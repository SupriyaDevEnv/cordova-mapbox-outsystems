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
        resolve();
      };
    }
  };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

test('regionId reaches native unchanged', async () => {
  const { api, calls } = bridge();
  const options = { regionId: 'trail-42' };
  await api.showOfflineRegion(options);
  assert.equal(calls[0].action, 'showOfflineRegion');
  assert.deepEqual(calls[0].args[0], { regionId: 'trail-42' });
});

test('downloads save the style and zoom range needed to reopen the region', () => {
  const a = between(android, 'private void downloadOfflineTiles(', 'private static Polygon offlineAreaPolygon(');
  assert.match(a, /regionMetadataValue\(regionId, styleUrl, toZoomByte\(minZoom\), toZoomByte\(maxZoom\)\)/);
  const save = between(android, 'private Value regionMetadataValue(', 'private static Object metadataEntry(');
  for (const key of ['regionId', 'styleUrl', 'minZoom', 'maxZoom']) assert.match(save, new RegExp('"' + key + '"'));
  const i = between(ios, 'private func downloadOfflineTiles(', 'activeTileRegionDownload = tileStore.loadTileRegion(');
  assert.match(i, /"styleUrl": styleURI\.rawValue/);
  assert.match(i, /"minZoom": Int\(minZoom\)/);
  assert.match(i, /"maxZoom": Int\(maxZoom\)/);
});

test('showOfflineRegion uses the stored region when regionId is given, on both platforms', () => {
  const aShow = between(android, 'private void showOfflineRegion(', 'private void showDownloadedRegion(');
  assert.match(aShow, /if \(!regionId\.isEmpty\(\)\) \{[\s\S]*?must be downloaded again to use isolated offline maps\.[\s\S]*?initializeOffline\(options, callback\)/);
  const iShow = between(ios, 'func showOfflineRegion(command:', 'private func showDownloadedRegion(');
  assert.match(iShow, /if !regionId\.isEmpty \{[\s\S]*?must be downloaded again to use isolated offline maps\.[\s\S]*?self\.initializeOffline\(command: command\)/);

  const a = between(android, 'private void showDownloadedRegion(', 'private void deleteOfflineRegion(');
  const i = between(ios, 'private func showDownloadedRegion(', '@objc(deleteOfflineRegion:)');
  assert.match(a, /getTileRegionGeometry\(regionId/);
  assert.match(a, /getTileRegionMetadata\(regionId/);
  assert.match(i, /tileRegionGeometry\(forId: regionId\)/);
  assert.match(i, /tileRegionMetadata\(forId: regionId\)/);
  for (const source of [a, i]) {
    assert.match(source, /is not downloaded on this device\./);
    assert.match(source, /A style load is already in progress/);
    // The saved style wins; the option is only a fallback for older downloads.
    assert.match(source, /"styleUrl"/);
    assert.match(source, /fitZoom\(/);
    assert.match(source, /loadReadyStyle\(/);
  }
  // Saved zooms bound the camera; the region's own style is preferred.
  assert.match(a, /String styleUrl = metadataString\(metadata, "styleUrl"\);\s*if \(styleUrl == null\) styleUrl = options\.optString\("styleUrl"/);
  assert.match(a, /zoom = clamp\(zoom, minZoom, maxZoom\);/);
  assert.match(i, /let styleUrl = savedStyle \?\? options\["styleUrl"\] as\? String/);
  assert.match(i, /zoom = Swift\.max\(minZoom, Swift\.min\(maxZoom, zoom\)\)/);
  assert.match(a, /if \(offlineMapAllowsWorldPan\) \{\s*boundsBuilder\.bounds\(new CoordinateBounds\([\s\S]*?Point\.fromLngLat\(-180\.0, -90\.0\)[\s\S]*?Point\.fromLngLat\(180\.0, 90\.0\)/);
  assert.match(a, /else \{\s*boundsBuilder\.bounds\(new CoordinateBounds\([\s\S]*?Point\.fromLngLat\(box\[0\], box\[1\]\)[\s\S]*?Point\.fromLngLat\(box\[2\], box\[3\]\)/);
  assert.match(a, /\.minZoom\(minZoom\)[\s\S]*?\.maxZoom\(maxZoom\)/);
  assert.match(i, /bounds: offlineMapAllowsWorldPan \? \.world : regionBounds,[\s\S]*?maxZoom:[\s\S]*?minZoom:/);
  assert.ok(a.indexOf('setBounds(bounds.build())') < a.indexOf('setCamera(new CameraOptions.Builder()'));
  assert.ok(i.indexOf('setCameraBounds(with: CameraBoundsOptions') < i.indexOf('setCamera(to: CameraOptions'));
  assert.match(a, /offlineRegionCameraBoundsActive = true/);
  assert.match(i, /offlineRegionCameraBoundsActive = true/);
});

test('opening a regular location restores the map bounds from initialize', () => {
  const a = between(android, 'private void showOfflineRegion(', 'private boolean restoreInitialCameraBounds(');
  const i = between(ios, 'func showOfflineRegion(command:', 'private func restoreInitialCameraBounds(');
  assert.match(a, /restoreInitialCameraBounds\(callback\)/);
  assert.match(i, /restoreInitialCameraBounds\(command\)/);
  assert.match(android, /initialCameraMinZoom = minZoom/);
  assert.match(android, /initialCameraMaxZoom = maxZoom/);
  assert.match(ios, /self\.initialCameraMinZoom = minZoom/);
  assert.match(ios, /self\.initialCameraMaxZoom = maxZoom/);
});

test('offline maps use a region-specific tile store and allow whole-world panning', () => {
  for (const source of [android, ios]) {
    assert.match(source, /offlineRegionTileStore\(regionId\)/);
    assert.match(source, /offlineMapAllowsWorldPan = true/);
    assert.match(source, /setMapboxStackConnected\(false\)|isMapboxStackConnected = false/);
  }
  assert.match(android, /offlineMapTileStore != null\s*\?\s*offlineMapTileStore : TileStore\.create\(\)/);
  assert.match(ios, /offlineMapTileStore \?\? TileStore\.default/);
  assert.match(android, /TileStore\.create\(path\.getAbsolutePath\(\)\)/);
  assert.match(ios, /TileStore\.shared\(for: try offlineRegionStoreURL\(regionId, create: true\)\)/);
  assert.match(android, /MapboxMapsOptions\.setTileStore\(tileStore\)/);
  assert.match(ios, /MapboxMapsOptions\.tileStore = tileStore/);
  assert.match(android, /detail\.put\("isolated", hasIsolatedOfflineRegionStore\(region\.getId\(\)\)\)/);
  assert.match(ios, /"isolated": self\.hasIsolatedOfflineRegionStore\(region\.id\)/);
});

test('offline deletion keeps the selected region store for style-pack cleanup', () => {
  const a = between(android, 'private void deleteOfflineRegion(', 'private void registerOfflineDownloadProgressCallback(');
  assert.match(a, /boolean hadIsolatedStore = isolatedStorePath\.isDirectory\(\);[\s\S]*?marker\.delete\(\)[\s\S]*?TileStore store = hadIsolatedStore/);

  const i = between(ios, '@objc(deleteOfflineRegion:)', '@objc(setWaypointSelectionEnabled:)');
  assert.match(i, /let hasIsolatedStore = FileManager\.default\.fileExists\(atPath: isolatedStoreURL\.path\)[\s\S]*?removeItem\(at: completionMarker\)[\s\S]*?MapboxMapsOptions\.tileStore = tileStore/);
});

test('both platforms fit the region with the same formula', () => {
  const a = between(android, 'private static double mercatorY(', 'private void showOfflineRegion(');
  const i = between(ios, 'static func fitZoom(', 'private func openDownloadedRegion(');
  for (const source of [a, i]) {
    assert.match(source, /0\.9/);
    assert.match(source, /512/);
    assert.match(source, /360/);
    assert.match(source, /85\.0511/);
  }
});

test('fit-zoom formula gives sensible zooms for typical regions', () => {
  // Same maths as fitZoom on both platforms.
  const mercatorY = (lat) => {
    const r = Math.max(-85.0511, Math.min(85.0511, lat)) * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2;
  };
  const fit = (s, w, n, e, width, height) => Math.min(
    Math.log2(width * 0.9 / (512 * (e - w) / 360)),
    Math.log2(height * 0.9 / (512 * Math.abs(mercatorY(s) - mercatorY(n)))));
  const fiveKm = fit(-34.95, 138.55, -34.905, 138.605, 390, 844);
  const fortyKm = fit(-35.1, 138.38, -34.74, 138.82, 390, 844);
  assert.ok(fiveKm > 11.5 && fiveKm < 12.5, String(fiveKm));
  assert.ok(fortyKm > 8.5 && fortyKm < 9.5, String(fortyKm));
  assert.ok(fortyKm < fiveKm);
});
