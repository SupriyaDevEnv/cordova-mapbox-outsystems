import Foundation

/// Accuracy-weighted position filter. Foundation only; the Java twin is
/// src/android/LocationFilter.java and both must keep identical constants and logic.
///
/// Each fix is weighted by its reported accuracy (one standard deviation, metres).
/// Standing still, the estimate converges on an accuracy-weighted average and barely
/// moves, so the position stays calm. When the person starts walking, the speed and the
/// distance from the estimate raise the process noise, so the estimate follows quickly.
final class LocationFilter {
    static let maxAccuracyMeters = 100.0
    static let minAccuracyMeters = 2.0
    static let maxSpeedMps = 15.0
    static let minProcessNoiseMps = 0.2
    static let processNoisePerSpeed = 3.0
    static let stationarySpeedMps = 0.35
    static let maxFixGapSeconds = 30.0
    static let innovationSigmas = 3.0
    static let innovationConfirmFixes = 2
    static let rejectedResetFixes = 3

    struct Estimate {
        let latitude: Double
        let longitude: Double
        let accuracyMeters: Double
    }

    private var hasEstimate = false
    private var latitude = 0.0
    private var longitude = 0.0
    private var variance = 0.0
    private var estimateTimeMs: Int64 = 0
    private var lastRawLatitude = 0.0
    private var lastRawLongitude = 0.0
    private var lastRawTimeMs: Int64 = 0
    private var lastRawAccuracy = 0.0
    private var innovationCount = 0
    private var rejectedCount = 0

    func reset() {
        hasEstimate = false
        innovationCount = 0
        rejectedCount = 0
    }

    /// - Parameter speed: reported speed in m/s, or a negative value when unknown.
    /// - Returns: the new estimate, or nil when the fix was rejected.
    func update(latitude lat: Double, longitude lon: Double, accuracy accuracyMeters: Double,
                timeMs: Int64, speed speedMps: Double) -> Estimate? {
        guard lat.isFinite, lon.isFinite, lat >= -90, lat <= 90, lon >= -180, lon <= 180,
              accuracyMeters.isFinite, accuracyMeters > 0,
              accuracyMeters <= Self.maxAccuracyMeters else {
            return nil
        }
        let accuracy = max(accuracyMeters, Self.minAccuracyMeters)
        let measurementVariance = accuracy * accuracy

        if !hasEstimate {
            start(lat, lon, accuracy, timeMs)
            return current()
        }

        let dt = Double(timeMs - estimateTimeMs) / 1000.0
        if dt < 0 {
            return nil
        }
        if dt > Self.maxFixGapSeconds {
            start(lat, lon, accuracy, timeMs)
            return current()
        }

        // Both fixes are uncertain, so their accuracies are subtracted before judging speed.
        let rawDistance = Self.distanceMeters(lastRawLatitude, lastRawLongitude, lat, lon)
        let rawDt = Double(timeMs - lastRawTimeMs) / 1000.0
        let movedMeters = max(0.0, rawDistance - lastRawAccuracy - accuracy)
        let impliedSpeed = rawDt > 0 ? movedMeters / rawDt : 0.0
        let speed = speedMps >= 0 ? max(speedMps, 0.0) : impliedSpeed
        if max(speed, impliedSpeed) > Self.maxSpeedMps {
            rejectedCount += 1
            if rejectedCount >= Self.rejectedResetFixes {
                start(lat, lon, accuracy, timeMs)
                return current()
            }
            return nil
        }
        rejectedCount = 0
        lastRawLatitude = lat
        lastRawLongitude = lon
        lastRawTimeMs = timeMs
        lastRawAccuracy = accuracy

        let processNoise = speed < Self.stationarySpeedMps
            ? Self.minProcessNoiseMps
            : max(Self.minProcessNoiseMps, speed * Self.processNoisePerSpeed)
        variance += processNoise * processNoise * dt

        let innovation = Self.distanceMeters(latitude, longitude, lat, lon)
        if innovation > Self.innovationSigmas * (variance + measurementVariance).squareRoot() {
            innovationCount += 1
            if innovationCount >= Self.innovationConfirmFixes {
                start(lat, lon, accuracy, timeMs)
                return current()
            }
        } else {
            innovationCount = 0
        }

        let gain = variance / (variance + measurementVariance)
        latitude += gain * (lat - latitude)
        longitude += gain * (lon - longitude)
        variance = (1.0 - gain) * variance
        estimateTimeMs = timeMs
        return current()
    }

    private func start(_ lat: Double, _ lon: Double, _ accuracy: Double, _ timeMs: Int64) {
        hasEstimate = true
        latitude = lat
        longitude = lon
        variance = accuracy * accuracy
        estimateTimeMs = timeMs
        lastRawLatitude = lat
        lastRawLongitude = lon
        lastRawTimeMs = timeMs
        lastRawAccuracy = accuracy
        innovationCount = 0
        rejectedCount = 0
    }

    private func current() -> Estimate {
        Estimate(latitude: latitude, longitude: longitude, accuracyMeters: variance.squareRoot())
    }

    static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let meanLatRad = ((lat1 + lat2) / 2.0) * Double.pi / 180.0
        let dy = (lat2 - lat1) * 111320.0
        let dx = (lon2 - lon1) * 111320.0 * cos(meanLatRad)
        return (dx * dx + dy * dy).squareRoot()
    }
}
