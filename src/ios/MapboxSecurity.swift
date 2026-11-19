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

    /// Marker images are shown as small thumbnails; serve them at about 256 px.
    static let maxMarkerImageBytes = 256 * 1024

    /// HTTPS URLs (optionally limited to a host list) or base64 image data URIs.
    static func markerImageAllowed(_ value: String, hosts: String) -> Bool {
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ","),
                  value.utf8.distance(from: value.startIndex, to: comma) <= 64 else { return false }
            let header = String(value[...comma])
            let payload = value.utf8[value.utf8.index(after: comma)...]
            guard header.range(of: "^data:image/(png|jpeg|jpg|webp|gif);base64,$", options: .regularExpression) != nil,
                  !payload.isEmpty, payload.count <= maxMarkerImageBytes / 3 * 4 + 4 else { return false }
            return payload.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="):
                    return true
                default:
                    return false
                }
            }
        }
        guard value.utf8.count <= 4096, let url = URLComponents(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        let allowed = hosts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return allowed.isEmpty || allowed.contains(host.lowercased())
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
        let scale = pow(2, ceil(zoom))
        let columns = ceil((east - west) / 360 * scale) + 2
        let rows = ceil(abs(mercator(north) - mercator(south)) * scale) + 2
        return columns * rows * 4 / 3 <= 50000
    }

    /// Web Mercator y in [0, 1] (0 at the north edge) for a latitude in degrees.
    private static func mercator(_ lat: Double) -> Double {
        let rad = Double.pi / 180
        return (1 - log(tan(lat * rad) + 1 / cos(lat * rad)) / Double.pi) / 2
    }

    // Tiles covering the box at every zoom from minZoom to maxZoom, for one tileset.
    // Returns -1 for invalid input. Used for download-size estimates, not limits.
    static func estimatedTileCount(south: Double, west: Double, north: Double, east: Double,
                                   minZoom: Int, maxZoom: Int) -> Int64 {
        guard [south, west, north, east].allSatisfy({ $0.isFinite }), south <= north, west <= east,
              minZoom >= 0, maxZoom <= 22, minZoom <= maxZoom else { return -1 }
        func tileIndex(_ value: Double, _ n: Double) -> Int64 {
            Int64(max(0, min(n - 1, floor(value))))
        }
        let top = mercator(min(north, 85.0511))
        let bottom = mercator(max(south, -85.0511))
        var total: Int64 = 0
        for z in minZoom...maxZoom {
            let n = pow(2, Double(z))
            let x0 = tileIndex((west + 180) / 360 * n, n)
            let x1 = tileIndex((east + 180) / 360 * n, n)
            let y0 = tileIndex(top * n, n)
            let y1 = tileIndex(bottom * n, n)
            total += (x1 - x0 + 1) * (y1 - y0 + 1)
        }
        return total
    }
}
