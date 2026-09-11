import Foundation

enum MapboxSecurity {
    static let maxPoints = 20000
    static let maxInputBytes = 4 * 1024 * 1024

    static func publicToken(_ token: String) -> Bool {
        token.range(of: "^pk\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    static func styleAllowed(_ value: String, hosts: String) -> Bool {
        guard value.utf8.count <= 4096 else { return false }
        if value.range(of: "^mapbox://styles/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$", options: .regularExpression) != nil { return true }
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443 else { return false }
        return hosts.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == host.lowercased()
        }
    }

    static func zoom(_ value: Double) -> UInt8? {
        guard value.isFinite, value >= 2, value <= 18 else { return nil }
        return UInt8(value)
    }

    static func offlineBounds(south: Double, west: Double, north: Double, east: Double, zoom: Double) -> Bool {
        guard self.zoom(zoom) != nil, [south, west, north, east].allSatisfy({ $0.isFinite }),
              south >= -85, north <= 85, west >= -180, east <= 180,
              south <= north, west <= east, east - west <= 180 else { return false }
        let rad = Double.pi / 180
        let a = pow(sin((north - south) * rad / 2), 2)
            + cos(south * rad) * cos(north * rad) * pow(sin((east - west) * rad / 2), 2)
        guard 6371000 * 2 * asin(sqrt(min(1, a))) <= 100000 else { return false }
        func mercator(_ lat: Double) -> Double {
            (1 - log(tan(lat * rad) + 1 / cos(lat * rad)) / Double.pi) / 2
        }
        let scale = pow(2, ceil(zoom))
        let columns = ceil((east - west) / 360 * scale) + 2
        let rows = ceil(abs(mercator(north) - mercator(south)) * scale) + 2
        return columns * rows * 4 / 3 <= 50000
    }
}
