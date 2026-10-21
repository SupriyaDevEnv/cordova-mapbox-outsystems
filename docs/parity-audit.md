# Android / iOS parity audit (Phase 1, no code changed)

Repo HEAD at audit time: `e98c945` (2026-10-21). Version `1.0.4-close-cleanup.1`. Mapbox SDK pinned to 11.30.0 on both platforms.

Tags: **[C]** = confirmed from code/config I read; **[I]** = inference (not verifiable from the repo alone).

File abbreviations (all paths under `src/`):
- `Entry` = android/MapboxPluginEntry.java, `PermA` = android/MapboxPluginPermissionEntry.java, `SecA` = android/MapboxSecurity.java, `IconsA` = android/MarkerIcons.java
- `Plugin` = ios/MapboxPlugin.swift, `Parity` = ios/MapboxPluginParity.swift, `PermI` = ios/MapboxPluginPermissionParity.swift, `SecI` = ios/MapboxSecurity.swift, `IconsI` = ios/MarkerIcons.swift

## 1. Headline result

- **[C] Action names match 1:1.** Android's `executeOnUiThread` switch (`Entry:288-453`) handles 46 action strings. iOS exposes the same 46 through `@objc(name:)` selectors across `Plugin`, `Parity` and `PermI`. There is **no Android-only and no iOS-only action**.
- **[C] Every function exported by `www/MapboxPlugin.js` maps to one of those 46 actions**, except two JS-only helpers (`diagnostic`, `isCancellationError`) which have no native counterpart by design. `registerCloseCallback` is called only internally by the JS bridge (`observeNativeClose`), not exported.
- The real gaps are **behavioral**: different timing, validation, error text, option coercion and location-pipeline behavior (section 4). Android is the richer baseline for location tracking (accuracy gate, jump rejection, movement classifier); iOS is the richer one for strict id validation and color fallback. I did not find a single platform that is the baseline everywhere.

## 2. Parity matrix (by action)

Status: **Both** = equivalent for callers (trivial differences noted), **Divergent** = caller-visible difference, see Gap ID in section 4.

| Action | JS function | Android (file:line) | iOS (file:line) | Status | Notes |
|---|---|---|---|---|---|
| registerCloseCallback | internal (`observeNativeClose`) | Entry:289 | Plugin:51 | Both | G21 close payload: Android none, iOS `{closed:true}` |
| ping | ping | Entry:294 | Plugin:121 | Both | `class` value differs ("MapboxPluginEntry" vs "MapboxPlugin"), trivial |
| getMapboxVersion | getMapboxVersion | Entry:305 | Parity:29 | Divergent | G09 |
| initialize | initialize | Entry:469 | Plugin:144 | Divergent | G01, G02, G19 |
| setViewport | setViewport | Entry:673 | Plugin:368 | Divergent | G03 |
| resizeMap | resizeMap | Entry:686 | Parity:40 | Divergent | G03 |
| setTouchableRects | setTouchableRects | Entry:735 | Plugin:400 | Divergent | G04; caps 50/20 intentional |
| setCamera | setCamera | Entry:780 | Plugin:279 | Both | partial-update semantics identical [C] |
| flyTo | flyTo | Entry:806 | Plugin:331 | Both | iOS accepts `duration` only if numeric; Android coerces strings (G02 family) |
| resetMapBearing | resetMapBearing | Entry:2451 | Plugin:313 | Both | 400 ms ease on both |
| enableUserLocation | enableUserLocation | Entry:844 (gate PermA:44) | Plugin:419 (gate PermI:22) | Both | Android also runs a one-shot bootstrap fix [C]; both fire tracking status |
| setDeviceHeadingEnabled | setDeviceHeadingEnabled | Entry:931 (gate PermA:45) | Plugin:437 (gate PermI:28) | Both | G02 for `enabled` coercion |
| setHeadingFollowMode | setHeadingFollowMode | Entry:966 | Plugin:462 (gate PermI:34) | Divergent | G08b; sensor vs CLHeading, intentional |
| setUserTrackingEnabled | setUserTrackingEnabled | Entry:1093 / startUserTracking Entry:1363 (gate PermA:46) | Plugin:489, Parity:109, PermI:40 | Divergent | G06, G02 |
| moveToCurrentLocation | moveToCurrentLocation | Entry:1748 (gate PermA:48) | Plugin:512, Parity:137, PermI:46 | Divergent | G05 |
| downloadOfflineRegion | downloadOfflineRegion | Entry:1913 | Plugin:1197 | Divergent | G10 |
| downloadOfflineRegionForRect | downloadOfflineRegionForRect | Entry:1962 | Plugin:1251 | Divergent | G10; both treat x/y/width/height as native pixels [C] |
| showOfflineRegion | showOfflineRegion | Entry:2206 | Plugin:1475 | Both | iOS silently falls back to `.streets` if `StyleURI(rawValue:)` fails (Plugin:1500); G10 |
| deleteOfflineRegion | deleteOfflineRegion | Entry:2238 | Plugin:1511 | Both | `regionId` string-only on iOS (G10) |
| registerOfflineDownloadProgressCallback | onOfflineDownloadProgress | Entry:2269 | Plugin:1562 | Both | payload identical, 100 ms rate limit on both [C] |
| setWaypointSelectionEnabled | setWaypointSelectionEnabled | Entry:2294 | Plugin:1538 | Both | G02, G13 |
| registerWaypointSelectedCallback | onWaypointSelected | Entry:2301 | Plugin:1548 | Both | payload `{type:"waypointSelected", id, latitude, longitude}` on both [C]; G13 |
| registerMarkerClickCallback | onMarkerClick | Entry:2309 | Plugin:1555 | Both | registration same; event payload mismatch with README on both platforms: G12 |
| registerTrackingStatusCallback | onTrackingStatusChanged | Entry:2317 | Plugin:1569 | Both | payload keys identical [C] |
| registerLocationAccuracyCallback | onLocationAccuracyChanged | Entry:2326 (gate PermA:49) | Parity:48 (not in PermI gate) | Divergent | G08 |
| registerCompassCallback | onCompassChanged | Entry:2383 | Plugin:1577 | Both | `{bearing, visible}` on both [C] |
| getCamera | getCamera | Entry:3597 | Plugin:1875 | Both | same five fields |
| getCurrentLocationAccuracy | getCurrentLocationAccuracy | Entry:3618 | Parity:75 | Both | same shape and labels; implementations differ (G14) |
| addMarker | addMarker | Entry:2734 | Plugin:745 | Divergent | documented differences, G15 |
| loadMarkers | loadMarkers | Entry:2775 | Plugin:792 | Divergent | documented differences, G15 |
| removeMarker | removeMarker | Entry:2958 | Plugin:836 | Divergent | documented quirk (numeric ids), G15 |
| clearMarkers | clearMarkers | Entry:2979 | Plugin:850 | Both | |
| loadBoundaries | loadBoundaries | Entry:3000 | Plugin:859 | Divergent | G16 |
| setBoundaryVisibility | setBoundaryVisibility | Entry:3054 | Plugin:887 | Both | G02 |
| setLayerVisibility | setLayerVisibility | Entry:3062 | Parity:175 | Divergent | G17 |
| getLayerIds | getLayerIds | Entry:3109 | Parity:218 | Both | returns array on both |
| clearBoundaries | clearBoundaries | Entry:3138 | Plugin:899 | Both | |
| startPathTracking | startPathTracking | Entry:3289 (gate PermA:47) | Plugin:936, Parity:121, PermI:52 | Divergent | G02 (`trackCamera` parsing), G18 |
| stopPathTracking | stopPathTracking | Entry:3330 | Plugin:974, Parity:129 | Both | same result shape [C] |
| pausePathTracking | pausePathTracking | Entry:3399 | Plugin:1029 | Both | |
| continuePathTracking | continuePathTracking | Entry:3436 | Plugin:1064 | Both | |
| loadPath | loadPath | Entry:3462 | Plugin:1088 | Divergent | G16 |
| clearPaths | clearPaths | Entry:3538 | Plugin:1156 | Both | |
| setPathVisibility | setPathVisibility | Entry:3555 | Plugin:1168 | Both | G02 |
| close | close | Entry:3754 (closeInternal Entry:3810) | Plugin:1895 (closeInternal Plugin:1935) | Both | cleanup lists equivalent [C] |
| setMapStyle | setMapStyle | Entry:3761 | Plugin:1903 | Divergent | G01, G20 |

## 3. Non-action parity (config, security, gating, touch)

| Area | Android | iOS | Status | Notes |
|---|---|---|---|---|
| Feature class registered in plugin.xml | `MapboxPluginPermissionEntry` (plugin.xml:36) | `MapboxPluginPermissionParity` (plugin.xml:63) | Both | outermost subclass on each side [C] |
| Source files listed in plugin.xml | SecA, IconsA, Entry, PermA (plugin.xml:54-57) | SecI, IconsI, Plugin, Parity, PermI (plugin.xml:85-89) | Both | no omissions [C] |
| Config preferences injected | token, style hosts, marker image hosts (plugin.xml:41-43) | same three (plugin.xml:69-71) | Both | |
| Permissions | INTERNET, ACCESS_NETWORK_STATE, FINE and COARSE location | `NSLocationWhenInUseUsageDescription` only | Both | no iOS equivalent needed for network state. Usage string is product-specific ("Realm Mapping ...") [C] |
| Location permission gate list | enableUserLocation, setDeviceHeadingEnabled, setUserTrackingEnabled, startPathTracking, moveToCurrentLocation, registerLocationAccuracyCallback (PermA:43-50) | enableUserLocation, setDeviceHeadingEnabled, setHeadingFollowMode, setUserTrackingEnabled, moveToCurrentLocation, startPathTracking (PermI:9-16) | Divergent | G08, G08b |
| Pending-queue cap | 32 actions and 4 MiB (PermA:32) | 32 actions (PermI:108) | Both | error text differs slightly |
| Public-token / style-URL policy | `SecA.publicToken/styleAllowed` | `SecI.publicToken/styleAllowed` | Both | regexes equal; length measured in UTF-16 chars (Java) vs UTF-8 bytes (Swift), G22 |
| Marker image policy | `SecA.markerImageAllowed` (SecA:33) | `SecI.markerImageAllowed` (SecI:25) | Both | same data-URI rules and host handling [C] |
| Offline budget math | `SecA.offlineBounds` | `SecI.offlineBounds` | Both | identical formulas; zoom type handling differs (G10) |
| Touch-region caps | 50 (Entry:746, AndroidTouchRegions.js:25) | 20 (Plugin:406, AndroidTouchRegions.js:25) | Divergent, intentional | documented in README |
| Behind-WebView gesture handling | raw `MotionEvent`s forwarded to the MapView (Entry:3989-4041) | overlay view with only pan, pinch, rotation and tap recognizers (Plugin:2123-2144) | Divergent | G23 |
| Lifecycle | `onPause`/`onResume` stop/start MapView (Entry:4150-4167) | none (UIKit manages MapView) | Divergent, intentional | platform difference |
| Input size gate | one global check for every action (Entry:279) | per-method `validInput` (Plugin:2065) | Divergent | G19 |
| Marker pin rendering | density-aware canvas (IconsA:165-172) | `format.scale = 1` (IconsI:172) | Divergent, test-enforced | tests/parity.test.cjs:66 asserts `format.scale = 1`; README 75-81 says "iOS marker sizing is unchanged" |
| Marker image redirects | final URL checked after redirects were followed (IconsA:117-119) | each redirect checked before it is followed (IconsI:129-136) | Divergent | G24 (security hardening candidate) |
| CI coverage | `javac` + run `MapboxSecurityTest` only | `swiftc -frontend -parse` of all iOS sources + run `security-main.swift` | Divergent | neither platform's native code is fully compiled in CI; Java test lacks zoom lower-bound checks that the Swift test has |

## 4. Gap register

Intent legend: **Intentional** (commented or platform-forced), **Documented** (README states it), **Accidental** (no evidence of intent), **Unclear**.
"Align to" is only a suggestion for Phase 2.

| ID | Gap | Evidence | Intent | Align to | Risk if left |
|---|---|---|---|---|---|
| G01 | `initialize` and `setMapStyle` resolve at different times: Android after the style has loaded, iOS right after creating the map. | Entry:629-650, Entry:3779-3791 vs Plugin:275, Plugin:1923-1924 [C] | Accidental | iOS to wait for style load. iOS API for that in 11.30.0 is **unverified**, must be confirmed in Phase 2 | OutSystems logic that adds markers/layers right after `initialize` can race on iOS. Layer calls then fail with "Style is not loaded yet." (Parity:227 area) |
| G02 | Boolean/number option coercion. Android `optBoolean/optDouble/optString` accept strings like `"false"`, `"12"`. iOS uses `as? Bool` for `enabled`, `visible`, `replace`, `isFind`, `IsFind`, `autoAddMarker`, `deleteStylePack`, `inline`, `behindWebView`, and `as? Double` for `lineWidth/lineOpacity`, `duration`. Only `trackCamera` uses the tolerant `boolOption` (Plugin:2300). Android's `trackCamera` check is `optString("trackCamera","true").equals("true")` (Entry:3315), so `"TRUE"` or `1` count as false on Android but not on iOS. | e.g. Entry:1100 vs Plugin:500; Entry:3562 vs Plugin:1179 [C] | Accidental (README only promises this for `trackCamera`, line 149) | Make iOS use `boolOption/doubleOption` everywhere; make Android `trackCamera` use the same rules | OutSystems often passes booleans as strings; `enabled:"false"` disables on Android but is ignored (treated as true) on iOS |
| G03 | `setViewport` on Android only applies x/y/width/height when `inline:true` is also passed; otherwise it becomes MATCH_PARENT (Entry:4053-4059). iOS applies the rect regardless (Plugin:379). `resizeMap` is a different code path on Android (adds WebView offset, defaults 1x1, no clamping, Entry:686-733) but is an alias of `setViewport` on iOS (Parity:40-46). Android also clamps rects to the screen, iOS does not. | listed line refs [C] | Unclear | Decide one contract, then align (needs your call) | Same JS call yields different map frames per platform |
| G04 | `setTouchableRects`: Android clears the stored list before checking the count (Entry:737 vs 748), so an over-limit call wipes existing exclusions. iOS keeps the old rects on error (Plugin:407-410). iOS skips the 4 MiB input check on this action. Caps 50/20 themselves are intentional. | [C] | Accidental (clear-before-check) | Android: validate before clearing | Low; JS auto-routing already degrades to one full-viewport rect above the cap |
| G05 | `moveToCurrentLocation`: Android uses a 5 s fused `getCurrentLocation`, flies with an animation, and errors with "Location provider is not enabled." / "Unable to get current location." (Entry:1768-1880). iOS starts continuous updates with no timeout, snaps the camera without animation only if camera-following is still on, and errors with "Failed to get current location." (Parity:137-173, 345-392). Result shape `{latitude, longitude, accuracy, accuracyLabel}` matches [C]. | [C] | Unclear (iOS "no move after gesture" is documented, README 754) | Align error text; consider a timeout on iOS | iOS call can stay pending indefinitely without a fix |
| G06 | User tracking pipeline: Android drops fixes with accuracy > 25 m, rejects speed jumps > 15 m/s, classifies stationary/slow/walking with hysteresis, uses per-state smoothing, drives the camera with a 250 ms ticker (Entry:1363-1612, 1636-1687). iOS applies fixed 0.35 smoothing and a 0.4 s throttle with no accuracy gate or jump rejection (Parity:239-317). Path points inherit these differences. | The Parity comment at Parity:285-286 explicitly says there is no 25 m gate on iOS [C] | Intentional (commented), but not documented for users | Leave, or add jump rejection on iOS (needs product decision) | Recorded paths on iOS may contain more GPS noise |
| G07 | `isCameraFollowingUser` starts `true` on Android (Entry:262) and `false` on iOS (Plugin:104). | [C] | Unclear | none needed unless a bug is observed | Low |
| G08 | `registerLocationAccuracyCallback`: Android is permission-gated and returns "Location permission is not granted." through the error callback. iOS is not in the PermI gate list and never reports denial; it requests authorization itself and keeps a silent keep-callback (Parity:48-73). | [C] | Accidental | iOS: add to gate or return the same error | `onLocationAccuracyChanged` error callback never fires on iOS when denied |
| G08b | `setHeadingFollowMode` is permission-gated on iOS only. | PermI:34 vs PermA:43-50 [C] | Intentional (Android uses the rotation-vector sensor, no location needed) | leave | none |
| G09 | `getMapboxVersion`: Android reads the Gradle `resValue` (Entry:305-319), iOS returns a hard-coded string `"11.30.0"` (Parity:11), separate from the pod pin (plugin.xml:81). | [C] | Accidental | single source of truth on iOS, or add a test that the two strings match | Silent drift on the next SDK bump |
| G10 | Offline details: Android rounds zooms with `Math.round` (Entry:4093), iOS truncates (`UInt8(value)`, SecI:54), so `maxZoom: 10.5` downloads z11 on Android and z10 on iOS, and the tile budget is checked at different zooms. Error text differs ("Invalid offline radius, zoom range, or region id." vs separate zoom and radius messages, Entry:2031 vs Plugin:1222/1340). `regionId`: Android coerces any JSON type to string (Entry:1940), iOS only accepts strings (Plugin:1229) and checks bytes, Android checks characters. iOS has an extra "Invalid styleUrl." (Plugin:1233) with no Android equivalent. | [C] | Accidental | one rounding rule and shared message strings | Different offline coverage for the same request |
| G11 | `deleteOfflineRegion` on iOS runs outside the session guard (Plugin:1511-1536); Android uses `runForSession` (Entry:2239). | [C] | Accidental | low priority | negligible |
| G12 | **Docs vs code, both platforms.** README says `onMarkerClick` delivers `type:"markerClicked"`, `latitude`, `longitude` (README:669-672). Both platforms send only `{id, type:"Find"\|"Waypoint"}` (Entry:2648-2650, Plugin:1717-1720, Plugin:2216-2219); the string `markerClicked` exists only in the README. README:681 and 741 also claim Android reports taps within 150 m of a marker, but `sendMarkerClickIfNear` has **no call sites** on either platform (definitions only: Entry:2685, Plugin:1837). | grep of whole repo [C] | Accidental | decide: fix README to match code, or change code to match README (needs your call) | Consumers coding to README get wrong event shape |
| G13 | Waypoint taps: Android debounces 400 ms and consumes the map click even when selection is disabled (Entry:2560-2564), and has a raw-touch fallback (Entry:2593). iOS has no debounce (Plugin:1666-1696) and a separate overlay tap path (Plugin:2205-2252). | [C] | Unclear | none unless duplicates are observed | possible double events on iOS (inference) |
| G14 | `getCurrentLocationAccuracy`: Android tries fused last location then GPS/network cache (Entry:3631-3677); iOS reads `CLLocationManager.location` from a manager created on demand (Parity:85-98). | [C] ; whether iOS often returns "Unknown" right after creation is [I] | Unclear | none yet | iOS may return `{-1, "Unknown"}` more often |
| G15 | Marker input handling (README documents most of it): ids coerced by Android `optString` vs strict `stringOption` on iOS; `removeMarker` numeric ids ignored on iOS (README:647, 742); `loadMarkers` non-object items clear all markers on iOS when `replace:true` (README:743); `loadMarkers` with missing `markers` returns success without clearing on Android but clears on iOS (Entry:2788 vs Plugin:804, unreachable via the JS wrapper which always sends an array). Error messages differ for limit/empty-id cases (README:566-567). | [C] | Documented (fixable) | iOS: accept numeric ids in `removeMarker`, skip non-object items | footguns for OutSystems callers |
| G16 | Boundaries and paths: Android passes color strings straight to the Mapbox builders (Entry:3182-3183, 3518-3522) while iOS parses hex and falls back to defaults (Plugin:2329). Android coerces numeric strings, iOS ignores them. First over-limit boundary message differs (Entry:3010 "Too many boundaries." vs Plugin:872 with the maximum). | [C] ; how Mapbox Android reacts to a malformed color string is [I] (not checked) | Accidental | Android: reuse `MarkerIcons.parseColor`-style validation | possible crash or blank layer on Android with bad input |
| G17 | `setLayerVisibility`: Android validates `layerId` before the map-initialized check and outside the session guard (Entry:3066-3072); iOS checks inside the session (Parity:175-216). Failure text differs ("Failed to change layer visibility: <detail>" vs generic). iOS has no input-size check. | [C] | Accidental | align text/order | low |
| G18 | **Shared behavior, not parity:** `startPathTracking({trackCamera:false})` starts no location updates on either platform, so no points are recorded (Entry:3315-3326, Plugin:966-970). README describes `trackCamera` as optional camera following only. | [C] | Accidental (both) | decide product behavior (needs your call) | recordings silently empty |
| G19 | Option/input validation order and strictness in `initialize`: iOS errors "Options are required." when no options object is passed (Plugin:147-150), Android defaults to `{}`; validation order differs (Android zoom bounds, token, style, coordinates; iOS size, zoom bounds, token, coordinates, style). For behind-WebView non-inline maps iOS honors x/y/width/height while Android uses MATCH_PARENT (Plugin:236 vs Entry:4054). Android has a single global 4 MiB check; iOS misses it in `setTouchableRects`, `setLayerVisibility`, and the parity `moveToCurrentLocation` override. | [C] | Accidental | small alignments | low |
| G20 | `setMapStyle` error handling: Android's "styleUrl is required" branch is unreachable because `styleAllowed("")` fails first (Entry:3769-3776); iOS returns "styleUrl is required" (Plugin:1914-1917) and a shorter "Style URL is not allowed." (Plugin:1920). | [C] | Accidental | align text and order | low |
| G21 | `registerCloseCallback` resolves with no payload on Android (Entry:3812) and `{closed:true}` on iOS (Plugin:1939). JS ignores the payload. | [C] | Accidental | none needed | none |
| G22 | `MapboxSecurity` differences: Java measures style URL length in UTF-16 chars, Swift in UTF-8 bytes; iOS wrapper falls back to `api.mapbox.com` when the host preference is empty (Plugin:2062) while Android does not (Entry:670, fails closed); `MapboxSecurityTest.java` has no zoom lower-bound or `>18` cases that `security-main.swift` has. | [C] | Accidental | add missing test cases | low |
| G23 | Behind-WebView gestures: Android forwards raw touches so all native Mapbox gestures work. The iOS overlay implements pan, pinch, rotation and tap only. | Plugin:2123-2144 [C] ; that double-tap zoom, two-finger tilt etc. are therefore unavailable in that mode is [I] | Unclear (likely accidental) | needs device verification before deciding | map interaction feels different on iOS |
| G24 | Marker image redirects: iOS rejects a disallowed redirect target before following it; Android checks `getURL()` after `HttpURLConnection` has followed redirects, so a request to the redirect target is already sent (the bytes are discarded). | IconsI:129-136 vs IconsA:117-119 [C] ; request-already-sent behavior is [I] (standard HttpURLConnection behavior) | Accidental | Android: disable auto-redirect and validate each hop | host allow-list is weaker on Android (SSRF-style exposure of the device's network position) |
| G25 | Doc inconsistency: README:75-81 says Android pins now render at device density, but README:740 still says Android pins appear about one third the size of iOS pins. | [C] | Accidental | fix README:740 | confusing docs |

## 5. What I did not check

- Python regression scripts in `tests/` (test-*.py), `tests/check-package.py`, and `.github` beyond the workflow file: not read in this phase.
- `www/AndroidTouchRegions.js` option `controlsOnly` semantics (shared JS, so not a platform gap).
- No build, no `npm test`, no `javac`/`swiftc` was run. Nothing was tested on a device or in an OutSystems build.
- Mapbox 11.30.0 SDK APIs: none verified. G01 (iOS style-loaded callback) and G24 (Android redirect handling) will need SDK/JDK confirmation in Phase 2.

## 6. Suggested Phase 2 grouping (for your approval)

1. **Low-risk contract fixes:** G02 (option coercion), G04, G08, G09, G17, G20, G21, G22, G25.
2. **Behavior alignment needing a decision from you:** G01, G03, G05, G10, G12, G15, G18, G19.
3. **Security hardening:** G16, G24.
4. **Leave as is (intentional or platform-forced):** G06, G07, G08b, touch caps 50/20, lifecycle hooks, pin rasterization scale (test-enforced).
5. **Needs device verification before touching:** G13, G14, G23.
