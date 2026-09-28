const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const android = fs.readFileSync('src/android/MapboxPluginEntry.java', 'utf8');
const ios = fs.readFileSync('src/ios/MapboxPlugin.swift', 'utf8');

function javaMethod(name, nextName) {
  return android.split('private void ' + name + '(')[1].split('private void ' + nextName + '(')[0];
}

test('camera actions preserve omitted center coordinates on both platforms', () => {
  for (const body of [javaMethod('setCamera', 'flyTo'), javaMethod('flyTo', 'enableUserLocation')]) {
    assert.match(body, /getCameraState\(\)\.getCenter\(\)/);
    assert.match(body, /optDouble\("latitude", currentCenter\.latitude\(\)\)/);
    assert.match(body, /optDouble\("longitude", currentCenter\.longitude\(\)\)/);
  }
  for (const name of ['setCamera', 'flyTo']) {
    const body = ios.split('func ' + name + '(command:')[1].split('@objc', 1)[0];
    assert.match(body, /defaultValue: mapView\.cameraState\.center\.latitude/);
    assert.match(body, /defaultValue: mapView\.cameraState\.center\.longitude/);
  }
});

test('initial camera applies bearing and pitch on both platforms', () => {
  const androidInitialize = android.split('private void initialize(')[1].split('private String getAccessToken')[0];
  assert.match(androidInitialize, /optDouble\("bearing", 0\.0\)/);
  assert.match(androidInitialize, /optDouble\("pitch", 0\.0\)/);
  assert.match(androidInitialize, /\.bearing\(bearing\)/);
  assert.match(androidInitialize, /\.pitch\(pitch\)/);

  const iosInitialize = ios.split('func initialize(command:')[1].split('@objc(setCamera:', 1)[0];
  assert.match(iosInitialize, /options\["bearing"\]/);
  assert.match(iosInitialize, /options\["pitch"\]/);
  assert.match(iosInitialize, /bearing: bearing/);
  assert.match(iosInitialize, /pitch: pitch/);
});
