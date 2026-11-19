# Testing

These checks complement the automated tests. Run them on physical Android and iOS devices with a fresh native build: publishing screen JavaScript alone does not update native code.

## Automated tests

From a development Git checkout, run `npm test` (`node --test tests/*.test.cjs`) for the JavaScript bridge, touch-routing and source-parity regressions.

The `Native security regression tests` workflow (`.github/workflows/security-tests.yml`) runs on every pull request and push to `main` on a macOS runner with Node 22, Java 17 and Swift. After `npm test` it runs each Python test as its own step with `python3 tests/<name>.py`. These tests extract the production Java/Swift code from `src/` and compile it against a minimal host with `javac` and/or `swiftc`, so no Mapbox SDK or device is needed:

| Test | Checks |
|---|---|
| `test-style-readiness.py` | Style readiness gates: failures, timeouts and cancellation |
| `test-marker-density.py` | Android pin size and cache across screen densities |
| `test-webview-transparency.py` | Behind-WebView transparency and appearance restoration |
| `test-initialize-zoom.py` | `minZoom` / `maxZoom` parsing on both platforms |
| `check-package.py` | The `git archive` ZIP and `npm pack` tarball contain exactly the build inputs |
| `test-empty-path.py` | Stopping an empty iOS path recording |
| `test-session-guards.py` | Callbacks from an old map session are dropped on both platforms |
| `test-teardown.py` | Delayed native marker taps and cleanup failures |
| `test-ios-touch-routing.py` | iOS touch coordinates and map boundaries |
| `test-ios-camera-follow.py` | iOS camera follow during manual gestures |
| `test-recenter-location.py` | Android recenter location age and accuracy |
| `test-shared-location.py` | Shared location waiting and cancellation |
| `test-android-camera-recenter.py` | Android recenter against the camera follow ticker |

The workflow also compiles and runs the Java and Swift input policies (`tests/MapboxSecurityTest.java`, `tests/security-main.swift`), parses every iOS source with `swiftc -frontend -parse`, and builds clean Cordova Android and iOS apps with the plugin.

To run a Python test locally, run it from the repository root, for example `python3 tests/test-teardown.py`. The native tests need `javac`, and those that cover iOS need `swiftc` (macOS). `check-package.py` archives the committed `HEAD`, so commit first. These checks do not replace device testing or a build of your consuming OutSystems application with its exact Cordova and Mapbox dependencies.

## Style loading

Verify slow/failed style loads, immediate layer toggles, close during loading, reopen and later style changes on both devices before UAT acceptance.

## Closing and reopening the map

On both platforms test: exit during initialization, permission prompts, marker downloads and pinch/pan; tap where the map used to be; reopen repeatedly with the same marker IDs; confirm no old events; confirm independent background tracking continues; and verify the rest of the WebView remains interactive.

## Touch routing

Keep existing OutSystems initialization JS, including `autoTouchRouting: false`, unchanged when map controls use `.map-control-btn`.

1. Tap each map control and verify its OutSystems action fires once. Pan, pinch and rotate in the map area between controls.
2. Start a drag on a control or an automatically discovered sheet and move outside its original bounds; verify the gesture stays with its starting target. Broad sheet discovery requires the default automatic mode.
3. Navigate away and back repeatedly, then close/reinitialize. Verify replacement buttons work, removed buttons leave no stale touch exclusions, and map/marker callbacks fire only for the current session.
4. Open/close overlays, scroll, and rotate the device. Verify control bounds update. For manual routing, call `setTouchableRects` and verify automatic updates stop until reinitialization.

The JavaScript regression suite exercises both platform configurations and lifecycle races with a simulated DOM/bridge. Native CI checks and device checks are separate; passing the JavaScript suite does not establish end-to-end device behavior.

## Removing markers

Add two markers (including an image marker), click both, remove one while its image is loading, and confirm only the remaining marker still produces clicks. Repeat removal, try an unknown ID and invalid IDs, then re-add the removed ID.

## Many marker photos

Load about 100 Waypoint markers with camera photos in one `loadMarkers` call. All pins should appear at once and photos fill in over the next seconds while the map stays usable. Remove one marker and clear the map while photos are still filling in: removed markers must not come back.

## Long path recordings

Record for 30 minutes or more (or simulate over 1,000 GPS fixes). The line must stay continuous across the 500-point pieces, the map must not get slower, and hide/show, pause/continue and stop must show the whole line.

## Offline limits

Download with `wifiOnly: true` on mobile data and confirm no tiles download until Wi-Fi is available. Download 20 regions, then confirm a 21st fails with the limit message and re-downloading an existing region still works.

## Style layers

On both platforms: call `getLayerIds()` after `initialize` resolves; call `getLayersByGroup` and `setLayerGroupVisibility` with a real Mapbox Studio folder name and confirm its layers hide and show; confirm an unknown group returns an error rather than waiting forever.
