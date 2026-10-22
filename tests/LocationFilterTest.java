package com.outsystems.mapbox;

import java.util.ArrayList;
import java.util.List;

/** Replays synthetic GPS traces. The Swift twin is tests/location-filter-main.swift (same scenarios). */
public class LocationFilterTest {
    private static final double LAT = 17.6807217;
    private static final double LON = 83.2492601;
    private static final double M_PER_DEG = 111320.0;

    private static long seed = 12345;

    private static double gaussian() {
        double u1 = next(), u2 = next();
        return Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);
    }

    private static double next() {
        seed = (seed * 1103515245L + 12345L) & 0x7fffffffL;
        return (seed + 1.0) / 2147483649.0;
    }

    private static double lat(double northMeters) {
        return LAT + northMeters / M_PER_DEG;
    }

    private static double lon(double eastMeters) {
        return LON + eastMeters / (M_PER_DEG * Math.cos(Math.toRadians(LAT)));
    }

    private static double error(double lat, double lon, double trueNorth, double trueEast) {
        return LocationFilter.distanceMeters(lat, lon, lat(trueNorth), lon(trueEast));
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static double mean(List<Double> values) {
        double sum = 0;
        for (double v : values) sum += v;
        return sum / values.size();
    }

    private static double max(List<Double> values) {
        double m = 0;
        for (double v : values) m = Math.max(m, v);
        return m;
    }

    public static void main(String[] args) {
        stationary();
        walking();
        startsWalking();
        rejectsBadFixes();
        recoversFromJump();
        System.out.println("Android location filter tests passed");
    }

    private static void stationary() {
        seed = 12345;
        LocationFilter filter = new LocationFilter();
        List<Double> raw = new ArrayList<>(), filtered = new ArrayList<>(), steps = new ArrayList<>();
        LocationFilter.Estimate previous = null;
        for (int i = 0; i < 90; i++) {
            double north = gaussian() * 3.0, east = gaussian() * 3.0;
            LocationFilter.Estimate e = filter.update(lat(north), lon(east), 4.0, 1000L * i, 0.0);
            check(e != null, "stationary fix accepted");
            if (i >= 20) {
                raw.add(error(lat(north), lon(east), 0, 0));
                filtered.add(error(e.latitude, e.longitude, 0, 0));
                steps.add(LocationFilter.distanceMeters(previous.latitude, previous.longitude, e.latitude, e.longitude));
            }
            previous = e;
        }
        System.out.printf("stationary: raw mean %.2f m, filtered mean %.2f m, largest step %.2f m%n",
            mean(raw), mean(filtered), max(steps));
        check(mean(filtered) < mean(raw) * 0.6, "standing still, the estimate is clearly closer than raw fixes");
        check(max(steps) < 1.0, "standing still, the dot does not jitter (steps under 1 m)");
    }

    private static void walking() {
        seed = 777;
        LocationFilter filter = new LocationFilter();
        List<Double> raw = new ArrayList<>(), filtered = new ArrayList<>();
        for (int i = 0; i < 90; i++) {
            double trueNorth = 1.4 * i;
            double north = trueNorth + gaussian() * 3.0, east = gaussian() * 3.0;
            LocationFilter.Estimate e = filter.update(lat(north), lon(east), 4.0, 1000L * i, 1.4);
            check(e != null, "walking fix accepted");
            if (i >= 20) {
                raw.add(error(lat(north), lon(east), trueNorth, 0));
                filtered.add(error(e.latitude, e.longitude, trueNorth, 0));
            }
        }
        System.out.printf("walking: raw mean %.2f m, filtered mean %.2f m, filtered worst %.2f m%n",
            mean(raw), mean(filtered), max(filtered));
        check(mean(filtered) < mean(raw), "walking, the estimate is closer than raw fixes on average");
        check(max(filtered) < 8.0, "walking, the estimate never lags far behind");
    }

    private static void startsWalking() {
        seed = 4242;
        LocationFilter filter = new LocationFilter();
        for (int i = 0; i < 40; i++) {
            filter.update(lat(gaussian() * 2.0), lon(gaussian() * 2.0), 3.0, 1000L * i, 0.0);
        }
        LocationFilter.Estimate e = null;
        for (int k = 1; k <= 6; k++) {
            double trueEast = 1.4 * k;
            e = filter.update(lat(gaussian() * 2.0), lon(trueEast + gaussian() * 2.0), 3.0, 40000L + 1000L * k, 1.4);
        }
        double err = error(e.latitude, e.longitude, 0, 1.4 * 6);
        System.out.printf("starts walking: error after 6 s of walking %.2f m%n", err);
        check(err < 5.0, "after standing still, the estimate follows within 6 s of walking");
    }

    private static void rejectsBadFixes() {
        LocationFilter filter = new LocationFilter();
        check(filter.update(lat(0), lon(0), 150.0, 0L, -1) == null, "accuracy above 100 m rejected");
        check(filter.update(Double.NaN, lon(0), 5.0, 0L, -1) == null, "NaN rejected");
        check(filter.update(lat(0), lon(0), 0.0, 0L, -1) == null, "zero accuracy rejected");
        LocationFilter.Estimate first = filter.update(lat(30), lon(0), 80.0, 0L, -1);
        check(first != null, "a poor first fix still shows something");
        LocationFilter.Estimate next = filter.update(lat(0), lon(0), 5.0, 1000L, -1);
        check(next != null && error(next.latitude, next.longitude, 0, 0) < 2.0,
            "an accurate fix quickly replaces a poor first fix");
    }

    private static void recoversFromJump() {
        LocationFilter filter = new LocationFilter();
        for (int i = 0; i < 10; i++) filter.update(lat(0), lon(0), 4.0, 1000L * i, 0.0);
        check(filter.update(lat(5000), lon(0), 4.0, 10000L, -1) == null, "impossible jump rejected (1)");
        check(filter.update(lat(5000), lon(0), 4.0, 11000L, -1) == null, "impossible jump rejected (2)");
        LocationFilter.Estimate e = filter.update(lat(5000), lon(0), 4.0, 12000L, -1);
        check(e != null && error(e.latitude, e.longitude, 5000, 0) < 1.0,
            "after 3 consistent far fixes the filter accepts the new position");
    }
}
