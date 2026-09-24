# OutSystems Mapbox Native Plugin

## Security behavior in 1.0.3

- Closing the map (including the native Close button) or resetting the WebView stops location/heading services, cancels downloads and pending permission actions, and clears map-session data and callbacks. Re-register callbacks after initializing a new map session.
- `MAPBOX_ACCESS_TOKEN` must be a public `pk.*` token. Both platform builds reject configured secret tokens. Initialization always reads the current configuration and removes legacy cached values, so token rotation works after app upgrades. Unconfigured build templates may still be prepared, but cannot initialize the map.
- Style URLs must be `mapbox://styles/<owner>/<style>` or HTTPS on an explicitly approved host. `MAPBOX_ALLOWED_STYLE_HOSTS` is a comma-separated build preference, defaulting to `api.mapbox.com`. Configure additional trusted style hosts through OutSystems Extensibility Configuration. Credentials in URLs, non-443 ports, fragments, HTTP and local-file URLs are rejected. Only allow hosts serving trusted styles: this entry-point policy does not inspect redirects or every resource referenced by a style.
- Native inputs are limited to approximately 4 MiB; at most 10,000 markers may exist at once, with marker IDs limited to 256 characters/bytes. Boundary batches allow 1,000 boundaries and 20,000 total vertices. Imported paths allow 2–20,000 points. Tracking stops location updates at the recording limit; call `stopPathTracking()` to retrieve the retained points. Stopping an empty recording returns an empty path with zero distance.
- Offline zooms must be between 2 and 18, with `minZoom <= maxZoom`; invalid values are rejected. Both circle and rectangle downloads are checked against a conservative bounding-box diagonal of 100 km and an estimated 50,000-tile budget (including lower zooms). This can reject large/high-zoom requests that older releases accepted. Polar and antimeridian-crossing bounds are rejected. The budget is an estimate, not a byte quota; Mapbox's tile-store constraints still apply. The consuming app should manage retained offline regions and its storage budget.
- Style URLs and underlying SDK error details are no longer included in plugin diagnostic logs.

Run `npm test` for the bridge and build-hook regressions. The `Native security regression tests` workflow also compiles/runs the Java and Swift input policy, executes the actual iOS empty-path method with a minimal host, and parses the iOS plugin sources. These checks do not replace device testing or a build of your consuming OutSystems application with its exact Cordova and Mapbox dependencies.

Cordova-style native Mapbox plugin for OutSystems mobile apps.

The plugin renders a native Mapbox map and exposes JavaScript actions through:

```javascript
window.MapboxPlugin
```

It supports inline maps, behind-WebView maps, markers, current-location movement, user tracking, offline downloads, waypoint selection, and boundary overlays.

## Actions

- `initialize(options)`
- `setViewport(options)`
- `setTouchableRects(rects)`
- `setCamera(options)`
- `flyTo(options)`
- `getCamera()`
- `getCurrentLocationAccuracy()`
- `enableUserLocation()`
- `moveToCurrentLocation(options)`
- `setUserTrackingEnabled(options)`
- `setDeviceHeadingEnabled(options)`
- `setHeadingFollowMode(options)`
- `addMarker(options)`
- `loadMarkers(markers, options)`
- `removeMarker(id)`
- `clearMarkers()`
- `loadBoundaries(boundaries, options)`
- `setBoundaryVisibility(options)`
- `clearBoundaries()`
- `startPathTracking(options)`
- `stopPathTracking()`
- `pausePathTracking()`
- `continuePathTracking()`
- `loadPath(pathData, options)`
- `clearPaths()`
- `setPathVisibility(options)`
- `downloadOfflineRegion(options)`
- `downloadOfflineRegionForRect(options)`
- `showOfflineRegion(options)`
- `deleteOfflineRegion(options)`
- `onOfflineDownloadProgress(callback, errorCallback)`
- `setWaypointSelectionEnabled(options)`
- `onWaypointSelected(callback, errorCallback)`
- `onMarkerClick(callback, errorCallback)`
- `close()`

## Initialize Map

Call `initialize` once when the map screen opens.

```javascript
var dpr = window.devicePixelRatio || 1;

var topOffset = 90;
var bottomOffset = 55;
var mapHeight = window.innerHeight - topOffset - bottomOffset;

window.MapboxPlugin.close()
  .catch(function () {})
  .then(function () {
    return window.MapboxPlugin.initialize({
      behindWebView: true,
      inline: true,

      x: 0,
      y: Math.round(topOffset * dpr),
      width: Math.round(window.innerWidth * dpr),
      height: Math.round(mapHeight * dpr),

      styleUrl: $parameters.Style,

      latitude: $parameters.Latitude,
      longitude: $parameters.Longitude,
      zoom: $parameters.Zoom,
      bearing: 0,
      pitch: 0
    });
  })
  .then($resolve)
  .catch($reject);
```

For behind-WebView maps, keep the WebView/page background transparent. Android now discovers overlay touch regions automatically; iOS still requires your existing `setTouchableRects` integration. See Touch Routing below.

## Fly To

Use this when you want an animated camera transition that evokes flight, instead of the instant jump of `setCamera`. For long distances Mapbox builds the curved globe-style flight path automatically.

```javascript
window.MapboxPlugin.flyTo({
  latitude: $parameters.Latitude,
  longitude: $parameters.Longitude,
  zoom: 15,
  bearing: 0,
  pitch: 0,
  duration: 2000
})
  .then($resolve)
  .catch($reject);
```

`duration` is in milliseconds. When omitted, the SDK computes a suitable flight duration from the distance. The promise resolves when the animation starts, matching `setCamera`.

## Move To Current Location Once

Use this when you want the map to move to the user location once, without continuous tracking.

```javascript
window.MapboxPlugin.enableUserLocation()
  .then(function () {
    return window.MapboxPlugin.moveToCurrentLocation({
      zoom: 15
    });
  })
  .then($resolve)
  .catch($reject);
```

This is different from tracking. The user can still drag the map away after this call.

## Current Location Accuracy

`getCurrentLocationAccuracy()` returns the latest valid location accuracy:

```javascript
window.MapboxPlugin.getCurrentLocationAccuracy()
  .then(function (result) {
    // result.accuracy is the estimated horizontal uncertainty in meters.
    // result.accuracyLabel is a human-readable accuracy bucket.
    console.log(result.accuracy, result.accuracyLabel);
  })
  .catch($reject);
```

**Returned value:** `{ accuracy: number, accuracyLabel: string }`

`accuracy` is an estimated radius of uncertainty in **meters**, not a percentage.
The Android implementation uses the best recent GPS or network location (up to 30
seconds old). If permission is missing, no recent location is available, or the
location has no accuracy, it returns `{ accuracy: -1, accuracyLabel: "Unknown" }`.

Labels are assigned as follows:

- `Very accurate`: up to 5 m
- `Accurate`: over 5 m and up to 15 m
- `Moderately`: over 15 m and up to 30 m
- `Low`: over 30 m and up to 100 m
- `Poor`: over 100 m

## User Tracking

Use tracking only when the map should continue following the user.

```javascript
window.MapboxPlugin.setUserTrackingEnabled({
  enabled: true
})
  .then($resolve)
  .catch($reject);
```

Disable tracking when the user should be free to move the map without it snapping back:

```javascript
window.MapboxPlugin.setUserTrackingEnabled({
  enabled: false
})
  .then($resolve)
  .catch($reject);
```

## Boundary Overlays

Load boundaries after `initialize` succeeds. Do not initialize the map again just to show or hide boundaries.

Accepted boundary format:

```json
[
  {
    "Id": 90838863,
    "geometry": [
      { "lat": 17.6807217, "lon": 83.2492601 },
      { "lat": 17.6817917, "lon": 83.2522383 },
      { "lat": 17.6812552, "lon": 83.2549626 }
    ]
  }
]
```

Records without a valid `geometry` array are skipped.

### Load Boundaries

```javascript
var boundaryData = typeof $parameters.BoundaryJson === "string"
  ? JSON.parse($parameters.BoundaryJson)
  : $parameters.BoundaryJson;

window.MapboxPlugin.loadBoundaries(boundaryData, {
  visible: true,
  fillColor: "#2E7D32",
  fillOpacity: 0.18,
  lineColor: "#FF0000"
})
  .then($resolve)
  .catch($reject);
```

### Show Or Hide Boundaries

Call this from your enable/disable button.

```javascript
window.MapboxPlugin.setBoundaryVisibility({
  visible: $parameters.IsVisible
})
  .then($resolve)
  .catch($reject);
```

### Clear Boundaries

```javascript
window.MapboxPlugin.clearBoundaries()
  .then($resolve)
  .catch($reject);
```

## Path Tracking

Path tracking lets you record the user's GPS movement as a visible polyline on the map. This is useful for hunt tracking, running routes, or any scenario where you need a trail of where the user has been.

### Start Path Tracking

Begins recording GPS points and drawing a live trail on the map. Optionally enables camera tracking at the same time.

```javascript
window.MapboxPlugin.startPathTracking({
  lineColor: "#FF0000",    // optional, default "#FF0000"
  lineWidth: 3.0,          // optional, default 3.0
  lineOpacity: 0.8,        // optional, default 1.0
  trackCamera: "true"      // optional, default "true" — also enable camera following
})
  .then($resolve)
  .catch($reject);
```

### Stop Path Tracking

Stops recording and returns all collected points so you can persist them.

```javascript
window.MapboxPlugin.stopPathTracking()
  .then(function (result) {
    // result.points = [{lat: 17.680, lon: 83.249}, ...]
    // result.distance = 1234.5  (meters)
    // result.duration = 45000   (milliseconds)
    // result.segments = [{startIndex: 0, endIndex: 50}, {startIndex: 51, endIndex: 100}]
    // result.segmentCount = 2

    // Save to your OutSystems database here
  })
  .catch($reject);
```

### Pause Path Tracking

Temporarily pauses GPS collection and line drawing. The tracking session stays active but no points are collected or drawn while paused.

```javascript
window.MapboxPlugin.pausePathTracking()
  .then(function (result) {
    // result.status = "paused"
    // result.segmentCount = 1 (segments completed so far)
  })
  .catch($reject);
```

### Continue Path Tracking

Resumes GPS collection after a pause. Starts a new line segment from the current position (visual gap between paused sections).

```javascript
window.MapboxPlugin.continuePathTracking()
  .then(function (result) {
    // result.status = "continued"
    // result.segmentCount = 2 (total segments including the new one)
  })
  .catch($reject);
```

**Pause/Continue Flow:**
```
Start → line segment A drawn
  Pause → line stops, no GPS collected
  Continue → new line segment B starts from current position
  Pause → line stops again
  Continue → new line segment C starts
Stop → returns all points + segment boundaries
```

The `segments` array in the stop result tells you where each segment starts/ends in the flat points array:
```json
{
  "points": [{"lat": 1, "lon": 2}, ..., {"lat": 5, "lon": 6}],
  "segments": [
    {"startIndex": 0, "endIndex": 50},
    {"startIndex": 51, "endIndex": 100},
    {"startIndex": 101, "endIndex": 150}
  ],
  "segmentCount": 3
}
```

### Load a Pre-recorded Path

Draws a path from saved coordinates. Use this to display a past hunt track.

```javascript
window.MapboxPlugin.loadPath({
  points: [
    { lat: 17.680, lon: 83.249 },
    { lat: 17.681, lon: 83.250 },
    { lat: 17.682, lon: 83.251 }
  ],
  lineColor: "#FF0000",    // optional, default "#FF0000"
  lineWidth: 3.0,          // optional, default 3.0
  lineOpacity: 0.8         // optional, default 1.0
})
  .then($resolve)
  .catch($reject);
```

### Clear Paths

Removes all drawn paths from the map.

```javascript
window.MapboxPlugin.clearPaths()
  .then($resolve)
  .catch($reject);
```

### Show Or Hide Paths

Toggle path visibility without removing it.

```javascript
window.MapboxPlugin.setPathVisibility({
  visible: true
})
  .then($resolve)
  .catch($reject);
```

### OutSystems Integration Example

**Start hunt:**
```javascript
window.MapboxPlugin.startPathTracking({ lineColor: "#FF0000" })
```

**Pause hunt (e.g., user takes a break):**
```javascript
window.MapboxPlugin.pausePathTracking()
```

**Continue hunt (resume after break):**
```javascript
window.MapboxPlugin.continuePathTracking()
```

**Stop hunt and save:**
```javascript
window.MapboxPlugin.stopPathTracking()
  .then(function (result) {
    // In a Client Action, call a Server Action to save:
    //   SaveHuntTrack(result.points, result.distance, result.duration, result.segments)
    // The Server Action stores to your Entity/Database
  })
```

**View past hunt:**
```javascript
// Fetch saved points from your database, then:
window.MapboxPlugin.loadPath({
  points: $parameters.SavedPoints
})
```

## Markers

### Add One Marker

```javascript
window.MapboxPlugin.addMarker({
  id: $parameters.Id,
  latitude: $parameters.Latitude,
  longitude: $parameters.Longitude
})
  .then($resolve)
  .catch($reject);
```

### Load Many Markers

```javascript
window.MapboxPlugin.loadMarkers($parameters.Markers, {
  replace: true
})
  .then($resolve)
  .catch($reject);
```

### Marker Click Callback

```javascript
window.MapboxPlugin.onMarkerClick(function (event) {
  console.log("Marker clicked", event.id, event.latitude, event.longitude);
});
```

## Touch Routing

On Android, a gesture starting in an overlay exclusion rectangle stays with the WebView. Otherwise it goes to native Mapbox only when it starts inside the laid-out map rectangle. Touches outside the map stay with the WebView. The chosen target keeps the entire gesture, including movement outside its original rectangle.

### Automatic Android overlay regions

`initialize({ behindWebView: true, ... })` starts plugin-owned DOM tracking by default on Android. No separate OutSystems touch script is needed. It tracks standard interactive HTML controls and roles, OutSystems bottom sheets, popups, modals and sidebars, `.map-touchable`, `.map-touch-region`, `[data-map-touch-region]`, and inline `cursor: pointer` tag controls inside `.tags-container`.

- Keep your existing map initialization and `setViewport`/`resizeMap` calls. Automatic tracking discovers overlays only; it does not infer which DOM element is your map container.
- Mark custom clickable or draggable containers with the `map-touch-region` class. Do not put this class on the map container or the whole screen unless all touches there should go to the WebView.
- Rectangles are clipped to the viewport and scroll containers, converted from CSS coordinates to native pixels using device pixel ratio, and deduplicated. Hidden and `pointer-events: none` controls are excluded.
- The plugin updates regions after DOM changes, scrolling, resizing, loads, and relevant CSS animations/transitions. It disconnects observers and listeners on `close()`, reinitialization, or page exit. Call `close()` when leaving the map screen in an OutSystems single-page navigation flow.
- Updates are serialized and failed updates are retried. If more than 50 independent regions remain, the plugin temporarily routes the entire viewport to the WebView and warns in the console. Group related controls under `map-touch-region` to reduce the count and restore map gestures.
- Normal WebView events handle clicks. The plugin does not simulate `.click()` or intercept DOM touch events. Controls must be reachable through normal DOM hit testing; check overlapping elements and `pointer-events` if a custom control still fails.

After rebuilding the Android app with this version, disable/remove the old standalone touch script. Its `window.__mapboxTouchBridge.stop()` is also called at automatic initialization if present, but the old script must not run again afterward. Keep the old integration on iOS; automatic tracking is Android-only.

Test map pan/pinch, tags, bottom-sheet drags, popup backdrops, scrolling, rotation, and repeated open/close on a physical Android device. DOM/bridge tests do not replace device testing.

### Manual regions and compatibility

Set `autoTouchRouting: false` in Android initialization to retain manual control. Calling `setTouchableRects` explicitly also stops automatic tracking until the next initialization, so manual and automatic writers do not overwrite each other. The existing method and native-pixel coordinate convention remain supported. iOS behavior is unchanged.

```javascript
var dpr = window.devicePixelRatio || 1;
window.MapboxPlugin.setTouchableRects([
  {
    x: 0,
    y: 0,
    width: window.innerWidth * dpr,
    height: 90 * dpr
  },
  {
    x: 0,
    y: (window.innerHeight - 55) * dpr,
    width: window.innerWidth * dpr,
    height: 55 * dpr
  }
])
  .then($resolve)
  .catch($reject);
```

## Token Handling

The Mapbox access token is configured once through OutSystems extensibility configuration. It never crosses the JavaScript bridge: passing `token` in `initialize()` is ignored for security and never reaches native.

```json
{
  "plugin": {
    "url": "https://github.com/devnandagopaljb/cordova-mapbox-outsystems.git",
    "variables": [
      {
        "name": "MAPBOX_ACCESS_TOKEN",
        "value": "pk.your_public_runtime_token_here"
      }
    ]
  }
}
```

## OutSystems Setup

1. Push this folder to a Git repository.
2. Add the plugin repository URL to the mobile app extensibility configuration.
3. Create OutSystems Client Actions that call the JavaScript examples above.
4. Generate the Android/iOS mobile app.
5. Test on a real device.

## SDK Versions

- Android uses Mapbox Maps `11.20.2` by default.
- iOS uses Mapbox Maps `~> 11.0`.
- iOS reads the token natively and assigns it via `MapboxOptions.accessToken`.

## Android Size Reduction

The Android build filters native libraries to production device ABIs by default:

```text
arm64-v8a,armeabi-v7a
```

Override this in OutSystems only when needed:

```json
{
  "name": "MAPBOX_ANDROID_ABIS",
  "value": "arm64-v8a"
}
```

For emulator testing, include `x86_64`:

```json
{
  "name": "MAPBOX_ANDROID_ABIS",
  "value": "arm64-v8a,armeabi-v7a,x86_64"
}
```

## Notes

- Call `initialize` once per map screen load.
- Call `loadBoundaries` after `initialize`.
- Use `setBoundaryVisibility` for show/hide. Do not reinitialize the map for boundary toggles.
- Use `moveToCurrentLocation` for a one-time move to user location.
- Use `setUserTrackingEnabled` only when the map should keep following the user.
- Background location tracking is not part of the Mapbox map view. Add a background geolocation plugin or native background location feature for that use case.
