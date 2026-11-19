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

const NEW_ACTIONS = ['estimateOfflineRegionSize', 'estimateOfflineRegionSizeForRect', 'getAvailableStorage',
  'cancelOfflineDownload', 'getOfflineRegionIds'];

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

test('invalid detail or zoom is rejected before native', async () => {
  const { api, calls } = bridge();
  await assert.rejects(api.downloadOfflineRegion({ detail: 'ultra' }), /detail must be/);
  await assert.rejects(api.downloadOfflineRegionForRect({ detail: 'low', maxZoom: 14 }), /either detail or maxZoom/);
  await assert.rejects(api.estimateOfflineRegionSize({ minZoom: 0 }), /Offline zoom/);
  await assert.rejects(api.estimateOfflineRegionSizeForRect({ minZoom: 14, detail: 'low' }), /Offline zoom/);
  assert.equal(calls.length, 0);
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

test('storage, region ids and byte progress return the same fields on both platforms', () => {
  for (const key of ['availableBytes', 'totalBytes', 'availableGB', 'regionIds', 'regions', 'complete',
    'completedBytes', 'completedMB']) {
    assert.match(android, new RegExp('"' + key + '"'), 'Android missing ' + key);
    assert.match(ios, new RegExp('"' + key + '"'), 'iOS missing ' + key);
  }
  assert.equal((android.match(/progress\.getCompletedResourceSize\(\)\)/g) || []).length, 2);
  assert.equal((ios.match(/completedBytes: Int64\(progress\.completedResourceSize\)/g) || []).length, 2);
});
