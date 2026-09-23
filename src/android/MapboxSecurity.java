package com.outsystems.mapbox;

import java.net.URI;

/** Input policy shared by every native entry point. No Android dependencies. */
final class MapboxSecurity {
    static final int MAX_POINTS = 20000;
    static final int MAX_INPUT_CHARS = 4 * 1024 * 1024;
    static final double MAX_TILES = 50000;

    static boolean publicToken(String token) {
        return token != null && token.matches("pk\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+");
    }

    static boolean styleAllowed(String value, String hosts) {
        if (value == null || value.length() > 4096) return false;
        if (value.matches("mapbox://styles/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+")) return true;
        try {
            URI uri = new URI(value);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                    || uri.getRawUserInfo() != null || uri.getRawFragment() != null
                    || (uri.getPort() != -1 && uri.getPort() != 443)) return false;
            for (String host : hosts.split(",")) {
                if (uri.getHost().equalsIgnoreCase(host.trim())) return true;
            }
        } catch (Exception ignored) { }
        return false;
    }

    static boolean validZoom(double zoom) {
        return Double.isFinite(zoom) && zoom >= 2 && zoom <= 18;
    }

    // Conservative bounding-box budget, including lower zoom levels. Reject
    // antimeridian-crossing boxes instead of underestimating their download cost.
    static boolean offlineBounds(double south, double west, double north, double east, double zoom) {
        if (!validZoom(zoom) || !Double.isFinite(south) || !Double.isFinite(west)
                || !Double.isFinite(north) || !Double.isFinite(east)
                || south < -85 || north > 85 || west < -180 || east > 180
                || south > north || west > east || east - west > 180) return false;
        if (distance(south, west, north, east) > 100000) return false;
        double scale = Math.pow(2, Math.ceil(zoom));
        double columns = Math.ceil((east - west) / 360 * scale) + 2;
        double rows = Math.ceil(Math.abs(mercator(north) - mercator(south)) * scale) + 2;
        return columns * rows * 4 / 3 <= MAX_TILES;
    }

    private static double mercator(double lat) {
        double rad = Math.toRadians(lat);
        return (1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2;
    }

    private static double distance(double lat1, double lon1, double lat2, double lon2) {
        double a = Math.pow(Math.sin(Math.toRadians(lat2 - lat1) / 2), 2)
            + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
            * Math.pow(Math.sin(Math.toRadians(lon2 - lon1) / 2), 2);
        return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, a)));
    }
}
