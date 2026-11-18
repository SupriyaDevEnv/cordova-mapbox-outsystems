# Offline maps: plugin actions to implement

Plugin changes needed for the offline-maps design (Select area, Download options,
Offline confirmation, Update downloaded, Offline landing, Offline map view, Details).

The list of downloaded maps is stored in the app database, not in the plugin.
Each change below applies to Android (`src/android`), iOS (`src/ios`), the
JavaScript wrapper (`www/MapboxPlugin.js`) and `README.md`.

## Needed now

### 1. Return more from the download calls
`downloadOfflineRegion` and `downloadOfflineRegionForRect` should resolve with:
- `regionId`
- size on disk in bytes (shown as "340 MB" in the lists)
- downloaded area (bounds, plus polygon when one was used)
- `minZoom` / `maxZoom` actually used
- download date

The app saves these in its database row for the map.

### 2. Download by area
`downloadOfflineRegion` accepts `bounds` (`south`, `west`, `north`, `east`) or a
GeoJSON polygon, alongside the current centre + `radiusKm`.
Needed for "Recommended maps" (known trail areas) and for "Update now", which
re-downloads a saved map with the same `regionId` and area. Mapbox only fetches
what changed.

### 3. `estimateOfflineRegionSize(options)`
Takes the same area and zoom options as a download and returns an approximate
size from the tile count. Feeds "Estimated download size" on Download options;
can return Low / Medium / High in one call. Mapbox has no exact pre-download
size, so this is an estimate.

### 4. `getAvailableStorage()`
Returns free space on the device in bytes (Android `StatFs`, iOS volume
available capacity). Feeds "Available storage".

### 5. `cancelOfflineDownload()`
Cancels the current download without closing the map. The pending download
rejects with the existing cancellation error (`MAPBOX_OPERATION_CANCELLED`).

### 6. `getOfflineRegionIds()`
Returns the `regionId`s actually stored on the device, so the app can remove
database rows for maps that were cleared by the user or the OS.

## Later

7. **Detail-level preset**: `detail: 'low' | 'medium' | 'high'` mapped to `maxZoom`
   inside the plugin, the same on both platforms.
8. **Better progress events**: percentage and approximate MB downloaded.
9. **Lock `showOfflineRegion` to the downloaded region**: limit camera centre and
   zoom so users cannot pan to areas without offline tiles.
10. **Marker images offline**: option to cache custom marker images with a download.

## App side (not plugin work)

- "Looks like you are offline" detection (network-status plugin).
- Recommended trails list (backend).
- Database table of downloaded maps: `regionId`, title, description, area, zoom
  range / detail level, style URL, size, download date, data version.
- Update check: compare the stored data version or date with the backend.
- Toasts, "Offline" badge, filter chips, Map Details and trail Details sheets,
  caching trail photos.

## Keeping the database in step

- Write the row only after the download succeeds.
- Delete in this order: `deleteOfflineRegion`, then the row.
- On the offline screens, call `getOfflineRegionIds()` and drop rows whose region
  is gone.
- The plugin stores at most 20 regions: disable "Download new offline map" at 20.
- Generate `regionId` in the app (for example `trail-<id>`) and use it everywhere.
