import Foundation

@main
struct SecurityTests {
    static func main() {
        precondition(MapboxSecurity.publicToken("pk.fake.public"))
        precondition(!MapboxSecurity.publicToken("sk.fake.secret"))
        precondition(!MapboxSecurity.publicToken("__MAPBOX_ACCESS_TOKEN_NOT_SET__"))
        precondition(MapboxSecurity.styleAllowed("mapbox://styles/mapbox/streets-v12", hosts: ""))
        precondition(MapboxSecurity.styleAllowed("https://maps.example/style.json", hosts: "api.mapbox.com,maps.example"))
        for url in ["http://api.mapbox.com/a", "https://api.mapbox.com.evil/a", "file:///a", "https://user:pass@api.mapbox.com/a", "https://api.mapbox.com:8443/a", "https://api.mapbox.com/a#b"] {
            precondition(!MapboxSecurity.styleAllowed(url, hosts: "api.mapbox.com"))
        }
        for value in [1e100, -1e100, Double.nan, Double.infinity, -Double.infinity, 1, 19] {
            precondition(MapboxSecurity.zoom(value) == nil)
        }
        precondition(MapboxSecurity.zoom(18) == 18)
        precondition(MapboxSecurity.offlineBounds(south: 0, west: 0, north: 0.01, east: 0.01, zoom: 18))
        precondition(!MapboxSecurity.offlineBounds(south: -30, west: -30, north: 30, east: 30, zoom: 18))
        precondition(!MapboxSecurity.offlineBounds(south: 0, west: 0, north: 0.5, east: 0.5, zoom: 18))
        precondition(!MapboxSecurity.offlineBounds(south: 0, west: 179, north: 0.01, east: -179, zoom: 10))
        precondition(!MapboxSecurity.offlineBounds(south: .nan, west: 0, north: 0.01, east: 0.01, zoom: 10))
        precondition(!MapboxSecurity.offlineBounds(south: 86, west: 0, north: 87, east: 0.01, zoom: 10))
        print("iOS security policy tests passed")
    }
}
