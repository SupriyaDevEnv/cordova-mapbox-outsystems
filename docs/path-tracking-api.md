# Path Tracking API

Record a user's GPS movement as a live polyline on the map, pause and resume it, save the result, and replay it later. In the OutSystems app this powers **hunt tracking**: *start hunt*, *pause hunt*, *continue hunt*, *stop and save hunt*, *view past hunt*.

All functions live on `window.MapboxPlugin`, return a **Promise**, and behave identically on Android and iOS.

| Function | Purpose |
|---|---|
| [`startPathTracking(options)`](#startpathtrackingoptions) | Begin recording and drawing the trail |
| [`pausePathTracking()`](#pausepathtracking) | Stop collecting points; the session stays open |
| [`continuePathTracking()`](#continuepathtracking) | Resume after a pause in a new segment |
| [`stopPathTracking()`](#stoppathtracking) | End the session and return everything recorded |
| [`loadPath(options)`](#loadpathoptions) | Draw a previously saved path |
| [`clearPaths()`](#clearpaths) | Remove the drawn path from the map |
| [`setPathVisibility({ visible })`](#setpathvisibility-visible-) | Hide or show the path without deleting it |

---

## Lifecycle

```
            start
              │
              ▼
   ┌────► RECORDING ──pause──► PAUSED
   │          │                   │
   │          │                   │ continue
   │          │                   ▼
   │          │              (new segment)
   │          │                   │
   │          └───────────────────┘
   │          │
   │         stop (from RECORDING or PAUSED)
   │          ▼
   │        IDLE ──► result { points, distance, duration, segments }
   └────────────────── start again
```

Calls made in the wrong state **reject** with an error message (see [Errors](#errors)).

---

## Line styling

`startPathTracking` and `loadPath` accept the same three style options.

| Option | Type | Default | Rules |
|---|---|---|---|
| `lineColor` | string | `"#FF0000"` | `#RRGGBB` or `#RRGGBBAA` (the `#` is optional). Anything else falls back to red. |
| `lineWidth` | number | `3` | Pixels. Must be greater than 0; values above **30** are capped. Numeric strings such as `"5"` are accepted. |
| `lineOpacity` | number | `1` | `0` (invisible) to `1` (solid). Out-of-range values are clamped. |

```javascript
{ lineColor: "#1E88E5", lineWidth: 6, lineOpacity: 0.85 }   // blue, thick, slightly transparent
{ lineColor: "#FF000080" }                                  // red at 50% alpha baked into the colour
```

Notes:

- The style is fixed when tracking **starts**. Every segment of that session, before and after a pause, uses it.
- The colour accepts hex only. Names such as `"red"` and short hex such as `#F00` are not recognised and fall back to red.
- `#RRGGBBAA` puts alpha **last**, as in CSS. It multiplies with `lineOpacity`.

---

## `startPathTracking(options)`

Begins recording GPS fixes and drawing the trail. Any earlier path data (recorded or loaded) is discarded.

| Option | Type | Default | Description |
|---|---|---|---|
| `lineColor`, `lineWidth`, `lineOpacity` | | | See [Line styling](#line-styling). |
| `trackCamera` | `"true"` / `"false"` (or boolean) | `"true"` | Also turn on user tracking so the camera follows the user. **GPS only runs while this is on**, so `"false"` draws and records nothing on its own. Keep the default. |

```javascript
window.MapboxPlugin.startPathTracking({
  lineColor: "#E53935",
  lineWidth: 5,
  lineOpacity: 0.9
})
  .then(function (r) { /* r.status === "started" on trackCamera:"false" */ })
  .catch(function (e) { /* "Path tracking is already active..." */ });
```

Requires the map to be initialised and location permission to be granted (the plugin requests it for you).

Points are collected from GPS updates of roughly one per second, at least 1 m apart. On iOS the coordinate is smoothed so the trail is not jittery.

**Limit:** recording stops automatically at **20 000 points**. The data already recorded stays available to `stopPathTracking()`.

---

## `pausePathTracking()`

Stops collecting points and drawing. The session stays active and the elapsed clock keeps running.

```javascript
window.MapboxPlugin.pausePathTracking().then(function (r) {
  // r.status       = "paused"
  // r.segmentCount = number of segments completed so far
});
```

---

## `continuePathTracking()`

Resumes collection in a **new segment**. The map shows a gap between the last point before the pause and the first point after the resume.

```javascript
window.MapboxPlugin.continuePathTracking().then(function (r) {
  // r.status       = "continued"
  // r.segmentCount = total segments including the new one
});
```

---

## `stopPathTracking()`

Ends the session and returns everything recorded. The line stays on the map until you call `clearPaths()`.

```javascript
window.MapboxPlugin.stopPathTracking().then(function (r) {
  // r.points       = [{ lat: 17.680, lon: 83.249 }, ...]
  // r.distance     = 1234.5   metres, rounded to 2 decimals
  // r.duration     = 45000    milliseconds from start to stop
  // r.segments     = [{ startIndex: 0, endIndex: 50 }, { startIndex: 51, endIndex: 100 }]
  // r.segmentCount = 2
});
```

### Reading `segments`

`points` is one flat list. `segments` says which slice belongs to which stretch of the walk. Both indexes are inclusive.

```
points:   [ p0 p1 p2 p3 p4 | p5 p6 p7 | p8 p9 ]
segments:   0 → 4 (A)        5 → 7 (B)   8 → 9 (C)
```

### What the numbers mean

- `duration` is wall-clock time from `start` to `stop` and **includes paused time**.
- `distance` adds up the straight-line distance between consecutive entries in `points`, so it **also counts the jump across each pause gap**. Compute per-segment distances yourself from `segments` if you need to exclude them.
- A segment with no points is dropped, so `segmentCount` only counts segments that recorded something.

---

## `loadPath(options)`

Draws a saved path, for example to show a past hunt.

| Option | Type | Description |
|---|---|---|
| `points` | array | 2 to 20 000 items shaped `{ lat, lon }`. `latitude`, `lng`, `longitude` are accepted as aliases. Invalid coordinates are skipped. |
| `lineColor`, `lineWidth`, `lineOpacity` | | See [Line styling](#line-styling). |

```javascript
window.MapboxPlugin.loadPath({
  points: savedPoints,
  lineColor: "#43A047",
  lineWidth: 4
}).then(function (r) { /* r.status === "loaded", r.pointCount */ });
```

- Fails while tracking is active. Stop first.
- Replaces any path already drawn.
- Draws **one continuous line**. Segment gaps from the original hunt are not reproduced, so a paused hunt shows a straight bridge across each pause.
- `loadPath` also accepts a JSON string of the same shape (max 4 MiB).

---

## `clearPaths()`

Removes every drawn path and the recorded points.

```javascript
window.MapboxPlugin.clearPaths();
```

## `setPathVisibility({ visible })`

Hides or shows the path without deleting it. Safe to call repeatedly.

```javascript
window.MapboxPlugin.setPathVisibility({ visible: false });
```

---

## Errors

Rejected promises carry a plain message.

| Message | Cause |
|---|---|
| `Map is not initialized.` | Call `initialize` first. |
| `Path tracking is already active. Call stopPathTracking first.` | `start` while a session is open. |
| `Path tracking is not active.` | `pause`, `continue` or `stop` with no session. |
| `Path tracking is already paused.` | `pause` twice. |
| `Path tracking is not paused. Call pausePathTracking first.` | `continue` while recording. |
| `Cannot load a path while path tracking is active. Stop tracking first.` | `loadPath` mid-session. |
| `A path requires between 2 and 20000 points.` | `loadPath` with too few or too many points. |
| `A path requires at least 2 valid points.` | Fewer than 2 points survived validation. |
| `Location provider is not enabled.` | GPS and network location are both off (Android). |

---

## Complete example: a hunt

```javascript
// 1. Start hunt
await MapboxPlugin.startPathTracking({ lineColor: "#E53935", lineWidth: 5 });

// 2. Coffee break
await MapboxPlugin.pausePathTracking();
await MapboxPlugin.continuePathTracking();

// 3. Finish and save
const hunt = await MapboxPlugin.stopPathTracking();
//   → send hunt.points, hunt.distance, hunt.duration, hunt.segments to your server

// 4. Later: replay it
await MapboxPlugin.clearPaths();
await MapboxPlugin.loadPath({ points: hunt.points, lineColor: "#1E88E5", lineWidth: 4 });
```

## Saving a hunt (OutSystems)

Store `points` as a JSON text (or one row per point with an index), plus `distance`, `duration` and `segments`. Persisting `segments` lets you split the line yourself later, even though `loadPath` draws it as one line.
