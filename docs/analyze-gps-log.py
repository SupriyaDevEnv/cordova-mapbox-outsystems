#!/usr/bin/env python3
"""Summarize plugin GPS diagnostics against surveyed ground-truth points.

Usage:
    python docs/analyze-gps-log.py logcat.txt truth.csv

truth.csv (header required), one row per standing test point or time window:
    label,start_ms,end_ms,lat,lon
Times are Unix epoch milliseconds, matching the t= value in the log.

Log lines come from the initialize option locationDiagnostics=true:
    gps <tag> raw=<lat>,<lon> acc=<m> speed=<m/s> t=<epoch ms> dot=<lat>,<lon>|none   (Android)
    gps <tag> raw=<lat>,<lon> acc=<m> speed=<m/s> t=<epoch ms> cam=<lat>,<lon>|none   (iOS)
On Android `dot` is the blue dot. On iOS the dot is drawn by Mapbox from the raw fix, so
`cam` (camera/path coordinate) is reported instead.
"""
import csv
import math
import re
import statistics
import sys
from collections import Counter

LINE = re.compile(
    r"gps (?P<tag>\S+) raw=(?P<lat>-?\d+\.\d+),(?P<lon>-?\d+\.\d+) acc=(?P<acc>-?[\d.]+) "
    r"speed=(?P<speed>-?[\d.]+) t=(?P<t>\d+) (?:dot|cam)=(?P<pos>none|-?\d+\.\d+,-?\d+\.\d+)"
)


def meters(lat1, lon1, lat2, lon2):
    radius = 6371000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((phi2 - phi1) / 2) ** 2
         + math.cos(phi1) * math.cos(phi2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * radius * math.asin(math.sqrt(min(1.0, a)))


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    index = min(len(ordered) - 1, int(math.ceil(fraction * len(ordered))) - 1)
    return ordered[max(0, index)]


def describe(values):
    if not values:
        return "n=0"
    return "n=%d median=%.2f m p95=%.2f m max=%.2f m" % (
        len(values), statistics.median(values), percentile(values, 0.95), max(values))


def main(log_path, truth_path):
    fixes = []
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = LINE.search(line)
            if match:
                fixes.append(match.groupdict())
    with open(truth_path, newline="", encoding="utf-8") as handle:
        truths = list(csv.DictReader(handle))

    print("Fixes in log: %d. By tag: %s" % (len(fixes), dict(Counter(f["tag"] for f in fixes))))
    all_raw, all_pos = [], []
    for truth in truths:
        start, end = int(truth["start_ms"]), int(truth["end_ms"])
        lat, lon = float(truth["lat"]), float(truth["lon"])
        raw, pos = [], []
        for fix in fixes:
            if not start <= int(fix["t"]) <= end:
                continue
            raw.append(meters(lat, lon, float(fix["lat"]), float(fix["lon"])))
            if fix["pos"] != "none":
                plat, plon = (float(part) for part in fix["pos"].split(","))
                pos.append(meters(lat, lon, plat, plon))
        all_raw += raw
        all_pos += pos
        print("%s\n  raw fix error:      %s\n  dot/camera error:   %s" % (
            truth["label"], describe(raw), describe(pos)))
    print("ALL POINTS\n  raw fix error:      %s\n  dot/camera error:   %s" % (
        describe(all_raw), describe(all_pos)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
