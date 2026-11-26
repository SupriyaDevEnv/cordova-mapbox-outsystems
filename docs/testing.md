# Testing

These checks complement the automated tests. Run them on physical Android and iOS devices with a fresh native build: publishing screen JavaScript alone does not update native code.

## Automated tests

From a development Git checkout, run `npm test` for the bridge and build-hook regressions. The `Native security regression tests` workflow also compiles/runs the Java and Swift input policy, executes the actual iOS empty-path method with a minimal host, and parses the iOS plugin sources. These checks do not replace device testing or a build of your consuming OutSystems application with its exact Cordova and Mapbox dependencies.

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
