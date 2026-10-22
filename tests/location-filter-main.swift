import Foundation

// Replays the same synthetic scenarios as tests/LocationFilterTest.java.
@main
struct LocationFilterTests {
    static let baseLat = 17.6807217
    static let baseLon = 83.2492601
    static let metersPerDegree = 111320.0
    static var seed: UInt64 = 12345

    static func next() -> Double {
        seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff
        return (Double(seed) + 1.0) / 2147483649.0
    }

    static func gaussian() -> Double {
        let u1 = next()
        let u2 = next()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }

    static func lat(_ north: Double) -> Double { baseLat + north / metersPerDegree }
    static func lon(_ east: Double) -> Double {
        baseLon + east / (metersPerDegree * cos(baseLat * Double.pi / 180.0))
    }
    static func error(_ la: Double, _ lo: Double, _ trueNorth: Double, _ trueEast: Double) -> Double {
        LocationFilter.distanceMeters(la, lo, lat(trueNorth), lon(trueEast))
    }
    static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

    static func main() {
        stationary()
        walking()
        startsWalking()
        rejectsBadFixes()
        recoversFromJump()
        print("iOS location filter tests passed")
    }

    static func stationary() {
        seed = 12345
        let filter = LocationFilter()
        var raw: [Double] = [], filtered: [Double] = [], steps: [Double] = []
        var previous: LocationFilter.Estimate?
        for i in 0..<90 {
            let north = gaussian() * 3.0
            let east = gaussian() * 3.0
            guard let e = filter.update(latitude: lat(north), longitude: lon(east), accuracy: 4.0,
                                        timeMs: Int64(1000 * i), speed: 0.0) else {
                preconditionFailure("stationary fix accepted")
            }
            if i >= 20, let p = previous {
                raw.append(error(lat(north), lon(east), 0, 0))
                filtered.append(error(e.latitude, e.longitude, 0, 0))
                steps.append(LocationFilter.distanceMeters(p.latitude, p.longitude, e.latitude, e.longitude))
            }
            previous = e
        }
        precondition(mean(filtered) < mean(raw) * 0.6, "standing still, the estimate is clearly closer than raw fixes")
        precondition((steps.max() ?? 0) < 1.0, "standing still, the position does not jitter (steps under 1 m)")
    }

    static func walking() {
        seed = 777
        let filter = LocationFilter()
        var raw: [Double] = [], filtered: [Double] = []
        for i in 0..<90 {
            let trueNorth = 1.4 * Double(i)
            let north = trueNorth + gaussian() * 3.0
            let east = gaussian() * 3.0
            guard let e = filter.update(latitude: lat(north), longitude: lon(east), accuracy: 4.0,
                                        timeMs: Int64(1000 * i), speed: 1.4) else {
                preconditionFailure("walking fix accepted")
            }
            if i >= 20 {
                raw.append(error(lat(north), lon(east), trueNorth, 0))
                filtered.append(error(e.latitude, e.longitude, trueNorth, 0))
            }
        }
        precondition(mean(filtered) < mean(raw), "walking, the estimate is closer than raw fixes on average")
        precondition((filtered.max() ?? 0) < 8.0, "walking, the estimate never lags far behind")
    }

    static func startsWalking() {
        seed = 4242
        let filter = LocationFilter()
        for i in 0..<40 {
            _ = filter.update(latitude: lat(gaussian() * 2.0), longitude: lon(gaussian() * 2.0),
                              accuracy: 3.0, timeMs: Int64(1000 * i), speed: 0.0)
        }
        var estimate: LocationFilter.Estimate?
        for k in 1...6 {
            let trueEast = 1.4 * Double(k)
            estimate = filter.update(latitude: lat(gaussian() * 2.0), longitude: lon(trueEast + gaussian() * 2.0),
                                     accuracy: 3.0, timeMs: 40000 + Int64(1000 * k), speed: 1.4)
        }
        guard let e = estimate else { preconditionFailure("walking start accepted") }
        precondition(error(e.latitude, e.longitude, 0, 1.4 * 6) < 5.0,
                     "after standing still, the estimate follows within 6 s of walking")
    }

    static func rejectsBadFixes() {
        let filter = LocationFilter()
        precondition(filter.update(latitude: lat(0), longitude: lon(0), accuracy: 150.0, timeMs: 0, speed: -1) == nil,
                     "accuracy above 100 m rejected")
        precondition(filter.update(latitude: Double.nan, longitude: lon(0), accuracy: 5.0, timeMs: 0, speed: -1) == nil,
                     "NaN rejected")
        precondition(filter.update(latitude: lat(0), longitude: lon(0), accuracy: 0.0, timeMs: 0, speed: -1) == nil,
                     "zero accuracy rejected")
        precondition(filter.update(latitude: lat(30), longitude: lon(0), accuracy: 80.0, timeMs: 0, speed: -1) != nil,
                     "a poor first fix still shows something")
        guard let next = filter.update(latitude: lat(0), longitude: lon(0), accuracy: 5.0, timeMs: 1000, speed: -1) else {
            preconditionFailure("accurate fix accepted")
        }
        precondition(error(next.latitude, next.longitude, 0, 0) < 2.0,
                     "an accurate fix quickly replaces a poor first fix")
    }

    static func recoversFromJump() {
        let filter = LocationFilter()
        for i in 0..<10 {
            _ = filter.update(latitude: lat(0), longitude: lon(0), accuracy: 4.0, timeMs: Int64(1000 * i), speed: 0.0)
        }
        precondition(filter.update(latitude: lat(5000), longitude: lon(0), accuracy: 4.0, timeMs: 10000, speed: -1) == nil,
                     "impossible jump rejected (1)")
        precondition(filter.update(latitude: lat(5000), longitude: lon(0), accuracy: 4.0, timeMs: 11000, speed: -1) == nil,
                     "impossible jump rejected (2)")
        guard let e = filter.update(latitude: lat(5000), longitude: lon(0), accuracy: 4.0, timeMs: 12000, speed: -1) else {
            preconditionFailure("far position accepted after 3 consistent fixes")
        }
        precondition(error(e.latitude, e.longitude, 5000, 0) < 1.0,
                     "after 3 consistent far fixes the filter accepts the new position")
    }
}
