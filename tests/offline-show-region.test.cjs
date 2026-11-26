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
  const i = between(ios, 'private func downloadOfflineTiles(', '// Like runForGeneration');
  assert.match(i, /"styleUrl": styleURI\.rawValue/);
  assert.match(i, /"minZoom": Int\(minZoom\)/);
  assert.match(i, /"maxZoom": Int\(maxZoom\)/);
});

test('initializeOffline selects the isolated region store and cache on both platforms', () => {
  const aInit = between(android, 'private void initializeOffline(', 'private String getAccessToken()');
  const iInit = between(ios, 'func initializeOffline(command:', 'private func openOfflineMapView(');
  const aOpen = between(android, 'private void openOfflineMapView(', 'private String getAccessToken()');
  const iOpen = between(ios, 'private func openOfflineMapView(', '@objc(setCamera:)');
  for (const source of [aInit, iInit]) {
    assert.match(source, /isOfflineRegionMarkedComplete/);
    assert.match(source, /offlineRegionTileStore/);
    assert.match(source, /getTileRegionGeometry|tileRegionGeometry/);
  }
  assert.match(aOpen, /MapboxMapsOptions\.setTileStore\(regionStore\)/);
  assert.match(aOpen, /MapboxMapsOptions\.setDataPath\(offlineRegionDataPath\(regionId\)\)/);
  assert.match(iOpen, /MapboxMapsOptions\.tileStore = regionStore/);
  assert.match(iOpen, /MapboxMapsOptions\.dataPath = try offlineRegionDataPath\(regionId\)/);
  assert.match(aOpen, /setMapboxStackConnected\(false\)/);
  assert.match(iOpen, /isMapboxStackConnected = false/);
});

test('offline camera remains world-wide while respecting saved zoom limits', () => {
  const a = between(android, 'private void openDownloadedRegion(', 'private void deleteOfflineRegion(');
  const i = between(ios, 'private func openDownloadedRegion(', '@objc(deleteOfflineRegion:)');
  assert.match(a, /CoordinateBounds worldBounds = new CoordinateBounds/);
  assert.match(a, /\.bounds\(worldBounds\)[\s\S]*?\.minZoom\(minZoom\)[\s\S]*?\.maxZoom\(maxZoom\)/);
  assert.match(i, /bounds: CoordinateBounds\.world,[\s\S]*?maxZoom:[\s\S]*?minZoom:/);
  assert.doesNotMatch(a, /bounds\(regionBounds\)/);
  assert.doesNotMatch(i, /bounds: regionBounds/);
});

test('region listings expose isolated status and scan both store types', () => {
  const aList = between(android, 'private void getOfflineRegionIds(', 'private Polygon createRectPolygon(');
  const iList = between(ios, 'func getOfflineRegionIds(command:', 'struct OfflineAreaError');
  for (const source of [aList, iList]) {
    assert.match(source, /"isolated"/);
    assert.match(source, /loadOfflineRegions/);
  }
  assert.match(android, /entries\.add\(new OfflineStoreEntry\(legacyOfflineTileStore\(\), false\)\)/);
  assert.match(ios, /stores\.append\(OfflineStoreEntry\(store: TileStore\.default, isolated: false\)\)/);
});

test('downloads continue with a logged best-effort limit check when a store cannot be read', () => {
  const aLoad = between(android, 'private void loadOfflineRegions(', 'private void initializeOffline(');
  const aDownload = between(android, 'private void startOfflineDownload(', 'private void beginOfflineDownload(');
  const aList = between(android, 'private void getOfflineRegionIds(', 'private Polygon createRectPolygon(');
  const iLoad = between(ios, 'private func loadOfflineRegions(', '/// Opens only a region downloaded');
  const iDownload = between(ios, 'private func startOfflineDownload(', 'struct OfflineAreaError');
  const iList = between(ios, 'func getOfflineRegionIds(command:', 'struct OfflineAreaError');

  assert.match(aLoad, /result\.isError\(\)[\s\S]*?loadOfflineRegions\(stores, index \+ 1/);
  assert.match(aDownload, /if \(error != null\)\s*\{\s*Log\.w\(/);
  assert.match(aList, /if \(error != null\)\s*\{\s*callback\.error\(error\)/);
  assert.match(iLoad, /case \.failure\(let error\):[\s\S]*?self\.loadOfflineRegions\(/);
  assert.match(iDownload, /if let error = error\s*\{\s*NSLog\(/);
  assert.match(iList, /sendError\(error \?\? "Failed to read offline regions\."/);
});

test('showOfflineRegion reads the active isolated store and directs other regions to initializeOffline', () => {
  const a = between(android, 'private void showDownloadedRegion(', 'private void openDownloadedRegion(');
  const i = between(ios, 'private func showDownloadedRegion(', 'private func geometryCoordinates(');
  for (const source of [a, i]) {
    assert.match(source, /activeOfflineRegionStore/);
    assert.match(source, /Open this isolated region with initializeOffline/);
    assert.match(source, /getTileRegionGeometry|tileRegionGeometry/);
    assert.match(source, /getTileRegionMetadata|tileRegionMetadata/);
  }
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
