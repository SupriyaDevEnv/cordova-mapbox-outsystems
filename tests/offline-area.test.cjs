const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const android = fs.readFileSync('src/android/MapboxPluginEntry.java', 'utf8');
const ios = fs.readFileSync('src/ios/MapboxPlugin.swift', 'utf8');

function between(source, start, end) {
  const from = source.indexOf(start);
  assert.ok(from >= 0, 'Missing ' + start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to >= 0, 'Missing ' + end);
  return source.slice(from, to);
}

function bridge() {
  const calls = [];
  const context = {
    module: { exports: {} },
    require(name) {
      assert.equal(name, 'cordova/exec');
      return (resolve, reject, service, action, args) => {
        calls.push({ service, action, args });
        resolve({ regionId: args[0].regionId });
      };
    }
  };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

test('bounds and polygon reach native unchanged', async () => {
  const { api, calls } = bridge();
  const bounds = { regionId: 'trail-1', bounds: { south: -35, west: 138.5, north: -34.9, east: 138.6 } };
  const polygon = {
    regionId: 'trail-2',
    polygon: { type: 'Polygon', coordinates: [[[138.5, -35], [138.6, -35], [138.6, -34.9]]] }
  };
  await api.downloadOfflineRegion(bounds);
  await api.downloadOfflineRegion(polygon);
  assert.equal(calls[0].action, 'downloadOfflineRegion');
  assert.deepEqual(calls[0].args[0], bounds);
  assert.deepEqual(calls[1].args[0], polygon);
});

test('both platforms parse bounds or polygon with the same rules', () => {
  const a = between(android, 'private static Polygon offlineAreaPolygon(', 'private static double[] polygonBounds(');
  const i = between(ios, 'private func offlineAreaPolygon(', 'private func polygonBounds(');
  for (const source of [a, i]) {
    assert.match(source, /Pass either bounds or polygon, not both\./);
    assert.match(source, /south must be less than north and west less than east/);
    assert.match(source, /"Polygon"/);
    assert.match(source, /at least 3 positions/);
    assert.match(source, /too many positions/);
  }
  assert.match(android, /MAX_OFFLINE_POLYGON_POINTS = 1000;/);
  assert.match(ios, /maxOfflinePolygonPoints = 1000/);
});

test('area downloads replace centre and radius on both platforms', () => {
  const a = between(android, 'private void downloadOfflineRegion(', 'private void downloadOfflineRegionForRect(');
  const i = between(ios, 'func downloadOfflineRegion(command:', '@objc(downloadOfflineRegionForRect:)');
  assert.match(a, /area = offlineAreaPolygon\(options\)/);
  assert.match(a, /area != null \? 0\.0 : options\.optDouble\("radiusKm", 10\.0\)/);
  assert.match(a, /"offline-area-"/);
  assert.match(a, /styleUrl,\s*area,/);
  assert.match(i, /area = try self\.offlineAreaPolygon\(options\)/);
  assert.match(i, /area != nil \? 0 : self\.doubleOption\(options\["radiusKm"\]/);
  assert.match(i, /offline-area-/);
  assert.match(i, /geometry: area\?\.geometry/);
});

test('the area that was downloaded is the one reported back', () => {
  // The circle is built once and passed on, so the result polygon matches the tile region.
  assert.match(android, /clampedMinZoom, clampedMaxZoom, styleUrl, downloadGeometry, wifiOnly, callback\)/);
  assert.match(ios, /geometry: regionGeometry,/);
  assert.match(android, /\.geometry\(area\)/);
  assert.match(ios, /geometry: area,\r?\n\s*descriptors:/);
});

test('download results include the fields the app stores', () => {
  const a = between(android, 'private static JSONObject offlineDownloadResult(', 'private Polygon createRectPolygon(');
  const i = between(ios, 'private func offlineDownloadResult(', '@objc(showOfflineRegion:)');
  for (const key of ['regionId', 'latitude', 'longitude', 'radiusKm', 'sizeBytes', 'bounds', 'polygon',
    'minZoom', 'maxZoom', 'styleUrl', 'downloadedAt', 'south', 'west', 'north', 'east']) {
    assert.match(a, new RegExp('"' + key + '"'), 'Android result missing ' + key);
    assert.match(i, new RegExp('"' + key + '"'), 'iOS result missing ' + key);
  }
  assert.match(android, /tileRegion\.getCompletedResourceSize\(\)/);
  assert.match(ios, /sizeBytes: region\.completedResourceSize/);
  assert.match(a, /TimeZone\.getTimeZone\("UTC"\)/);
  assert.match(i, /withFractionalSeconds/);
});
