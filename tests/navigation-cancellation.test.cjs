const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function host(platform) {
  const calls = [];
  const context = { module: { exports: {} }, window: { cordova: { platformId: platform } },
    require(name) {
      assert.equal(name, 'cordova/exec');
      return (ok, fail, service, action, args) => calls.push({ ok, fail, action, args });
    } };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

for (const platform of ['android', 'ios']) {
  test(`${platform}: navigate away with location pending, then reopen without stale delivery`, async () => {
    const { api, calls } = host(platform);
    const first = api.initialize({});
    calls.at(-1).ok({ status: 'initialized' });
    await first;
    const oldClosed = calls.at(-1);
    const location = api.moveToCurrentLocation({});
    const oldLocation = calls.at(-1);
    const cancelled = assert.rejects(location, error => {
      assert.equal(error.code, 'MAPBOX_OPERATION_CANCELLED');
      assert.equal(error.name, 'MapboxCancellationError');
      assert.equal(error.action, 'moveToCurrentLocation');
      return api.isCancellationError(error);
    });
    const close = api.close();
    calls.at(-1).ok();
    await close;
    await cancelled;
    const reopened = api.initialize({});
    calls.at(-1).ok({ status: 'initialized' });
    await reopened;
    const nextLocation = api.moveToCurrentLocation({});
    const current = calls.at(-1);
    oldClosed.ok();
    oldLocation.fail('Unable to get current location.');
    oldLocation.ok({ latitude: 0, longitude: 0 });
    current.ok({ latitude: 12, longitude: 77 });
    assert.deepEqual(await nextLocation, { latitude: 12, longitude: 77 });
  });

  test(`${platform}: reinitialization cancels the old request with its action`, async () => {
    const { api, calls } = host(platform);
    const first = api.initialize({});
    const cancelled = assert.rejects(first, error =>
      api.isCancellationError(error) && error.action === 'initialize');
    const next = api.initialize({});
    calls.at(-1).ok({ status: 'initialized' });
    await next;
    await cancelled;
  });
}

test('native cancellation strings are normalized, genuine location failures are preserved', async () => {
  const { api, calls } = host('android');
  for (const message of ['Map closed; operation cancelled.', 'Location request was cancelled.',
    'Location request superseded.']) {
    const request = api.moveToCurrentLocation({});
    const rejected = assert.rejects(request, error =>
      api.isCancellationError(error) && error.message === message && error.action === 'moveToCurrentLocation');
    calls.at(-1).fail(message);
    await rejected;
    assert.equal(api.isCancellationError(message), true);
  }
  for (const message of ['Unable to get current location.', 'Location permission is not granted.',
    'Location provider is not enabled.', 'Map is not initialized.']) {
    const request = api.moveToCurrentLocation({});
    const rejected = assert.rejects(request, error => error === message && !api.isCancellationError(error));
    calls.at(-1).fail(message);
    await rejected;
  }
  assert.equal(api.isCancellationError(null), false);
  assert.equal(api.isCancellationError({}), false);
});

test('callback-based APIs receive typed native cancellation without a success callback', () => {
  const { api, calls } = host('ios');
  let success = 0, failure;
  api.getMapboxVersion(() => success++, error => { failure = error; });
  calls.at(-1).fail('Map closed; operation cancelled.');
  assert.equal(success, 0);
  assert.equal(failure.action, 'getMapboxVersion');
  assert.equal(api.isCancellationError(failure), true);
});
