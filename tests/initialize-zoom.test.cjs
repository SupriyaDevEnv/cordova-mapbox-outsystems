const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function bridge() {
  const calls = [];
  const context = {
    module: { exports: {} },
    require(name) {
      assert.equal(name, 'cordova/exec');
      return (resolve, reject, service, action, args) => {
        calls.push({ service, action, args });
        resolve({ status: 'initialized' });
      };
    }
  };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

test('initialize preserves absent, null, and undefined bounds without inserting defaults', async () => {
  const { api, calls } = bridge();
  for (const options of [undefined, {}, { minZoom: null }, { maxZoom: null },
    { minZoom: null, maxZoom: null }, { minZoom: undefined, maxZoom: undefined }]) {
    await api.initialize(options);
    if (options) assert.equal(calls.at(-1).args[0], options);
    else assert.deepEqual(Object.keys(calls.at(-1).args[0]), []);
  }
});

test('initialize forwards one-sided, fractional, equal, and endpoint bounds unchanged', async () => {
  const { api, calls } = bridge();
  for (const options of [{ minZoom: 18 }, { maxZoom: 19.5 },
    { minZoom: 0, maxZoom: 25.5 }, { minZoom: 18, maxZoom: 18 },
    { minZoom: null, maxZoom: 0 }, { minZoom: 18.25, maxZoom: undefined }]) {
    await api.initialize(options);
    assert.equal(calls.at(-1).action, 'initialize');
    assert.equal(calls.at(-1).args[0], options);
  }
});

test('invalid bounds reject before reaching Cordova, including non-finite values before JSON serialization', async () => {
  const { api, calls } = bridge();
  for (const key of ['minZoom', 'maxZoom']) {
    for (const value of [NaN, Infinity, -Infinity, -0.01, 25.5001, '18', '', true, false, [], {}, new Number(18)]) {
      await assert.rejects(api.initialize({ [key]: value }), {
        message: key + ' must be a finite number between 0 and 25.5.'
      });
    }
  }
  await assert.rejects(api.initialize({ minZoom: 19, maxZoom: 18 }), {
    message: 'minZoom must be less than or equal to maxZoom.'
  });
  assert.equal(calls.length, 0);
});

test('reinitializing without bounds does not retain previous options', async () => {
  const { api, calls } = bridge();
  await api.initialize({ minZoom: 18, maxZoom: 20 });
  await api.initialize({ zoom: 12 });
  assert.deepEqual(calls[1].args[0], { zoom: 12 });
});

test('offline limits and defaults are unchanged', async () => {
  const { api, calls } = bridge();
  for (const name of ['downloadOfflineRegion', 'downloadOfflineRegionForRect']) {
    await api[name]({});
    await api[name]({ minZoom: 18, maxZoom: 18 });
    await assert.rejects(api[name]({ minZoom: 0, maxZoom: 25.5 }), /Offline zoom/);
  }
  assert.equal(calls.length, 4);
});

test('native source guards preserve optional bounds and enforce constraints before success', () => {
  const android = fs.readFileSync('src/android/MapboxPluginEntry.java', 'utf8');
  const ios = fs.readFileSync('src/ios/MapboxPlugin.swift', 'utf8');
  const a = android.split('private void initialize(')[1].split('private String getAccessToken')[0];
  const i = ios.split('func initialize(command:')[1].split('@objc(setCamera:')[0];
  assert.match(android, /if \(options\.isNull\(key\)\) return null/);
  assert.match(android, /value instanceof Number/);
  assert.match(android, /Double\.isNaN\(zoom\).*Double\.isInfinite\(zoom\).*zoom < 0.*zoom > 25\.5/);
  assert.match(ios, /value is NSNull/);
  assert.match(ios, /CFGetTypeID\(number\) != CFBooleanGetTypeID\(\)/);
  assert.match(ios, /number\.doubleValue\.isFinite/);
  assert.match(ios, /\(0\.\.\.25\.5\)\.contains\(number\.doubleValue\)/);
  for (const body of [a, i]) {
    assert.ok(body.indexOf('optionalCameraZoom') < body.indexOf('closeInternal()'));
    assert.match(body, /minZoom > maxZoom/);
    assert.match(body, /Camera zoom bounds conflict with the map's default bounds\./);
  }
  assert.match(a, /if \(minZoom != null \|\| maxZoom != null\)/);
  assert.match(a, /if \(minZoom != null\) bounds\.minZoom\(minZoom\)/);
  assert.match(a, /if \(maxZoom != null\) bounds\.maxZoom\(maxZoom\)/);
  assert.ok(a.indexOf('setBounds(') < a.indexOf('setCamera('));
  assert.match(a, /setBounds\(bounds\.build\(\)\)\.isError\(\)/);
  assert.match(i, /if minZoom != nil \|\| maxZoom != nil/);
  assert.match(i, /try mapView\.mapboxMap\.setCameraBounds/);
  assert.match(i, /maxZoom: maxZoom, minZoom: minZoom/);
  assert.ok(i.indexOf('setCameraBounds') < i.indexOf('setCamera(to: camera)'));
  assert.ok(i.indexOf('setCameraBounds') < i.indexOf('self.mapView = mapView'));
});
