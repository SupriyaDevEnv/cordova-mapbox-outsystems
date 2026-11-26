const test = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const Module = require('node:module');

// Load www/MapboxPlugin.js with a fake cordova/exec that records calls.
function loadPlugin(respond) {
  const calls = [];
  const fakeExec = (success, error, service, action, args) => {
    calls.push({ action, args });
    if (respond) respond(action, args, success, error);
  };
  const file = path.join(__dirname, '..', 'www', 'MapboxPlugin.js');
  const originalLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === 'cordova/exec') return fakeExec;
    return originalLoad.call(this, request, parent, isMain);
  };
  global.window = {};
  try {
    delete require.cache[file];
    return { api: require(file), calls };
  } finally {
    Module._load = originalLoad;
  }
}

test('initialize does not change the caller options and never sends a token', async () => {
  const { api, calls } = loadPlugin((action, args, ok) => ok({}));
  const options = { latitude: 1, longitude: 2, token: 'pk.should.not.send' };
  await api.initialize(options);
  assert.strictEqual(options.token, 'pk.should.not.send');
  const init = calls.find((c) => c.action === 'initialize');
  assert.ok(init);
  assert.strictEqual(init.args[0].token, undefined);
  assert.strictEqual(init.args[0].latitude, 1);
});

test('initialize rejects invalid zoom bounds before calling native code', async () => {
  const { api, calls } = loadPlugin();
  await assert.rejects(api.initialize({ minZoom: 'NaN' }), /minZoom/);
  await assert.rejects(api.initialize({ minZoom: 10, maxZoom: 5 }), /less than or equal/);
  await assert.rejects(api.initialize({ maxZoom: 30 }), /maxZoom/);
  assert.strictEqual(calls.filter((c) => c.action === 'initialize').length, 0);
});

test('isCancellationError recognises codes and legacy messages only', () => {
  const { api } = loadPlugin();
  assert.ok(api.isCancellationError({ code: 'MAPBOX_OPERATION_CANCELLED' }));
  assert.ok(api.isCancellationError('Map closed; operation cancelled.'));
  assert.ok(api.isCancellationError(new Error('Offline download cancelled.')));
  assert.ok(!api.isCancellationError(new Error('Location permission is not granted.')));
  assert.ok(!api.isCancellationError(null));
});

test('native cancellation strings become MapboxCancellationError', async () => {
  const { api } = loadPlugin((action, args, ok, fail) => fail('Location request superseded.'));
  await assert.rejects(api.moveToCurrentLocation({}), (error) => {
    assert.strictEqual(error.code, 'MAPBOX_OPERATION_CANCELLED');
    assert.strictEqual(error.name, 'MapboxCancellationError');
    assert.strictEqual(error.action, 'moveToCurrentLocation');
    return true;
  });
});

test('close cancels pending operations', async () => {
  let pendingDone = false;
  const { api } = loadPlugin((action, args, ok) => {
    if (action === 'close') ok();
    // every other action stays pending
  });
  const pending = api.getCamera().catch((error) => { pendingDone = true; return error; });
  await api.close();
  const error = await pending;
  assert.ok(pendingDone);
  assert.ok(api.isCancellationError(error));
});

test('offline detail levels match the documented zooms', () => {
  const { api } = loadPlugin();
  assert.deepStrictEqual({ ...api.offlineDetailMaxZoom }, { low: 13, medium: 15, high: 16 });
});

test('initializeOffline requires a regionId and calls the native action', async () => {
  const { api, calls } = loadPlugin((action, args, ok) => ok({ status: 'ok' }));
  await assert.rejects(api.initializeOffline({}), /regionId is required/);
  await assert.rejects(api.initializeOffline({ regionId: '   ' }), /regionId is required/);
  assert.strictEqual(calls.length, 0);

  const options = { regionId: 'trail-42', inline: true, token: 'pk.x.y' };
  await api.initializeOffline(options);
  const call = calls.find((c) => c.action === 'initializeOffline');
  assert.ok(call);
  assert.strictEqual(call.args[0].regionId, 'trail-42');
  assert.strictEqual(call.args[0].behindWebView, true);
  assert.strictEqual(call.args[0].token, undefined);
  assert.strictEqual(options.behindWebView, undefined);
  assert.strictEqual(options.token, 'pk.x.y');
  assert.ok(!calls.some((c) => c.action === 'initialize'));
});

test('initializeOffline rejects invalid zoom bounds like initialize', async () => {
  const { api, calls } = loadPlugin();
  await assert.rejects(api.initializeOffline({ regionId: 'a', minZoom: 12, maxZoom: 3 }), /less than or equal/);
  assert.strictEqual(calls.length, 0);
});
