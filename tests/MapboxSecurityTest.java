package com.outsystems.mapbox;

public class MapboxSecurityTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(MapboxSecurity.publicToken("pk.fake.public"));
        check(!MapboxSecurity.publicToken("sk.fake.secret"));
        check(!MapboxSecurity.publicToken("__MAPBOX_ACCESS_TOKEN_NOT_SET__"));
        check(MapboxSecurity.styleAllowed("mapbox://styles/mapbox/streets-v12", ""));
        check(MapboxSecurity.styleAllowed("https://maps.example/style.json", "api.mapbox.com,maps.example"));
        for (String url : new String[]{"http://api.mapbox.com/a", "https://api.mapbox.com.evil/a", "file:///a", "https://user:pass@api.mapbox.com/a", "https://api.mapbox.com:8443/a", "https://api.mapbox.com/a#b"}) {
            check(!MapboxSecurity.styleAllowed(url, "api.mapbox.com"));
        }
        check(MapboxSecurity.markerImageAllowed("https://cdn.example/a.png", ""));
        check(MapboxSecurity.markerImageAllowed("https://cdn.example/a.png", " , "));
        check(MapboxSecurity.markerImageAllowed("https://CDN.example/a.png?v=1", "api.mapbox.com, cdn.example"));
        check(MapboxSecurity.markerImageAllowed("data:image/png;base64,iVBORw0KGgo=", "cdn.example"));
        for (String url : new String[]{"", "http://cdn.example/a.png", "https://evil.example/a.png", "file:///a.png",
                "https://user:pass@cdn.example/a.png", "javascript:alert(1)", "data:text/html;base64,PGh0bWw+",
                "data:image/png;base64,", "data:image/png,rawdata", "data:image/png;base64,abc<"}) {
            check(!MapboxSecurity.markerImageAllowed(url, "cdn.example"));
        }
        check(!MapboxSecurity.markerImageAllowed("data:image/png;base64," + "A".repeat(MapboxSecurity.MAX_MARKER_IMAGE_BYTES / 3 * 4 + 8), ""));
        check(!MapboxSecurity.validZoom(1e100));
        check(!MapboxSecurity.validZoom(Double.NaN));
        check(!MapboxSecurity.validZoom(Double.POSITIVE_INFINITY));
        check(MapboxSecurity.validZoom(18));
        check(MapboxSecurity.offlineBounds(0, 0, .01, .01, 18));
        check(!MapboxSecurity.offlineBounds(-30, -30, 30, 30, 18));
        check(!MapboxSecurity.offlineBounds(0, 0, .5, .5, 18));
        check(!MapboxSecurity.offlineBounds(0, 179, .01, -179, 10));
        check(!MapboxSecurity.offlineBounds(Double.NaN, 0, .01, .01, 10));
        check(!MapboxSecurity.offlineBounds(86, 0, 87, .01, 10));
        System.out.println("Android security policy tests passed");
    }
}
