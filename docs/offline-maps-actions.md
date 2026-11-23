# Offline maps: plugin actions

Plugin changes for the offline-maps design (Select area, Download options,
Offline confirmation, Update downloaded, Offline landing, Offline map view, Details).

The list of downloaded maps is stored in the app database, not in the plugin.
Each change applies to Android (`src/android`), iOS (`src/ios`), the JavaScript
wrapper (`www/MapboxPlugin.js`) and `README.md`. See the README offline section
for exact options and results.

## Status

| # | Action | Status |
|---|---|---|
| 1 | Richer download results (`sizeBytes`, `bounds`, `polygon`, zooms, `styleUrl`, `downloadedAt`) | Done |
| 2 | Download by area: `bounds` or GeoJSON `polygon` in `downloadOfflineRegion` | Done |
| 3 | `estimateOfflineRegionSize` / `estimateOfflineRegionSizeForRect` | Done |
| 4 | `getAvailableStorage` | Done |
| 5 | `cancelOfflineDownload` | Done |
| 6 | `getOfflineRegionIds` (with size and `complete` per region) | Done |
| 7 | `detail: 'low' \| 'medium' \| 'high'` → `maxZoom` 13 / 15 / 16 | Done |
| 8 | Progress with `completedBytes` / `completedMB` (`percent` already existed) | Done |
| 9 | Lock `showOfflineRegion` to the downloaded region | Not planned for now |
| 10 | Cache custom marker images with a download | Not started |

`downloadOfflineRegionForRect` gets the same richer result, `detail`, byte
progress and cancel support, and has its own estimate call.

## Screen → plugin call

- **Select area:** `estimateOfflineRegionSizeForRect`, then `downloadOfflineRegionForRect`.
- **Download options:** `estimateOfflineRegionSize*` per detail level for
  "Estimated download size"; `getAvailableStorage` for "Available storage".
- **Recommended maps:** `downloadOfflineRegion` with the trail's `polygon` or `bounds`.
- **Downloading:** `onOfflineDownloadProgress` for the progress bar;
  `cancelOfflineDownload` for Cancel.
- **Downloaded maps / offline landing:** list from the app database, cleaned with
  `getOfflineRegionIds`.
- **Update now:** `downloadOfflineRegion` with the stored `regionId`, `polygon`,
  zooms and `styleUrl`.
- **Delete:** `deleteOfflineRegion`, then remove the database row.

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
