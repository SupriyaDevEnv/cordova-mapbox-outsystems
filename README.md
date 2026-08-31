# OutSystems Mapbox Native Plugin

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

For iOS and Android behind-WebView maps, keep the WebView/page background transparent and call `setTouchableRects` for OutSystems controls that must remain clickable.

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

    // Save to your OutSystems database here
  })
  .catch($reject);
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

**Stop hunt and save:**
```javascript
window.MapboxPlugin.stopPathTracking()
  .then(function (result) {
    // In a Client Action, call a Server Action to save:
    //   SaveHuntTrack(result.points, result.distance, result.duration)
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

When the map is behind the WebView, touches are routed to the native map unless they fall inside configured clickable rectangles.

```javascript
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
