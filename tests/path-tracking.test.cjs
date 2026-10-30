const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const root = path.join(__dirname, '..');
const android = fs.readFileSync(path.join(root, 'src/android/MapboxPluginEntry.java'), 'utf8');
const ios = fs.readFileSync(path.join(root, 'src/ios/MapboxPlugin.swift'), 'utf8');

function bridge() {
  const calls = [];
  const context = { module: { exports: {} }, require() {
    return (ok, fail, service, action, args) => { calls.push({ action, args }); ok({}); };
  }};
  vm.runInNewContext(fs.readFileSync(path.join(root, 'www/MapboxPlugin.js'), 'utf8'), context);
  return { api: context.module.exports, calls };
}

const points = [{ lat: 1, lon: 1 }, { lat: 2, lon: 2 }, { lat: 3, lon: 3 }];

test('loadPath forwards style and segments given on the path object', async () => {
  const { api, calls } = bridge();
  const segments = [{ startIndex: 0, endIndex: 1 }];
  await api.loadPath({ points, lineColor: '#327bf0', lineWidth: 5, lineOpacity: 0.5, segments });
  const sent = calls[0].args[0];
  assert.equal(sent.lineColor, '#327bf0');
  assert.equal(sent.lineWidth, 5);
  assert.equal(sent.lineOpacity, 0.5);
  assert.deepEqual(sent.segments, segments);
  assert.equal(sent.points.length, 3);
});

test('loadPath second argument wins over the path object', async () => {
  const { api, calls } = bridge();
  await api.loadPath({ points, lineColor: '#111111' }, { lineColor: '#222222' });
  assert.equal(calls[0].args[0].lineColor, '#222222');
});

test('loadPath without style or segments sends only the points', async () => {
  const { api, calls } = bridge();
  await api.loadPath({ points });
  const sent = calls[0].args[0];
  assert.deepEqual(Object.keys(sent), ['points']);
});

test('both platforms report moving time and measure distance per segment', () => {
  const androidStop = android.split('private void stopPathTracking(')[1].split('private void pausePathTracking(')[0];
  assert.match(androidStop, /pathPausedTotalMs/);
  assert.match(androidStop, /segmentDistance\(segment\)/);
  assert.doesNotMatch(androidStop, /pathPoints\.get\(i - 1\)/);

  const iosStop = ios.split('func stopPathTracking(command:')[1].split('@objc(pausePathTracking:', 1)[0];
  assert.match(iosStop, /pathPausedTotal/);
  assert.match(iosStop, /for segment in self\.pathSegments/);
  assert.doesNotMatch(iosStop, /zip\(self\.pathPoints/);
});

test('pause and continue track paused time on both platforms', () => {
  const androidPause = android.split('private void pausePathTracking(')[1].split('private void continuePathTracking(')[0];
  const androidContinue = android.split('private void continuePathTracking(')[1].split('private void loadPath(')[0];
  assert.match(androidPause, /pathPauseStartMs = System\.currentTimeMillis\(\)/);
  assert.match(androidContinue, /pathPausedTotalMs \+=/);

  const iosPause = ios.split('func pausePathTracking(command:')[1].split('@objc(continuePathTracking:', 1)[0];
  const iosContinue = ios.split('func continuePathTracking(command:')[1].split('@objc(loadPath:', 1)[0];
  assert.match(iosPause, /self\.pathPauseStart = /);
  assert.match(iosContinue, /self\.pathPausedTotal \+=/);
});

test('loadPath draws one line per segment and show restores finished segments', () => {
  const androidLoad = android.split('private void loadPath(')[1].split('private void clearPaths(')[0];
  assert.match(androidLoad, /optJSONArray\("segments"\)/);
  assert.match(androidLoad, /drawSegmentAnnotations\(\)/);
  const androidVisibility = android.split('private void setPathVisibility(')[1].split('private void sendKeepCallback(')[0];
  assert.match(androidVisibility, /if \(!wasVisible\)[\s\S]*drawSegmentAnnotations\(\)/);

  const iosLoad = ios.split('func loadPath(command:')[1].split('@objc(clearPaths:', 1)[0];
  assert.match(iosLoad, /options\["segments"\]/);
  assert.match(iosLoad, /self\.drawSegmentAnnotations\(\)/);
  const iosVisibility = ios.split('func setPathVisibility(command:')[1].split('@objc(downloadOfflineRegion:', 1)[0];
  assert.match(iosVisibility, /if !wasVisible[\s\S]*self\.drawSegmentAnnotations\(\)/);
});

test('iOS path visibility accepts the "true"/"false" text OutSystems sends', () => {
  const visibility = ios.split('func setPathVisibility(command:')[1].split('@objc(downloadOfflineRegion:', 1)[0];
  assert.match(visibility, /boolOption\(options\["visible"\], defaultValue: true\)/);
  assert.doesNotMatch(visibility, /options\["visible"\] as\? Bool/);
});

test('a segment needs two points to be drawn', () => {
  assert.match(android, /private void drawSegmentAnnotations\(\)[\s\S]*segment\.size\(\) < 2/);
  assert.match(ios, /for segment in pathSegments where segment\.count >= 2/);
});
