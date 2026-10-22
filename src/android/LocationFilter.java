package com.outsystems.mapbox;

/**
 * Accuracy-weighted position filter. No Android dependencies; the Swift twin is
 * src/ios/LocationFilter.swift and both must keep identical constants and logic.
 *
 * Each fix is weighted by its reported accuracy (one standard deviation, metres).
 * Standing still, the estimate converges on an accuracy-weighted average and barely
 * moves, so the dot stays calm. When the person starts walking, the speed and the
 * distance from the estimate raise the process noise, so the estimate follows quickly.
 */
final class LocationFilter {
    static final double MAX_ACCURACY_METERS = 100.0;
    static final double MIN_ACCURACY_METERS = 2.0;
    static final double MAX_SPEED_MPS = 15.0;
    static final double MIN_PROCESS_NOISE_MPS = 0.2;
    static final double PROCESS_NOISE_PER_SPEED = 3.0;
    static final double STATIONARY_SPEED_MPS = 0.35;
    static final double MAX_FIX_GAP_SECONDS = 30.0;
    static final double INNOVATION_SIGMAS = 3.0;
    static final int INNOVATION_CONFIRM_FIXES = 2;
    static final int REJECTED_RESET_FIXES = 3;

    static final class Estimate {
        final double latitude;
        final double longitude;
        final double accuracyMeters;

        Estimate(double latitude, double longitude, double accuracyMeters) {
            this.latitude = latitude;
            this.longitude = longitude;
            this.accuracyMeters = accuracyMeters;
        }
    }

    private boolean hasEstimate;
    private double latitude;
    private double longitude;
    private double variance;
    private long estimateTimeMs;
    private double lastRawLatitude;
    private double lastRawLongitude;
    private long lastRawTimeMs;
    private double lastRawAccuracy;
    private int innovationCount;
    private int rejectedCount;

    void reset() {
        hasEstimate = false;
        innovationCount = 0;
        rejectedCount = 0;
    }

    /**
     * @param speedMps reported speed in m/s, or a negative value when unknown
     * @return the new estimate, or null when the fix was rejected
     */
    Estimate update(double lat, double lon, double accuracyMeters, long timeMs, double speedMps) {
        if (!Double.isFinite(lat) || !Double.isFinite(lon) || lat < -90 || lat > 90
                || lon < -180 || lon > 180 || !Double.isFinite(accuracyMeters)
                || accuracyMeters <= 0 || accuracyMeters > MAX_ACCURACY_METERS) {
            return null;
        }
        double accuracy = Math.max(accuracyMeters, MIN_ACCURACY_METERS);
        double measurementVariance = accuracy * accuracy;

        if (!hasEstimate) {
            start(lat, lon, accuracy, timeMs);
            return current();
        }

        double dt = (timeMs - estimateTimeMs) / 1000.0;
        if (dt < 0) {
            return null;
        }
        if (dt > MAX_FIX_GAP_SECONDS) {
            start(lat, lon, accuracy, timeMs);
            return current();
        }

        // Both fixes are uncertain, so their accuracies are subtracted before judging speed.
        double rawDistance = distanceMeters(lastRawLatitude, lastRawLongitude, lat, lon);
        double rawDt = (timeMs - lastRawTimeMs) / 1000.0;
        double movedMeters = Math.max(0.0, rawDistance - lastRawAccuracy - accuracy);
        double impliedSpeed = rawDt > 0 ? movedMeters / rawDt : 0.0;
        double speed = speedMps >= 0 ? Math.max(speedMps, 0.0) : impliedSpeed;
        if (Math.max(speed, impliedSpeed) > MAX_SPEED_MPS) {
            rejectedCount++;
            if (rejectedCount >= REJECTED_RESET_FIXES) {
                start(lat, lon, accuracy, timeMs);
                return current();
            }
            return null;
        }
        rejectedCount = 0;
        lastRawLatitude = lat;
        lastRawLongitude = lon;
        lastRawTimeMs = timeMs;
        lastRawAccuracy = accuracy;

        double processNoise = speed < STATIONARY_SPEED_MPS
            ? MIN_PROCESS_NOISE_MPS
            : Math.max(MIN_PROCESS_NOISE_MPS, speed * PROCESS_NOISE_PER_SPEED);
        variance += processNoise * processNoise * dt;

        double innovation = distanceMeters(latitude, longitude, lat, lon);
        if (innovation > INNOVATION_SIGMAS * Math.sqrt(variance + measurementVariance)) {
            innovationCount++;
            if (innovationCount >= INNOVATION_CONFIRM_FIXES) {
                start(lat, lon, accuracy, timeMs);
                return current();
            }
        } else {
            innovationCount = 0;
        }

        double gain = variance / (variance + measurementVariance);
        latitude += gain * (lat - latitude);
        longitude += gain * (lon - longitude);
        variance = (1.0 - gain) * variance;
        estimateTimeMs = timeMs;
        return current();
    }

    private void start(double lat, double lon, double accuracy, long timeMs) {
        hasEstimate = true;
        latitude = lat;
        longitude = lon;
        variance = accuracy * accuracy;
        estimateTimeMs = timeMs;
        lastRawLatitude = lat;
        lastRawLongitude = lon;
        lastRawTimeMs = timeMs;
        lastRawAccuracy = accuracy;
        innovationCount = 0;
        rejectedCount = 0;
    }

    private Estimate current() {
        return new Estimate(latitude, longitude, Math.sqrt(variance));
    }

    static double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
        double meanLatRad = Math.toRadians((lat1 + lat2) / 2.0);
        double dy = (lat2 - lat1) * 111320.0;
        double dx = (lon2 - lon1) * 111320.0 * Math.cos(meanLatRad);
        return Math.sqrt(dx * dx + dy * dy);
    }
}
