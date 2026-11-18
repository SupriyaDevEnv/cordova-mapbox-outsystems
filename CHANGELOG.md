# Changelog

## 1.0.9

- **New (iOS):** `getLayerIds`, `getLayersByGroup`, `setLayerGroupVisibility` and `diagnoseLayerGroup`, matching Android. Previously these calls never returned on iOS.
- **Security:** marker images are limited to 4096 px per side and 4 megapixels, the image cache is sized in bytes, and Android checks every redirect hop against the allowed hosts.
- **Security:** numeric options such as `"NaN"` or `"Infinity"` fall back to defaults instead of crashing iOS; camera, line width and opacity values are range-checked.
- **Build:** the plugin no longer forces R8 minification and resource shrinking on the whole Android app. `MAPBOX_ANDROID_VERSION` and `MAPBOX_ANDROID_ABIS` set in Extensibility Configuration now take effect.
- **New:** `LOCATION_USAGE_DESCRIPTION` sets the iOS location permission text.
- **Changed:** `deleteOfflineRegion` keeps the shared style pack unless `deleteStylePack: true` is passed.
- **Performance:** Android creates and deletes markers and boundaries in batches.
- **Changed:** `loadMarkers`, `loadBoundaries` and `loadPath` no longer modify the options object you pass in.
- **Changed:** `diagnoseLayerGroup` no longer writes style metadata to the Android log.

## Marker changes in earlier versions

- **Breaking:** `loadMarkers` item keys are capitalized: `Id`, `Latitude`, `Longitude`, `IsFind`. Items using `id`, `latitude`, `longitude`, or `isFind` are no longer read. Every such item falls back to an index ID and coordinates `0, 0`. `addMarker` still uses lowercase keys.
- **New:** `pinColor` / `PinColor` and `imageUrl` / `ImageUrl`.
- **New:** `isFind` pins show a magnifying-glass icon on both platforms.
- **Changed (1.0.6):** Find markers are white rounded-square cards and Waypoint markers are white circles, each with a black outline and tip, replacing the red/blue teardrop pin. Size, anchor and position are unchanged; `pinColor` colours the outline and tip; `pinStyle: "photo"` is accepted but renders the same design.
- **New:** the `MAPBOX_ALLOWED_MARKER_IMAGE_HOSTS` preference.
- **New (1.0.8):** markers without an image that send no `isFind` (plain location / search pins) or are offline (`isOnline: false`) use the classic red teardrop pin with a white dot.
- **New (1.0.7):** `isPublic` / `IsPublic`. `false` draws a lock tile for private Finds and Waypoints, so the app no longer sends a lock image.
- **New (1.0.5):** `imageBinary` / `ImageBinary` and `imageMimeType` / `ImageMimeType` for Waypoint markers. Find markers are unchanged.
