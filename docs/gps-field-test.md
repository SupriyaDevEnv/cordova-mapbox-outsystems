# GPS accuracy field test

Purpose: measure how far the blue dot and the raw GPS fix are from the true position, before and after each change. Nothing here is a requirement of the plugin itself.

## Equipment
- The phones under test (at least two models; note which one supports dual-frequency GPS if known).
- A way to get true positions: at least 10 surveyed points (road centre, road edge, a corner, an open field point). Use points whose coordinates are known to better than 0.5 m (survey marks, or agreed reference points). Do not use coordinates read from the same map style.
- A computer with `adb` (Android) or Xcode console (iOS).

## One-time setup
1. In the test app's `initialize` call add `locationDiagnostics: true`. Never ship this: it writes coordinates to the log.
2. Start tracking: `enableUserLocation()` and `setUserTrackingEnabled({enabled: true})`.
3. Android: `adb logcat -c`, then `adb logcat -s MapboxPlugin > logcat.txt`. iOS: copy the lines containing `MapboxPlugin: gps` from the Xcode console.

## Procedure
1. At each surveyed point stand still for 2 minutes with the phone held normally. Write down the point label and the start and end time (epoch ms, or note the clock time and convert).
2. Walk one line of about 100 m along the road centre at normal pace, noting start and end time.
3. Repeat in at least two conditions: open sky, and next to buildings (like the problem area).
4. Repeat with each build being compared (baseline, then after each phase).

## Analysis
Create `truth.csv`:

    label,start_ms,end_ms,lat,lon
    corner-A,1761100000000,1761100120000,17.6807217,83.2492601

Run:

    python docs/analyze-gps-log.py logcat.txt truth.csv

The script prints, per point and overall, the median and 95th percentile error of (a) the raw GPS fix and (b) the blue dot (Android) or camera/path coordinate (iOS), plus how many fixes were dropped or held (`dropped-accuracy`, `dropped-jump`, `held-stationary`).

## Comparing builds and the decision gate
Run the same points and phones for each configuration:
1. Baseline: `locationFilter: "legacy"` (default).
2. Candidate: `locationFilter: "accuracyWeighted"`, optionally with `showAccuracyRing: true`.

Switch the default to `accuracyWeighted` only if all of these hold on at least two phone models, in open sky and next to buildings:
- Median error is at least about 15% lower than legacy, standing and walking.
- The 95th-percentile error is not worse than legacy.
- The dot does not visibly jitter while standing and does not lag more than a step or two while walking.
- Recorded paths look at least as good as legacy (no zig-zag, no gaps).
- No new complaints about the dot freezing in poor-signal areas.

If these are not met, keep `legacy` and record the numbers here. Whatever the result, phone GPS alone will not reach sub-metre accuracy; the 0.5-1 m goal needs different hardware.

## How to read it
- Raw error already 3 m or more: the phone hardware is the limit; software can only help partly.
- Dot error clearly worse than raw error: our filtering adds error. That is the part we can fix.
- Many `dropped-accuracy` lines: fixes worse than 25 m are being discarded, which can leave the dot stale.
- Record median and 95th percentile for every build. Compare builds on the same points and phones.
