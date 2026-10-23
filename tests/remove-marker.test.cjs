const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function host() {
  const calls = [];
  const context = { module: { exports: {} }, require(name) {
    assert.equal(name, 'cordova/exec');
    return (ok, fail, service, action, args) => calls.push({ ok, fail, service, action, args });
  } };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

test('removeMarker dispatches the exact ID and supports Promise and success callback callers', async () => {
  const { api, calls } = host();
  for (const id of ['pin-1', '0', 'marker with spaces', '📍']) {
    let count = 0;
    const request = api.removeMarker(id, () => count++);
    const call = calls.at(-1);
    assert.equal(call.service, 'MapboxPlugin');
    assert.equal(call.action, 'removeMarker');
    assert.equal(call.args[0].id, id);
    call.ok();
    call.ok(); // A duplicate native reply must not deliver twice.
    await request;
    assert.equal(count, 1);
  }
  const request = api.removeMarker('unknown');
  calls.at(-1).ok();
  assert.equal(await request, undefined);
});

test('invalid IDs reject or reach the error callback without dispatch', async () => {
  const { api, calls } = host();
  for (const id of [undefined, null, '', 0, 42, false, {}, [], { id: 'pin' }]) {
    await assert.rejects(api.removeMarker(id), /markerId must be a non-empty string/);
    let received;
    await api.removeMarker(id, assert.fail, error => { received = error; });
    assert.equal(received.message, 'markerId must be a non-empty string.');
  }
  assert.equal(calls.length, 0);
});

test('native failures reach Promise and callback callers', async () => {
  const { api, calls } = host();
  const request = api.removeMarker('pin');
  calls.at(-1).fail('Failed to remove marker');
  await assert.rejects(request, error => error === 'Failed to remove marker');
  let received;
  const callbackRequest = api.removeMarker('pin', assert.fail, error => { received = error; });
  calls.at(-1).fail('Failed to remove marker');
  await callbackRequest;
  assert.equal(received, 'Failed to remove marker');
});

test('removal leaves the marker click stream active, including after repeated removal', async () => {
  const { api, calls } = host();
  const clicks = [];
  api.onMarkerClick(event => clicks.push(event));
  const stream = calls.at(-1);
  for (let i = 0; i < 2; i++) {
    const request = api.removeMarker('removed');
    calls.at(-1).ok();
    await request;
    stream.ok({ id: 'remaining', type: 'marker' });
  }
  assert.equal(clicks.length, 2);
  assert.equal(clicks[1].id, 'remaining');
});

test('close cancels pending removal once and suppresses a late native reply', async () => {
  const { api, calls } = host();
  let failures = 0;
  const removal = api.removeMarker('pin', assert.fail, error => {
    failures++;
    assert.equal(error.code, 'MAPBOX_OPERATION_CANCELLED');
  });
  const pending = calls.at(-1);
  const close = api.close();
  calls.at(-1).ok();
  pending.ok();
  await Promise.all([removal, close]);
  assert.equal(failures, 1);
});
