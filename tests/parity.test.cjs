const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const android = fs.readFileSync('src/android/MapboxPluginEntry.java', 'utf8');
const androidPermissions = fs.readFileSync('src/android/MapboxPluginPermissionEntry.java', 'utf8');
const ios = fs.readFileSync('src/ios/MapboxPlugin.swift', 'utf8');
const iosMarkerIcons = fs.readFileSync('src/ios/MarkerIcons.swift', 'utf8');

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

test('iOS consistently converts native-pixel rectangles to UIKit points', () => {
  const frame = ios.split('private func frameFromOptions')[1].split('private func touchRectFromOptions')[0];
  assert.doesNotMatch(frame, /appearsDevicePixelScaled/);
  assert.match(frame, /options\["x"\][\s\S]*\/ scale/);
  assert.match(frame, /options\["width"\][\s\S]*\/ scale/);

  const offline = ios.split('func downloadOfflineRegionForRect(command:')[1]
    .split('private func startOfflineDownload')[0];
  for (const name of ['x', 'y', 'width', 'height']) {
    assert.match(offline, new RegExp('let ' + name + ' = native' +
      name[0].toUpperCase() + name.slice(1) + ' / scale'));
  }
});

test('iOS matches Android option coercion and idempotent path visibility', () => {
  const pathStart = ios.split('func startPathTracking(command:')[1].split('@objc(stopPathTracking:', 1)[0];
  assert.match(pathStart, /boolOption\(options\["trackCamera"\], defaultValue: true\)/);

  const markers = ios.split('func loadMarkers(command:')[1].split('@objc(removeMarker:', 1)[0];
  assert.match(markers, /marker\["Id"\]\.flatMap\(self\.stringOption\)/);
  assert.match(markers, /marker\["Latitude"\]/);
  assert.match(markers, /marker\["Longitude"\]/);
  assert.match(markers, /marker\["IsFind"\]/);
  assert.match(iosMarkerIcons, /cg\.setLineCap\(\.round\)/);
  assert.match(iosMarkerIcons, /cg\.strokeEllipse\(in:/);
  assert.match(iosMarkerIcons, /format\.scale = 1/);
  assert.match(ios, /private func stringOption/);

  const visibility = ios.split('func setPathVisibility(command:')[1].split('@objc(downloadOfflineRegion:', 1)[0];
  assert.doesNotMatch(visibility, /No path is loaded/);
  assert.match(visibility, /self\.isPathVisible = visible/);
  assert.match(visibility, /self\.sendSuccess\(command\)/);
});

test('markers accept imageUrl and pinColor on both platforms and reject disallowed images', () => {
  const androidAdd = javaMethod('addMarker', 'loadMarkers');
  const androidLoad = android.split('private void loadMarkers(')[1].split('private boolean addMarkerInternal(')[0];
  for (const body of [androidAdd, androidLoad]) {
    assert.match(body, /markerStyle\(/);
    assert.match(body, /MARKER_IMAGE_NOT_ALLOWED/);
  }
  assert.match(androidAdd, /optString\("imageUrl"/);
  assert.match(androidAdd, /optString\("pinColor"/);
  assert.match(androidLoad, /optString\("ImageUrl"/);
  assert.match(androidLoad, /optString\("PinColor"/);
  assert.match(android, /markerImageAllowed\(imageUrl, allowedMarkerImageHosts\(\)\)/);

  const iosAdd = ios.split('func addMarker(command:')[1].split('@objc(loadMarkers:', 1)[0];
  const iosLoad = ios.split('func loadMarkers(command:')[1].split('@objc(removeMarker:', 1)[0];
  for (const body of [iosAdd, iosLoad]) {
    assert.match(body, /markerStyle\(isFind:/);
    assert.match(body, /markerImageNotAllowed/);
  }
  assert.match(iosAdd, /options\["imageUrl"\]/);
  assert.match(iosAdd, /options\["pinColor"\]/);
  assert.match(iosLoad, /marker\["ImageUrl"\]/);
  assert.match(iosLoad, /marker\["PinColor"\]/);
  assert.match(ios, /marker\.iconSize = 0\.5/);
  assert.match(android, /\.withIconSize\(0\.5\)/);
  assert.match(ios, /MAPBOX_ALLOWED_MARKER_IMAGE_HOSTS/);
});

test('Mapbox SDK version strings agree across plugin.xml, Gradle and iOS', () => {
  const pluginXml = fs.readFileSync('plugin.xml', 'utf8');
  const gradle = fs.readFileSync('src/android/mapbox-plugin.gradle', 'utf8');
  const parity = fs.readFileSync('src/ios/MapboxPluginParity.swift', 'utf8');
  const pod = pluginXml.match(/<pod name="MapboxMaps" spec="([^"]+)"/)[1];
  const androidDefault = pluginXml.match(/name="MAPBOX_ANDROID_VERSION" default="([^"]+)"/)[1];
  const gradleDefault = gradle.match(/\?:\s*"(\d+\.\d+\.\d+)"/)[1];
  const iosReported = parity.match(/mapboxSdkVersion = "([^"]+)"/)[1];
  assert.equal(androidDefault, pod);
  assert.equal(gradleDefault, pod);
  assert.equal(iosReported, pod);
});

test('precise location is required on both platforms with the same error text', () => {
  const iosPermissions = fs.readFileSync('src/ios/MapboxPluginPermissionParity.swift', 'utf8');
  const iosParity = fs.readFileSync('src/ios/MapboxPluginParity.swift', 'utf8');
  const hasPermission = android.split('private boolean hasLocationPermission()')[1].split('}')[0];
  assert.match(hasPermission, /ACCESS_FINE_LOCATION/);
  assert.doesNotMatch(hasPermission, /ACCESS_COARSE_LOCATION/);
  const gate = androidPermissions.split('private boolean hasLocationPermission()')[1].split('}')[0];
  assert.match(gate, /ACCESS_FINE_LOCATION/);
  assert.doesNotMatch(gate, /ACCESS_COARSE_LOCATION/);
  assert.match(androidPermissions, /Precise location permission is not granted\./);
  assert.match(android, /Precise location permission is not granted\./);
  assert.match(iosPermissions, /accuracyAuthorization == \.fullAccuracy/);
  assert.match(iosPermissions, /Precise location permission is not granted\./);
  assert.match(iosParity, /accuracyAuthorization == \.fullAccuracy/);
  assert.equal((android.match(/setGranularity\(Granularity\.GRANULARITY_FINE\)/g) || []).length, 2,
    'tracking and accuracy-monitor requests ask for fine granularity');
});

test('Java and Swift location filters keep identical constants', () => {
  const java = fs.readFileSync('src/android/LocationFilter.java', 'utf8');
  const swift = fs.readFileSync('src/ios/LocationFilter.swift', 'utf8');
  const javaConstants = {};
  for (const m of java.matchAll(/static final (?:double|int) ([A-Z_]+) = ([0-9.]+);/g)) {
    const camel = m[1].toLowerCase().replace(/_([a-z])/g, (_, c) => c.toUpperCase());
    javaConstants[camel] = Number(m[2]);
  }
  const swiftConstants = {};
  for (const m of swift.matchAll(/static let ([A-Za-z]+) = ([0-9.]+)/g)) swiftConstants[m[1]] = Number(m[2]);
  assert.equal(Object.keys(javaConstants).length, 10, 'all filter constants found in Java');
  assert.deepEqual(swiftConstants, javaConstants);
});

test('locationFilter option is validated identically on both platforms and defaults to legacy', () => {
  assert.match(android, /"legacy"\.equals\(locationFilterMode\) && !"accuracyWeighted"\.equals\(locationFilterMode\)/);
  assert.match(android, /locationFilter must be \\"legacy\\" or \\"accuracyWeighted\\"\./);
  assert.match(ios, /mode == "legacy" \|\| mode == "accuracyWeighted"/);
  assert.match(ios, /locationFilter must be \\"legacy\\" or \\"accuracyWeighted\\"\./);
  assert.match(android, /accuracyWeightedFilter = false;/);
  assert.match(ios, /accuracyWeightedFilter = false/);
});

test('accuracy ring is opt-in on both platforms and the legacy puck is unchanged when off', () => {
  assert.match(android, /options\.optBoolean\("showAccuracyRing", false\)/);
  assert.match(android, /location\.setShowAccuracyRing\(showAccuracyRing\)/);
  assert.match(android, /onHorizontalAccuracyRadiusUpdated\(/);
  assert.match(android, /showAccuracyRing = false;/);
  assert.match(ios, /boolOption\(options\["showAccuracyRing"\], defaultValue: false\)/);
  assert.match(ios, /guard showAccuracyRing else \{\s*return showBearing \? \.puck2D\(\.makeDefault\(showBearing: true\)\) : \.puck2D\(\)/);
  assert.match(ios, /configuration\.showsAccuracyRing = true/);
  assert.doesNotMatch(ios, /options\.puckType = \.puck2D/, 'puck creation goes through puckType(showBearing:)');
});

test('location diagnostics are opt-in on both platforms', () => {
  const iosParity = fs.readFileSync('src/ios/MapboxPluginParity.swift', 'utf8');
  assert.match(android, /options\.optBoolean\("locationDiagnostics", false\)/);
  assert.match(ios, /boolOption\(options\["locationDiagnostics"\], defaultValue: false\)/);
  assert.match(android, /if \(!locationDiagnostics\) return;/);
  assert.match(iosParity, /guard locationDiagnostics else \{ return \}/);
});

test('boolean and numeric options use the same tolerant parsing on both platforms', () => {
  assert.doesNotMatch(ios, /options\["(enabled|visible|replace|isFind|autoAddMarker|deleteStylePack|inline|behindWebView)"\] as\? Bool/);
  assert.doesNotMatch(ios, /marker\["IsFind"\] as\? Bool/);
  assert.doesNotMatch(ios, /options\["(lineWidth|lineOpacity|duration)"\] as\? Double/);
  assert.match(ios, /CFGetTypeID\(number\) == CFBooleanGetTypeID\(\)/);
  assert.match(android, /options\.optBoolean\("trackCamera", true\)/);
  assert.doesNotMatch(android, /optString\("trackCamera"/);
});

test('location accuracy subscriptions actively monitor and clean up on both platforms', () => {
  const androidRegistration = javaMethod('registerLocationAccuracyCallback', 'stopLocationAccuracyMonitoring');
  assert.match(androidRegistration, /requestLocationUpdates/);
  assert.match(androidRegistration, /sendLocationAccuracyUpdate/);
  assert.match(androidPermissions, /"registerLocationAccuracyCallback"\.equals\(action\)/);
  assert.match(android, /stopLocationAccuracyMonitoring\(\);[\s\S]*locationAccuracyCallback = null/);

  const iosParity = fs.readFileSync('src/ios/MapboxPluginParity.swift', 'utf8');
  const iosRegistration = iosParity.split('func registerLocationAccuracyCallback(command:')[1]
    .split('@objc(getCurrentLocationAccuracy:', 1)[0];
  assert.match(iosRegistration, /startUpdatingLocation\(\)/);
  assert.match(iosParity, /stopAccuracyMonitoring\(\)/);
});
test('pinStyle "photo" draws the same 52x63 pin on both platforms and is opt-in', () => {
  const androidIcons = fs.readFileSync('src/android/MarkerIcons.java', 'utf8');
  assert.match(android, /optString\("pinStyle"/);
  assert.match(android, /optString\("PinStyle"/);
  assert.match(ios, /pinStyle: options\["pinStyle"\]/);
  assert.match(ios, /pinStyle: marker\["PinStyle"\]/);
  assert.match(ios, /\(pinStyle as\? String\) == "photo"/);
  // Same canvas (52x63 grid at 2x) and the same teardrop geometry.
  assert.match(androidIcons, /PHOTO_WIDTH = 52/);
  assert.match(androidIcons, /PHOTO_HEIGHT = 63/);
  assert.match(iosMarkerIcons, /photoSize = CGSize\(width: 104, height: 126\)/);
  for (const source of [androidIcons, iosMarkerIcons]) {
    assert.match(source, /14\.5/);
    assert.match(source, /36\.95/);
    assert.match(source, /62\.75/);
  }
  // Classic pins are untouched unless the option is set.
  assert.match(android, /MarkerStyle\(int color, boolean isFind, String imageUrl\)\s*\{\s*this\(color, isFind, imageUrl, false\)/);
  assert.match(ios, /var photo = false/);
});
