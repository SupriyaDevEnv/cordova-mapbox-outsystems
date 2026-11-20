# Changelog

## Unreleased

- **Changed:** `showOfflineRegion({ regionId })` constrains the camera center to the saved region bounds and zoom range on Android and iOS.
- **Changed:** removed `diagnoseLayerGroup` and `getLayerIds` from the Android and iOS APIs.
- **Changed:** iOS `setLayerGroupVisibility` reports per-layer failures and partial updates like Android.
- **New:** `downloadOfflineRegion` accepts `bounds` (`{ south, west, north, east }`) or a GeoJSON `polygon` to download a known area, such as a recommended trail, instead of a centre and radius.
- **New:** `downloadOfflineRegion` and `downloadOfflineRegionForRect` resolve with `sizeBytes`, `bounds`, `polygon` (the exact area downloaded), `minZoom`, `maxZoom`, `styleUrl` and `downloadedAt`, alongside the existing `regionId`, `latitude`, `longitude` and `radiusKm`.
- **New:** `estimateOfflineRegionSize` and `estimateOfflineRegionSizeForRect` return an approximate tile count and download size, and whether the download would be within the limits.
- **New:** `getAvailableStorage` returns free and total device storage.
- **New:** `cancelOfflineDownload` stops the current download without closing the map; the download rejects with a cancellation error.
- **New:** `getOfflineRegionIds` lists the regions stored on the device, with size and whether each finished.
- **New:** `detail: 'low' | 'medium' | 'high'` sets the download zoom (13, 15 or 16) for downloads and estimates.
- **New:** offline progress events include `completedBytes` and `completedMB`.
- **New:** `showOfflineRegion({ regionId })` opens a downloaded region by id: it centres on the region, fits it on screen within the downloaded zooms and loads the style it was downloaded with. Downloads now save their style URL and zoom range for this. Calls without `regionId` are unchanged.

## 1.0.10

- **New:** mark the element the map shows through with `data-mapbox-map`, and behind-WebView touch routing gives the page every touch on anything drawn over the map: clickable containers, cards, chips, scrollable rows, labels and custom bottom sheets, not only buttons, links and known OutSystems classes. Transparent wrappers still let touches through to the map. Without the attribute, tracking is unchanged.
- **Changed:** Android and iOS accept up to 256 overlay regions, up from 50 on Android and 20 on iOS. Beyond the limit, neighbouring regions are merged instead of routing the whole screen to the WebView, so map gestures no longer stop working on busy screens.
- **New:** `docs/touch-routing-demo.html`, a browser simulation that compares the two tracking modes on a map screen.

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
- **Performance:** `loadMarkers` with many Waypoint photos draws every marker at once, converts photos one at a time and fills them in as they finish, instead of waiting for all photos and decoding four at once.
- **Memory (Android):** marker pins are drawn at the size they are shown, using a quarter of the memory per pin. Pins look the same.
- **Changed:** marker images (URLs and data URIs) are limited to 256 KiB, down from 1 MiB. Serve thumbnails of about 256 px; larger files show a plain pin.
- **New:** `wifiOnly` option for offline downloads, and a limit of 20 stored offline regions.
- **Performance:** a long path recording redraws only its newest 500 points on each GPS fix.

## Marker changes in earlier versions

- **Breaking:** `loadMarkers` item keys are capitalized: `Id`, `Latitude`, `Longitude`, `IsFind`. Items using `id`, `latitude`, `longitude`, or `isFind` are no longer read. Every such item falls back to an index ID and coordinates `0, 0`. `addMarker` still uses lowercase keys.
- **New:** `pinColor` / `PinColor` and `imageUrl` / `ImageUrl`.
- **New:** `isFind` pins show a magnifying-glass icon on both platforms.
- **Changed (1.0.6):** Find markers are white rounded-square cards and Waypoint markers are white circles, each with a black outline and tip, replacing the red/blue teardrop pin. Size, anchor and position are unchanged; `pinColor` colours the outline and tip; `pinStyle: "photo"` is accepted but renders the same design.
- **New:** the `MAPBOX_ALLOWED_MARKER_IMAGE_HOSTS` preference.
- **New (1.0.8):** markers without an image that send no `isFind` (plain location / search pins) or are offline (`isOnline: false`) use the classic red teardrop pin with a white dot.
- **New (1.0.7):** `isPublic` / `IsPublic`. `false` draws a lock tile for private Finds and Waypoints, so the app no longer sends a lock image.
- **New (1.0.5):** `imageBinary` / `ImageBinary` and `imageMimeType` / `ImageMimeType` for Waypoint markers. Find markers are unchanged.
