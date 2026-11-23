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

function bridge(reply) {
  const calls = [];
  const context = {
    module: { exports: {} },
    require(name) {
      assert.equal(name, 'cordova/exec');
      return (resolve, reject, service, action, args) => {
        calls.push({ service, action, args });
        if (reply) reply(resolve, reject, action, args);
        else resolve({ ok: true });
      };
    }
  };
  vm.runInNewContext(fs.readFileSync('www/MapboxPlugin.js', 'utf8'), context);
  return { api: context.module.exports, calls };
}

const NEW_ACTIONS = ['estimateOfflineRegionSize', 'estimateOfflineRegionSizeForRect',
  'estimateOfflineRegionSizesForRect', 'getAvailableStorage', 'cancelOfflineDownload', 'getOfflineRegionIds'];

test('new offline calls reach their native actions', async () => {
  const { api, calls } = bridge();
  for (const name of NEW_ACTIONS) await api[name]({});
  assert.deepEqual(calls.map((c) => c.action), NEW_ACTIONS);
});

test('detail sets maxZoom for downloads and estimates without changing the caller object', async () => {
  const { api, calls } = bridge();
  const names = ['downloadOfflineRegion', 'downloadOfflineRegionForRect',
    'estimateOfflineRegionSize', 'estimateOfflineRegionSizeForRect'];
  for (const name of names) {
    for (const [detail, zoom] of [['low', 13], ['medium', 15], ['high', 16]]) {
      const options = { regionId: 'trail-1', detail };
      await api[name](options);
      assert.equal(calls.at(-1).args[0].maxZoom, zoom);
      assert.equal(calls.at(-1).args[0].regionId, 'trail-1');
      assert.deepEqual(options, { regionId: 'trail-1', detail });
    }
  }
  assert.equal(api.offlineDetailMaxZoom.medium, 15);
  assert.ok(Object.isFrozen(api.offlineDetailMaxZoom));
});

test('download forwards the selected estimate and rejects invalid values', async () => {
  const { api, calls } = bridge();
  const options = { detail: 'medium', estimatedMB: 18.4, regionId: 'trail-1' };
  await api.downloadOfflineRegionForRect(options);
  assert.equal(calls[0].args[0].maxZoom, 15);
  assert.equal(calls[0].args[0].estimatedMB, 18.4);
  assert.deepEqual(options, { detail: 'medium', estimatedMB: 18.4, regionId: 'trail-1' });

  await assert.rejects(api.downloadOfflineRegionForRect({ estimatedMB: -1 }), /estimatedMB must be/);
  await assert.rejects(api.downloadOfflineRegion({ estimatedMB: 'not a size' }), /estimatedMB must be/);
  assert.equal(calls.length, 1);
});

test('invalid detail or zoom is rejected before native', async () => {
  const { api, calls } = bridge();
  await assert.rejects(api.downloadOfflineRegion({ detail: 'ultra' }), /detail must be/);
  await assert.rejects(api.downloadOfflineRegionForRect({ detail: 'low', maxZoom: 14 }), /either detail or maxZoom/);
  await assert.rejects(api.estimateOfflineRegionSize({ minZoom: 0 }), /Offline zoom/);
  await assert.rejects(api.estimateOfflineRegionSizeForRect({ minZoom: 14, detail: 'low' }), /Offline zoom/);
  assert.equal(calls.length, 0);
});

test('one rectangle request returns all detail estimates without a maxZoom', async () => {
  const { api, calls } = bridge();
  const options = { x: 2, y: 3, width: 40, height: 50, minZoom: 10 };
  await api.estimateOfflineRegionSizesForRect(options);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, 'estimateOfflineRegionSizesForRect');
  assert.equal(calls[0].args[0].minZoom, 10);
  assert.equal(calls[0].args[0].maxZoom, undefined);
  assert.equal(options.minZoom, 10);

  await assert.rejects(
    api.estimateOfflineRegionSizesForRect({ minZoom: 14 }),
    /minZoom must be 2 through 13/
  );
  await assert.rejects(
    api.estimateOfflineRegionSizesForRect({ detail: 'low' }),
    /All detail levels are estimated/
  );
  await assert.rejects(
    api.estimateOfflineRegionSizesForRect({ maxZoom: 13 }),
    /All detail levels are estimated/
  );
  assert.equal(calls.length, 1);
});

test('a cancelled download rejects as a cancellation', async () => {
  const { api } = bridge((resolve, reject) => reject('Offline download cancelled.'));
  await assert.rejects(api.downloadOfflineRegion({}), (error) => {
    assert.equal(error.code, 'MAPBOX_OPERATION_CANCELLED');
    assert.equal(error.action, 'downloadOfflineRegion');
    assert.ok(api.isCancellationError(error));
    return true;
  });
});

test('both platforms implement every new action', () => {
  for (const name of NEW_ACTIONS) {
    assert.match(android, new RegExp('case "' + name + '":'), 'Android missing ' + name);
    assert.match(ios, new RegExp('@objc\\(' + name + ':\\)'), 'iOS missing ' + name);
  }
});

test('cancel ignores the old download and rejects it with the shared message', () => {
  const a = between(android, 'private void cancelOfflineDownload(', 'private void getOfflineRegionIds(');
  const i = between(ios, 'func cancelOfflineDownload(command:', '@objc(getOfflineRegionIds:)');
  assert.match(a, /offlineDownloadToken\+\+/);
  assert.match(a, /cancelCurrentDownload\(\)/);
  assert.match(a, /"Offline download cancelled\."/);
  assert.match(i, /offlineDownloadToken &\+= 1/);
  assert.match(i, /cancelCurrentDownload\(\)/);
  assert.match(i, /"Offline download cancelled\."/);
  // Every Mapbox download callback checks the token, so a late completion cannot
  // finish the next download or clear its in-progress flag.
  const aChain = between(android, 'private void startOfflineDownload(', 'private static Polygon offlineAreaPolygon(');
  const iChain = between(ios, 'private func startOfflineDownload(', 'struct OfflineAreaError');
  assert.doesNotMatch(aChain, /runForGeneration\(downloadGeneration/);
  assert.doesNotMatch(iChain, /runForGeneration\(downloadGeneration\)/);
  assert.equal((aChain.match(/runForDownload\(downloadGeneration, downloadToken,/g) || []).length, 5);
  assert.equal((iChain.match(/runForDownload\(downloadGeneration, downloadToken\)/g) || []).length, 5);
});

test('estimates use the shared tile count and report the download limits', () => {
  const a = between(android, 'private void estimateOfflineRegionSize(', 'private void getAvailableStorage(');
  const i = between(ios, 'private func sendOfflineEstimate(', '@objc(getAvailableStorage:)');
  for (const source of [a, i]) {
    assert.match(source, /estimatedTileCount\(/);
    assert.match(source, /"withinLimits"/);
    for (const key of ['tileCount', 'bytesPerTile', 'estimatedBytes', 'estimatedMB', 'minZoom', 'maxZoom', 'bounds']) {
      assert.match(source, new RegExp('"' + key + '"'));
    }
  }
  assert.match(android, /DEFAULT_BYTES_PER_TILE = 50 \* 1024;/);
  assert.match(ios, /defaultBytesPerTile: Double = 50 \* 1024/);
});

test('rectangle multi-estimate returns low, medium and high MB values on both platforms', () => {
  const a = between(android, 'private void estimateOfflineRegionSizesForRect(', 'private void estimateOfflineRegionSize(');
  const i = between(ios, '@objc(estimateOfflineRegionSizesForRect:)', 'private func sendOfflineEstimate(');
  for (const source of [a, i]) {
    for (const key of ['lowEstimatedMB', 'mediumEstimatedMB', 'highEstimatedMB']) {
      assert.match(source, new RegExp(key));
    }
  }
  assert.match(a, /int\[\] maxZooms = \{13, 15, 16\}/);
  assert.match(i, /\("lowEstimatedMB", 13\), \("mediumEstimatedMB", 15\), \("highEstimatedMB", 16\)/);
});

test('storage, region ids and byte progress return the same fields on both platforms', () => {
  for (const key of ['availableBytes', 'totalBytes', 'availableGB', 'regionIds', 'regions', 'complete',
    'completedBytes', 'completedMB']) {
    assert.match(android, new RegExp('"' + key + '"'), 'Android missing ' + key);
    assert.match(ios, new RegExp('"' + key + '"'), 'iOS missing ' + key);
  }
  assert.equal((android.match(/progress\.getCompletedResourceSize\(\)/g) || []).length, 2);
  assert.equal((ios.match(/completedBytes: Int64\(progress\.completedResourceSize\)/g) || []).length, 2);
});

test('tile progress carries the selected estimate beside downloaded MB on both platforms', () => {
  const aDownload = between(android, 'private void downloadOfflineRegion(JSONObject options', 'private void startOfflineDownload(');
  const iDownload = between(ios, '@objc(downloadOfflineRegion:)', 'private func startOfflineDownload(');
  assert.equal((aDownload.match(/optDouble\("estimatedMB", Double\.NaN\)/g) || []).length, 2);
  assert.equal((iDownload.match(/estimatedMB: estimatedMB/g) || []).length, 2);
  assert.match(android, /payload\.put\("estimatedMB", estimatedMB\)/);
  assert.match(ios, /payload\["estimatedMB"\] = estimatedMB/);
  assert.match(android, /"tiles", progress\.getCompletedResourceCount\(\), progress\.getRequiredResourceCount\(\), progress\.getCompletedResourceSize\(\), estimatedMB/);
  assert.match(ios, /phase: "tiles"[\s\S]*?estimatedMB: estimatedMB/);
});
