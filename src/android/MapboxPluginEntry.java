package com.outsystems.mapbox;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.util.Log;
import android.os.Bundle;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import android.content.SharedPreferences;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKey;

import com.mapbox.bindgen.Value;

import com.mapbox.common.MapboxOptions;
import com.mapbox.common.Cancelable;
import com.mapbox.common.TileRegionLoadOptions;
import com.mapbox.common.TileStore;
import com.mapbox.common.TilesetDescriptor;
import com.mapbox.geojson.Point;
import com.mapbox.geojson.Polygon;
import com.mapbox.maps.CameraOptions;
import com.mapbox.maps.GlyphsRasterizationMode;
import com.mapbox.maps.MapView;
import com.mapbox.maps.OfflineManager;
import com.mapbox.maps.ScreenCoordinate;
import com.mapbox.maps.Style;
import com.mapbox.maps.StylePackLoadOptions;
import com.mapbox.maps.TilesetDescriptorOptions;
import com.mapbox.maps.extension.style.layers.properties.generated.IconAnchor;
import com.mapbox.maps.plugin.PuckBearing;
import com.mapbox.maps.plugin.Plugin;
import com.mapbox.maps.plugin.annotation.AnnotationPlugin;
import com.mapbox.maps.plugin.annotation.generated.PointAnnotation;
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationManager;
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationManagerKt;
import com.mapbox.maps.plugin.annotation.generated.PointAnnotationOptions;
import com.mapbox.maps.plugin.annotation.generated.PolygonAnnotation;
import com.mapbox.maps.plugin.annotation.generated.PolygonAnnotationManager;
import com.mapbox.maps.plugin.annotation.generated.PolygonAnnotationManagerKt;
import com.mapbox.maps.plugin.annotation.generated.PolygonAnnotationOptions;
import com.mapbox.maps.plugin.animation.CameraAnimationsPlugin;
import com.mapbox.maps.plugin.animation.MapAnimationOptions;
import com.mapbox.maps.plugin.gestures.GesturesPlugin;
import com.mapbox.maps.plugin.gestures.OnMapClickListener;
import com.mapbox.maps.plugin.locationcomponent.LocationComponentPlugin;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public class MapboxPluginEntry extends CordovaPlugin {
    private static final int MAX_MARKERS = 10000;
    private static final int MAX_BOUNDARIES = 1000;
    private static final double MAX_OFFLINE_RADIUS_KM = 50.0;
    private static final double MIN_OFFLINE_ZOOM = 2.0;
    private static final double MAX_OFFLINE_ZOOM = 18.0;
    private static final long MAX_LOCATION_AGE_MS = 30_000L;
    private static final float VERY_ACCURATE_METERS = 5f;
    private static final float ACCURATE_METERS = 15f;
    private static final float MODERATE_METERS = 30f;
    private static final float LOW_METERS = 100f;

    private MapView mapView;
    private FrameLayout rootView;
    private final List<TouchRect> touchableRects = new ArrayList<>();
    private SensorManager sensorManager;
    private SensorEventListener headingSensorListener;
    private final float[] headingRotationMatrix = new float[9];
    private final float[] headingOrientationValues = new float[3];
    private double lastHeadingBearing = -1.0;
    private long lastHeadingUpdateMs = 0L;
    private LocationManager locationManager;
    private LocationListener userTrackingListener;
    private long lastUserTrackingUpdateMs = 0L;
    private Location lastAcceptedTrackingLocation = null;

    private static final float MAX_ACCEPTABLE_ACCURACY_METERS = 25.0f;
    private static final float MAX_STATIONARY_JITTER_METERS = 3.0f;
    private static final float MAX_REASONABLE_SPEED_MPS = 50.0f;
    private static final long MIN_TRACKING_CAMERA_INTERVAL_MS = 700L;

    private CallbackContext moveToCurrentLocationCallback = null;
    private LocationListener moveToCurrentLocationListener = null;
    private LocationManager moveToCurrentLocationManager = null;
    private double moveToCurrentLocationZoom = 0.0;
    private boolean moveToCurrentLocationZoomSet = false;
    private float currentLocationAccuracy = -1f;
    private String currentLocationAccuracyLabel = "Unknown";
    private PointAnnotationManager pointAnnotationManager;
    private PolygonAnnotationManager boundaryAnnotationManager;
    private final List<PolygonAnnotationOptions> boundaryAnnotationOptions = new ArrayList<>();
    private final List<PolygonAnnotation> boundaryAnnotations = new ArrayList<>();
    private final Map<String, String> markerRecordIds = new HashMap<>();
    private final Map<String, PointAnnotation> markerAnnotationsByRecordId = new HashMap<>();
    private final Map<String, Point> markerPointsByRecordId = new HashMap<>();
    private CallbackContext waypointSelectedCallback;
    private CallbackContext markerClickCallback;
    private CallbackContext offlineDownloadProgressCallback;
    private OfflineManager activeOfflineManager;
    private TileStore activeOfflineTileStore;
    private Cancelable activeStylePackDownload;
    private Cancelable activeTileRegionDownload;
    private boolean isOfflineDownloading = false;
    private boolean waypointSelectionEnabled = false;
    private boolean autoAddWaypointMarker = false;
    private OnMapClickListener mapClickListener;
    private float rawTapDownX = 0.0f;
    private float rawTapDownY = 0.0f;
    private long rawTapDownMs = 0L;
    private long lastMapSelectionCallbackMs = 0L;
    private long lastKeepCallbackOfflineMs = 0L;
    private long lastKeepCallbackWaypointMs = 0L;
    private long lastKeepCallbackMarkerMs = 0L;
    private static final long CALLBACK_RATE_LIMIT_MS = 100L;
    private boolean boundaryVisible = true;
    private boolean isUserLocationEnabled = false;
    private boolean isUserTrackingEnabled = false;
    private boolean isDeviceHeadingEnabled = false;
    private boolean isHeadingFollowModeEnabled = false;
    private CallbackContext trackingStatusCallback;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) {
        JSONObject options = args.optJSONObject(0);
        if (options == null) {
            options = new JSONObject();
        }

        switch (action) {
            case "ping":
                try {
                    JSONObject result = new JSONObject();
                    result.put("status", "ok");
                    result.put("service", "MapboxPlugin");
                    result.put("class", "MapboxPluginEntry");
                    callbackContext.success(result);
                } catch (Exception e) {
                    callbackContext.error(e.getMessage());
                }
                return true;
            case "initialize":
                initialize(options, callbackContext);
                return true;
            case "setViewport":
                setViewport(options, callbackContext);
                return true;
            case "resizeMap":
                resizeMap(options, callbackContext);
                return true;
            case "setTouchableRects":
                setTouchableRects(args, callbackContext);
                return true;
            case "setCamera":
                setCamera(options, callbackContext);
                return true;
            case "flyTo":
                flyTo(options, callbackContext);
                return true;
            case "enableUserLocation":
                enableUserLocation(callbackContext);
                return true;
            case "setDeviceHeadingEnabled":
                setDeviceHeadingEnabled(options, callbackContext);
                return true;
            case "setHeadingFollowMode":
                setHeadingFollowMode(options, callbackContext);
                return true;
            case "setUserTrackingEnabled":
                setUserTrackingEnabled(options, callbackContext);
                return true;
            case "moveToCurrentLocation":
                moveToCurrentLocation(options, callbackContext);
                return true;
            case "downloadOfflineRegion":
                downloadOfflineRegion(options, callbackContext);
                return true;
            case "downloadOfflineRegionForRect":
                downloadOfflineRegionForRect(options, callbackContext);
                return true;
            case "showOfflineRegion":
                showOfflineRegion(options, callbackContext);
                return true;
            case "deleteOfflineRegion":
                deleteOfflineRegion(options, callbackContext);
                return true;
            case "registerOfflineDownloadProgressCallback":
                registerOfflineDownloadProgressCallback(callbackContext);
                return true;
            case "setWaypointSelectionEnabled":
                setWaypointSelectionEnabled(options, callbackContext);
                return true;
            case "registerWaypointSelectedCallback":
                registerWaypointSelectedCallback(callbackContext);
                return true;
            case "registerMarkerClickCallback":
                registerMarkerClickCallback(callbackContext);
                return true;
            case "registerTrackingStatusCallback":
                registerTrackingStatusCallback(callbackContext);
                return true;
            case "getCamera":
                getCamera(callbackContext);
                return true;
            case "getCurrentLocationAccuracy":
                getCurrentLocationAccuracy(callbackContext);
                return true;
            case "addMarker":
                addMarker(options, callbackContext);
                return true;
            case "loadMarkers":
                loadMarkers(options, callbackContext);
                return true;
            case "removeMarker":
                removeMarker(options, callbackContext);
                return true;
            case "clearMarkers":
                clearMarkers(callbackContext);
                return true;
            case "loadBoundaries":
                loadBoundaries(options, callbackContext);
                return true;
            case "setBoundaryVisibility":
                setBoundaryVisibility(options, callbackContext);
                return true;
            case "clearBoundaries":
                clearBoundaries(callbackContext);
                return true;
            case "close":
                close(callbackContext);
                return true;
            default:
                return false;
        }
    }

    private void initialize(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            try {
                String token = getAccessToken();
                if (token.isEmpty()) {
                    callback.error("Mapbox access token is required. Configure MAPBOX_ACCESS_TOKEN in OutSystems Extensibility Configuration.");
                    return;
                }

                MapboxOptions.setAccessToken(token);

                String styleUrl = options.optString("styleUrl", Style.MAPBOX_STREETS);
                double latitude = options.optDouble("latitude", 0.0);
                double longitude = options.optDouble("longitude", 0.0);
                double zoom = options.optDouble("zoom", 12.0);

                if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
                    callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                    return;
                }

                closeInternal();

                boolean behindWebView = options.optBoolean("behindWebView", false);

                rootView = new FrameLayout(cordova.getActivity());
                rootView.setBackgroundColor(behindWebView ? Color.TRANSPARENT : Color.WHITE);
                rootView.setLayoutParams(layoutParamsFromOptions(options));

                mapView = new MapView(cordova.getActivity());
                mapView.setLayoutParams(new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    Gravity.CENTER
                ));

                rootView.addView(mapView);
                mapView.onStart();
                installMapClickListener();

                if (!options.optBoolean("inline", false)) {
                    Button closeButton = new Button(cordova.getActivity());
                    closeButton.setText("Close");
                    closeButton.setOnClickListener(view -> closeInternal());

                    FrameLayout.LayoutParams buttonParams = new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP | Gravity.END
                    );
                    buttonParams.topMargin = 48;
                    buttonParams.rightMargin = 24;
                    closeButton.setLayoutParams(buttonParams);
                    rootView.addView(closeButton);
                }

                if (behindWebView) {
                    addBehindWebView(rootView);
                } else {
                    ViewGroup decor = (ViewGroup) cordova.getActivity().getWindow().getDecorView();
                    decor.addView(rootView);
                }

                mapView.getMapboxMap().setCamera(new CameraOptions.Builder()
                    .center(Point.fromLngLat(longitude, latitude))
                    .zoom(zoom)
                    .build());

                mapView.getMapboxMap().loadStyle(styleUrl);

                JSONObject result = new JSONObject();
                result.put("status", "initialized");
                callback.success(result);
            } catch (Throwable e) {
                callback.error(sanitizeError("Failed to initialize Mapbox map.", e));
            }
        });
    }

    private String getAccessToken() {
        String token = getTokenFromSecureStorage();
        if (!token.isEmpty()) {
            return token;
        }

        token = preferences.getString("MAPBOX_ACCESS_TOKEN", "");
        if ("__MAPBOX_ACCESS_TOKEN_NOT_SET__".equals(token)) {
            token = "";
        }
        if (!token.isEmpty()) {
            saveTokenToSecureStorage(token);
        }
        return token;
    }

    private String getTokenFromSecureStorage() {
        try {
            MasterKey masterKey = new MasterKey.Builder(cordova.getActivity())
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build();
            SharedPreferences securePrefs = EncryptedSharedPreferences.create(
                cordova.getActivity(),
                "mapbox_secure_prefs",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            );
            return securePrefs.getString("mapbox_access_token", "");
        } catch (Exception e) {
            return "";
        }
    }

    private void saveTokenToSecureStorage(String token) {
        try {
            MasterKey masterKey = new MasterKey.Builder(cordova.getActivity())
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build();
            SharedPreferences securePrefs = EncryptedSharedPreferences.create(
                cordova.getActivity(),
                "mapbox_secure_prefs",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            );
            securePrefs.edit().putString("mapbox_access_token", token).apply();
        } catch (Exception e) {
            // Silent fail — next launch will fall back to preferences
        }
    }

    private void setViewport(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (rootView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            rootView.setLayoutParams(layoutParamsFromOptions(options));
            rootView.requestLayout();
            callback.success();
        });
    }

    private void resizeMap(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (rootView == null || mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            int x = options.optInt("x", 0);
            int y = options.optInt("y", 0);
            int width = options.optInt("width", 1);
            int height = options.optInt("height", 1);

            int[] webViewLocation = new int[2];
            webView.getView().getLocationInWindow(webViewLocation);

            int webViewTop = webViewLocation[1];
            int webViewLeft = webViewLocation[0];

            int nativeX = x + webViewLeft;
            int nativeY = y + webViewTop;

            FrameLayout.LayoutParams params;
            ViewGroup.LayoutParams currentParams = rootView.getLayoutParams();

            if (currentParams instanceof FrameLayout.LayoutParams) {
                params = (FrameLayout.LayoutParams) currentParams;
            } else {
                params = new FrameLayout.LayoutParams(width, height);
            }

            params.width = width;
            params.height = height;
            params.leftMargin = nativeX;
            params.topMargin = nativeY;
            rootView.setLayoutParams(params);

            FrameLayout.LayoutParams mapParams =
                new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                );
            mapView.setLayoutParams(mapParams);

            rootView.requestLayout();
            mapView.requestLayout();
            callback.success();
        });
    }

   private void setTouchableRects(JSONArray args, CallbackContext callback) {
    cordova.getActivity().runOnUiThread(() -> {
        touchableRects.clear();

        JSONArray rects = args.optJSONArray(0);

        if (rects == null || rects.length() == 0) {
            callback.success();
            return;
        }

        int maxRects = 50;

        if (rects.length() > maxRects) {
            callback.error(
                "Too many touchable rects. Maximum is " + maxRects + "."
            );
            return;
        }

        for (int i = 0; i < rects.length(); i++) {
            JSONObject rect = rects.optJSONObject(i);

            if (rect == null) {
                continue;
            }

            double x = rect.optDouble("x", 0.0);
            double y = rect.optDouble("y", 0.0);
            double width = rect.optDouble("width", 0.0);
            double height = rect.optDouble("height", 0.0);

            if (width <= 0 || height <= 0) {
                continue;
            }

            touchableRects.add(
                new TouchRect(x, y, width, height)
            );
        }

        callback.success();
    });
}
    private void setCamera(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            double setCamLat = options.optDouble("latitude", 0.0);
            double setCamLng = options.optDouble("longitude", 0.0);
            if (!isValidLatitude(setCamLat) || !isValidLongitude(setCamLng)) {
                callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                return;
            }

            mapView.getMapboxMap().setCamera(new CameraOptions.Builder()
                .center(Point.fromLngLat(setCamLng, setCamLat))
                .zoom(options.optDouble("zoom", mapView.getMapboxMap().getCameraState().getZoom()))
                .bearing(options.optDouble("bearing", mapView.getMapboxMap().getCameraState().getBearing()))
                .pitch(options.optDouble("pitch", mapView.getMapboxMap().getCameraState().getPitch()))
                .build());

            callback.success();
        });
    }

    private void flyTo(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            double flyLat = options.optDouble("latitude", 0.0);
            double flyLng = options.optDouble("longitude", 0.0);
            if (!isValidLatitude(flyLat) || !isValidLongitude(flyLng)) {
                callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                return;
            }

            CameraAnimationsPlugin cameraAnimations = mapView.getPlugin(Plugin.MAPBOX_CAMERA_PLUGIN_ID);
            if (cameraAnimations == null) {
                callback.error("Camera animations plugin is not available.");
                return;
            }

            CameraOptions cameraOptions = new CameraOptions.Builder()
                .center(Point.fromLngLat(flyLng, flyLat))
                .zoom(options.optDouble("zoom", mapView.getMapboxMap().getCameraState().getZoom()))
                .bearing(options.optDouble("bearing", mapView.getMapboxMap().getCameraState().getBearing()))
                .pitch(options.optDouble("pitch", mapView.getMapboxMap().getCameraState().getPitch()))
                .build();

            MapAnimationOptions.Builder animationOptions = new MapAnimationOptions.Builder();
            if (options.has("duration")) {
                animationOptions.duration(options.optLong("duration", 2000L));
            }

            cameraAnimations.flyTo(cameraOptions, animationOptions.build(), null);
            callback.success();
        });
    }

    private void enableUserLocation(CallbackContext callback) {
        if (mapView == null) {
            callback.error("Map is not initialized.");
            return;
        }

        cordova.getActivity().runOnUiThread(() -> {
            try {
                LocationComponentPlugin locationPlugin =
                    mapView.getPlugin(
                        Plugin.MAPBOX_LOCATION_COMPONENT_PLUGIN_ID
                    );

                if (locationPlugin == null) {
                    callback.error(
                        "Mapbox location component is not available."
                    );
                    return;
                }

                locationPlugin.setPuckBearing(
                    PuckBearing.HEADING
                );

                locationPlugin.setEnabled(true);

                callback.success();
            } catch (Exception e) {
                callback.error(
                    "Unable to enable user location: "
                        + e.getMessage()
                );
            }
        });
    }

    private boolean hasPermission(String permission) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true;
        }

        return cordova.getActivity().checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean hasLocationPermission() {
        return hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            || hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION);
    }

    private void setDeviceHeadingEnabled(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            boolean hasFineLocation = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION);
            boolean hasCoarseLocation = hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION);

            if (!hasFineLocation && !hasCoarseLocation) {
                callback.error("Location permission is not granted.");
                return;
            }

            LocationComponentPlugin location =
                mapView.getPlugin(Plugin.MAPBOX_LOCATION_COMPONENT_PLUGIN_ID);

            if (location == null) {
                callback.error("Location component is not available.");
                return;
            }

            boolean enabled = options.optBoolean("enabled", true);
            location.setEnabled(true);
            location.setPuckBearing(PuckBearing.HEADING);
            location.setPuckBearingEnabled(enabled);

            isDeviceHeadingEnabled = enabled;
            fireTrackingStatusChanged();

            callback.success();
        });
    }

    private void setHeadingFollowMode(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            boolean enabled = options.optBoolean("enabled", true);

            if (!enabled) {
                stopHeadingFollowMode();
                callback.success();
                return;
            }

            startHeadingFollowMode(callback);
        });
    }

    private void startHeadingFollowMode(CallbackContext callback) {
        stopHeadingFollowMode();

        sensorManager = (SensorManager) cordova.getActivity().getSystemService(Context.SENSOR_SERVICE);
        if (sensorManager == null) {
            callback.error("Device sensor manager is not available.");
            return;
        }

        Sensor rotationVectorSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
        if (rotationVectorSensor == null) {
            callback.error("Device rotation sensor is not available.");
            return;
        }

        headingSensorListener = new SensorEventListener() {
            @Override
            public void onSensorChanged(SensorEvent event) {
                if (mapView == null || event.sensor.getType() != Sensor.TYPE_ROTATION_VECTOR) {
                    return;
                }

                SensorManager.getRotationMatrixFromVector(headingRotationMatrix, event.values);
                SensorManager.getOrientation(headingRotationMatrix, headingOrientationValues);

                double bearing = Math.toDegrees(headingOrientationValues[0]);
                if (bearing < 0) {
                    bearing += 360.0;
                }

                long now = System.currentTimeMillis();
                if (now - lastHeadingUpdateMs < 80L) {
                    return;
                }

                if (lastHeadingBearing >= 0.0) {
                    double diff = Math.abs(bearing - lastHeadingBearing);
                    diff = Math.min(diff, 360.0 - diff);

                    if (diff < 1.5) {
                        return;
                    }

                    bearing = lastHeadingBearing + shortestBearingDelta(lastHeadingBearing, bearing) * 0.25;
                    if (bearing < 0.0) {
                        bearing += 360.0;
                    } else if (bearing >= 360.0) {
                        bearing -= 360.0;
                    }
                }

                lastHeadingBearing = bearing;
                lastHeadingUpdateMs = now;

                final double cameraBearing = bearing;
                cordova.getActivity().runOnUiThread(() -> {
                    if (mapView != null) {
                        mapView.getMapboxMap().setCamera(new CameraOptions.Builder()
                            .bearing(cameraBearing)
                            .build());
                    }
                });
            }

            @Override
            public void onAccuracyChanged(Sensor sensor, int accuracy) {
            }
        };

        sensorManager.registerListener(
            headingSensorListener,
            rotationVectorSensor,
            SensorManager.SENSOR_DELAY_UI
        );

        isHeadingFollowModeEnabled = true;
        fireTrackingStatusChanged();

        callback.success();
    }

    private void stopHeadingFollowMode() {
        if (sensorManager != null && headingSensorListener != null) {
            sensorManager.unregisterListener(headingSensorListener);
        }

        headingSensorListener = null;
        lastHeadingBearing = -1.0;
        lastHeadingUpdateMs = 0L;
        isHeadingFollowModeEnabled = false;
        fireTrackingStatusChanged();
    }

    private double shortestBearingDelta(double from, double to) {
        return (to - from + 540.0) % 360.0 - 180.0;
    }

    private void setUserTrackingEnabled(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            boolean enabled = options.optBoolean("enabled", true);
            if (!enabled) {
                stopUserTracking();
                callback.success();
                return;
            }

            startUserTracking(callback);
        });
    }

    private void startUserTracking(CallbackContext callback) {
        if (!hasLocationPermission()) {
            callback.error("Location permission is not granted.");
            return;
        }

        // Stop previous tracking and reset filter state
        stopUserTracking();

        locationManager = (LocationManager) cordova
            .getActivity()
            .getSystemService(Context.LOCATION_SERVICE);

        if (locationManager == null) {
            callback.error("Device location manager is not available.");
            return;
        }

        userTrackingListener = new LocationListener() {
            @Override
            public void onLocationChanged(Location location) {
                if (mapView == null || location == null) {
                    return;
                }

                long now = System.currentTimeMillis();

                // 1. Reject poor accuracy locations
                if (location.hasAccuracy()
                        && location.getAccuracy()
                        > MAX_ACCEPTABLE_ACCURACY_METERS) {
                    return;
                }

                // 2. Prevent excessive camera updates
                if (now - lastUserTrackingUpdateMs
                        < MIN_TRACKING_CAMERA_INTERVAL_MS) {
                    return;
                }

                double latitude = location.getLatitude();
                double longitude = location.getLongitude();

                // 3. Validate coordinates
                if (!isValidLatitude(latitude)
                        || !isValidLongitude(longitude)) {
                    return;
                }

                // 4. Reject GPS drift and unrealistic jumps
                if (lastAcceptedTrackingLocation != null) {
                    float distance =
                        lastAcceptedTrackingLocation.distanceTo(location);
                    long timeDifference =
                        location.getTime()
                        - lastAcceptedTrackingLocation.getTime();

                    // Ignore tiny movements while stationary
                    if (distance < MAX_STATIONARY_JITTER_METERS) {
                        return;
                    }

                    // Reject unrealistic jumps
                    if (timeDifference > 0) {
                        float speed =
                            distance / (timeDifference / 1000.0f);
                        if (speed > MAX_REASONABLE_SPEED_MPS) {
                            return;
                        }
                    }
                }

                // Accept this location
                lastAcceptedTrackingLocation =
                    new Location(location);
                lastUserTrackingUpdateMs = now;

                final Point cameraPoint =
                    Point.fromLngLat(longitude, latitude);

                // Update the camera for the accepted location.
                cordova.getActivity().runOnUiThread(() -> {
                    if (mapView == null) {
                        return;
                    }

                    CameraAnimationsPlugin cameraAnimations =
                        mapView.getPlugin(
                            Plugin.MAPBOX_CAMERA_PLUGIN_ID
                        );
                    CameraOptions cameraOptions =
                        new CameraOptions.Builder()
                            .center(cameraPoint)
                            .build();

                    if (cameraAnimations != null) {
                        cameraAnimations.easeTo(
                            cameraOptions,
                            new MapAnimationOptions.Builder()
                                .duration(800L)
                                .build(),
                            null
                        );
                    } else {
                        // Fallback if animation plugin is unavailable
                        mapView.getMapboxMap()
                            .setCamera(cameraOptions);
                    }
                });
            }

            @Override
            public void onStatusChanged(
                    String provider,
                    int status,
                    Bundle extras) {
            }

            @Override
            public void onProviderEnabled(String provider) {
            }

            @Override
            public void onProviderDisabled(String provider) {
            }
        };

        try {
            boolean gpsEnabled =
                locationManager.isProviderEnabled(
                    LocationManager.GPS_PROVIDER
                );
            boolean networkEnabled =
                locationManager.isProviderEnabled(
                    LocationManager.NETWORK_PROVIDER
                );

            // Prefer GPS for better tracking accuracy
            if (gpsEnabled) {
                locationManager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    1000L,
                    2.0f,
                    userTrackingListener
                );
            // Use Network only when GPS is unavailable
            } else if (networkEnabled) {
                locationManager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    1000L,
                    3.0f,
                    userTrackingListener
                );
            }

            // No location provider is available
            if (!gpsEnabled && !networkEnabled) {
                stopUserTracking();
                callback.error("Location provider is not enabled.");
                return;
            }

            isUserTrackingEnabled = true;
            fireTrackingStatusChanged();
            callback.success();
        } catch (SecurityException e) {
            stopUserTracking();
            callback.error("Location permission is not granted.");
        }
    }

    private void stopUserTracking() {
        if (locationManager != null && userTrackingListener != null) {
            try {
                locationManager.removeUpdates(userTrackingListener);
            } catch (SecurityException ignored) {
            }
        }

        userTrackingListener = null;
        lastUserTrackingUpdateMs = 0L;

        lastAcceptedTrackingLocation = null;
        isUserTrackingEnabled = false;
        fireTrackingStatusChanged();
    }

    private void moveToCurrentLocation(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            moveToCurrentLocationZoomSet = options.has("zoom");
            moveToCurrentLocationZoom = options.optDouble("zoom", 0.0);

            if (!hasLocationPermission()) {
                callback.error("Location permission is not granted.");
                return;
            }

            startMoveToCurrentLocation(callback);
        });
    }

    private void startMoveToCurrentLocation(CallbackContext callback) {
        unregisterMoveToCurrentLocation();

        LocationManager manager = (LocationManager) cordova.getActivity().getSystemService(Context.LOCATION_SERVICE);
        if (manager == null) {
            callback.error("Device location manager is not available.");
            return;
        }

        moveToCurrentLocationManager = manager;
        moveToCurrentLocationCallback = callback;

        moveToCurrentLocationListener = new LocationListener() {
            @Override
            public void onLocationChanged(Location location) {
                if (location == null) {
                    return;
                }

                currentLocationAccuracy = location.hasAccuracy() ? location.getAccuracy() : -1f;
                currentLocationAccuracyLabel = getAccuracyLabel(currentLocationAccuracy);

                final double latitude = location.getLatitude();
                final double longitude = location.getLongitude();

                if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
                    if (moveToCurrentLocationCallback != null) {
                        moveToCurrentLocationCallback.error(
                            "Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180]."
                        );
                    }
                    return;
                }

                if (moveToCurrentLocationCallback == null) {
                    return;
                }

                final CallbackContext pendingCallback = moveToCurrentLocationCallback;
                final boolean applyZoom = moveToCurrentLocationZoomSet;
                final double zoom = moveToCurrentLocationZoom;

                moveToCurrentLocationCallback = null;

                cordova.getActivity().runOnUiThread(() -> {
                    if (mapView != null) {
                        CameraOptions.Builder cameraBuilder = new CameraOptions.Builder()
                            .center(Point.fromLngLat(longitude, latitude));
                        if (applyZoom) {
                            cameraBuilder.zoom(zoom);
                        }
                        mapView.getMapboxMap().setCamera(cameraBuilder.build());
                    }

                    JSONObject result = new JSONObject();
                    try {
                        result.put("latitude", latitude);
                        result.put("longitude", longitude);
                        result.put("accuracy", currentLocationAccuracy);
                        result.put("accuracyLabel", currentLocationAccuracyLabel);
                        pendingCallback.success(result);
                    } catch (JSONException e) {
                        pendingCallback.error(e.getMessage());
                    }
                });
            }

            @Override
            public void onStatusChanged(String provider, int status, Bundle extras) {
            }

            @Override
            public void onProviderEnabled(String provider) {
            }

            @Override
            public void onProviderDisabled(String provider) {
            }
        };

        try {
            boolean gpsEnabled = manager.isProviderEnabled(LocationManager.GPS_PROVIDER);
            boolean networkEnabled = manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER);

            if (gpsEnabled) {
                manager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    0L,
                    0.0f,
                    moveToCurrentLocationListener
                );
            }

            if (networkEnabled) {
                manager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    0L,
                    0.0f,
                    moveToCurrentLocationListener
                );
            }

            if (!gpsEnabled && !networkEnabled) {
                cancelMoveToCurrentLocation();
                callback.error("Location provider is not enabled.");
            }
        } catch (SecurityException e) {
            cancelMoveToCurrentLocation();
            callback.error("Location permission is not granted.");
        }
    }

    private String getAccuracyLabel(float accuracy) {
        if (accuracy < 0) {
            return "Unknown";
        } else if (accuracy <= VERY_ACCURATE_METERS) {
            return "Very accurate";
        } else if (accuracy <= ACCURATE_METERS) {
            return "Accurate";
        } else if (accuracy <= MODERATE_METERS) {
            return "Moderately";
        } else if (accuracy <= LOW_METERS) {
            return "Low";
        } else {
            return "Poor";
        }
    }

    private void unregisterMoveToCurrentLocation() {
        if (moveToCurrentLocationManager != null && moveToCurrentLocationListener != null) {
            try {
                moveToCurrentLocationManager.removeUpdates(moveToCurrentLocationListener);
            } catch (SecurityException ignored) {
            }
        }

        moveToCurrentLocationManager = null;
        moveToCurrentLocationListener = null;
        moveToCurrentLocationCallback = null;
    }

    private void cancelMoveToCurrentLocation() {
        unregisterMoveToCurrentLocation();
        moveToCurrentLocationZoom = 0.0;
        moveToCurrentLocationZoomSet = false;
    }

    private void downloadOfflineRegion(JSONObject options, CallbackContext callback) {
        sendOfflineProgress("started", 0, 100);
        cordova.getActivity().runOnUiThread(() -> {
            try {
                sendOfflineProgress("native-entered", 0, 100);

                if (mapView == null) {
                    callback.error("Map is not initialized.");
                    return;
                }

                double latitude = options.optDouble("latitude", 0.0);
                double longitude = options.optDouble("longitude", 0.0);

                if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
                    callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                    return;
                }

                double radiusKm = options.optDouble("radiusKm", 10.0);
                double minZoom = options.optDouble("minZoom", 10.0);
                double maxZoom = options.optDouble("maxZoom", 16.0);
                String styleUrl = options.optString("styleUrl", Style.MAPBOX_STREETS);
                String regionId = options.optString(
                    "regionId",
                    "offline-" + Math.round(latitude * 100000.0) + "-" + Math.round(longitude * 100000.0)
                );

                startOfflineDownload(
                    regionId,
                    latitude,
                    longitude,
                    radiusKm,
                    minZoom,
                    maxZoom,
                    styleUrl,
                    null,
                    callback
                );
            } catch (Throwable e) {
                callback.error(sanitizeError("Failed to start offline download.", e));
            }
        });
    }

    private void downloadOfflineRegionForRect(JSONObject options, CallbackContext callback) {
        sendOfflineProgress("started", 0, 100);
        cordova.getActivity().runOnUiThread(() -> {
            try {
                sendOfflineProgress("native-entered", 0, 100);

                if (mapView == null) {
                    callback.error("Map is not initialized.");
                    return;
                }

                double x = options.optDouble("x", 0.0);
                double y = options.optDouble("y", 0.0);
                double width = options.optDouble("width", 1.0);
                double height = options.optDouble("height", 1.0);
                double minZoom = options.optDouble("minZoom", 10.0);
                double maxZoom = options.optDouble("maxZoom", 16.0);
                String styleUrl = options.optString("styleUrl", Style.MAPBOX_STREETS);
                String regionId = options.optString("regionId", "offline-rect-" + System.currentTimeMillis());

                Polygon polygon = createRectPolygon(x, y, width, height);
                Point center = mapView.getMapboxMap().coordinateForPixel(
                    new ScreenCoordinate(x + width / 2.0, y + height / 2.0)
                );

                startOfflineDownload(
                    regionId,
                    center.latitude(),
                    center.longitude(),
                    0.0,
                    minZoom,
                    maxZoom,
                    styleUrl,
                    polygon,
                    callback
                );
            } catch (Throwable e) {
                callback.error(sanitizeError("Failed to start offline region download.", e));
            }
        });
    }

    private void startOfflineDownload(
        String regionId,
        double latitude,
        double longitude,
        double radiusKm,
        double minZoom,
        double maxZoom,
        String styleUrl,
        Polygon geometry,
        CallbackContext callback
    ) {
        if (isOfflineDownloading) {
            callback.error("An offline region download is already in progress.");
            return;
        }
        final double clampedRadiusKm = clamp(radiusKm, 0.0, MAX_OFFLINE_RADIUS_KM);
        final double clampedMinZoom = clamp(minZoom, MIN_OFFLINE_ZOOM, MAX_OFFLINE_ZOOM);
        final double clampedMaxZoom = clamp(maxZoom, clampedMinZoom, MAX_OFFLINE_ZOOM);
        isOfflineDownloading = true;
        cancelCurrentDownload();
        activeOfflineManager = new OfflineManager();
        sendOfflineProgress("style-start", 0, 100);

        StylePackLoadOptions stylePackOptions = new StylePackLoadOptions.Builder()
            .glyphsRasterizationMode(GlyphsRasterizationMode.IDEOGRAPHS_RASTERIZED_LOCALLY)
            .metadata(metadataValue(regionId))
            .acceptExpired(false)
            .build();

        activeStylePackDownload = activeOfflineManager.loadStylePack(
            styleUrl,
            stylePackOptions,
            progress -> sendOfflineProgress("style", progress.getCompletedResourceCount(), progress.getRequiredResourceCount()),
            expectedStylePack -> expectedStylePack.fold(
                error -> {
                    isOfflineDownloading = false;
                    callback.error(sanitizeError("Failed to download style pack.", error));
                    return null;
                },
                stylePack -> {
                    sendOfflineProgress("tiles-start", 0, 100);
                    downloadOfflineTiles(
                        activeOfflineManager,
                        regionId,
                        latitude,
                        longitude,
                        clampedRadiusKm,
                        clampedMinZoom,
                        clampedMaxZoom,
                        styleUrl,
                        geometry,
                        callback
                    );
                    return null;
                }
            )
        );
    }

    private void downloadOfflineTiles(
        OfflineManager offlineManager,
        String regionId,
        double latitude,
        double longitude,
        double radiusKm,
        double minZoom,
        double maxZoom,
        String styleUrl,
        Polygon geometry,
        CallbackContext callback
    ) {
        cordova.getActivity().runOnUiThread(() -> {
            try {
                TilesetDescriptorOptions descriptorOptions = new TilesetDescriptorOptions.Builder()
                    .styleURI(styleUrl)
                    .pixelRatio(cordova.getActivity().getResources().getDisplayMetrics().density)
                    .minZoom(toZoomByte(minZoom))
                    .maxZoom(toZoomByte(maxZoom))
                    .build();

                TilesetDescriptor descriptor = offlineManager.createTilesetDescriptor(descriptorOptions);

                TileRegionLoadOptions tileRegionOptions = new TileRegionLoadOptions.Builder()
                    .geometry(geometry == null ? createCirclePolygon(longitude, latitude, radiusKm) : geometry)
                    .descriptors(Collections.singletonList(descriptor))
                    .metadata(metadataValue(regionId))
                    .acceptExpired(false)
                    .build();

                activeOfflineTileStore = TileStore.create();
                activeTileRegionDownload = activeOfflineTileStore.loadTileRegion(
                    regionId,
                    tileRegionOptions,
                    progress -> sendOfflineProgress("tiles", progress.getCompletedResourceCount(), progress.getRequiredResourceCount()),
                    expectedTileRegion -> expectedTileRegion.fold(
                        error -> {
                            isOfflineDownloading = false;
                            callback.error(sanitizeError("Failed to download tile region.", error));
                            return null;
                        },
                        tileRegion -> {
                            isOfflineDownloading = false;
                            try {
                                JSONObject result = new JSONObject();
                                result.put("regionId", regionId);
                                result.put("latitude", latitude);
                                result.put("longitude", longitude);
                                result.put("radiusKm", radiusKm);
                                callback.success(result);
                            } catch (Exception e) {
                                callback.error(sanitizeError("An internal error occurred.", e));
                            }
                            return null;
                        }
                    )
                );
            } catch (Throwable e) {
                isOfflineDownloading = false;
                callback.error(sanitizeError("Failed to download offline tiles.", e));
            }
        });
    }

    private Polygon createRectPolygon(double x, double y, double width, double height) {
        Point topLeft = mapView.getMapboxMap().coordinateForPixel(new ScreenCoordinate(x, y));
        Point topRight = mapView.getMapboxMap().coordinateForPixel(new ScreenCoordinate(x + width, y));
        Point bottomRight = mapView.getMapboxMap().coordinateForPixel(new ScreenCoordinate(x + width, y + height));
        Point bottomLeft = mapView.getMapboxMap().coordinateForPixel(new ScreenCoordinate(x, y + height));

        List<Point> points = new ArrayList<>();
        points.add(topLeft);
        points.add(topRight);
        points.add(bottomRight);
        points.add(bottomLeft);
        points.add(topLeft);

        return Polygon.fromLngLats(Collections.singletonList(points));
    }

    private Polygon createCirclePolygon(double longitude, double latitude, double radiusKm) {
        List<Point> points = new ArrayList<>();
        double earthRadiusKm = 6371.0088;
        double angularDistance = radiusKm / earthRadiusKm;
        double latitudeRad = Math.toRadians(latitude);
        double longitudeRad = Math.toRadians(longitude);

        for (int i = 0; i <= 64; i++) {
            double bearing = 2.0 * Math.PI * i / 64.0;
            double pointLatitude = Math.asin(
                Math.sin(latitudeRad) * Math.cos(angularDistance)
                    + Math.cos(latitudeRad) * Math.sin(angularDistance) * Math.cos(bearing)
            );
            double pointLongitude = longitudeRad + Math.atan2(
                Math.sin(bearing) * Math.sin(angularDistance) * Math.cos(latitudeRad),
                Math.cos(angularDistance) - Math.sin(latitudeRad) * Math.sin(pointLatitude)
            );

            points.add(Point.fromLngLat(Math.toDegrees(pointLongitude), Math.toDegrees(pointLatitude)));
        }

        return Polygon.fromLngLats(Collections.singletonList(points));
    }

    private Value metadataValue(String regionId) {
        HashMap<String, Value> metadata = new HashMap<>();
        metadata.put("regionId", Value.valueOf(regionId));
        return Value.valueOf(metadata);
    }

    private void showOfflineRegion(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            double latitude = options.optDouble("latitude", 0.0);
            double longitude = options.optDouble("longitude", 0.0);

            if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
                callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                return;
            }

            double zoom = options.optDouble("zoom", 13.0);
            String styleUrl = options.optString("styleUrl", Style.MAPBOX_STREETS);

            mapView.getMapboxMap().loadStyle(styleUrl);
            mapView.getMapboxMap().setCamera(new CameraOptions.Builder()
                .center(Point.fromLngLat(longitude, latitude))
                .zoom(zoom)
                .build());

            callback.success();
        });
    }

    private void deleteOfflineRegion(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            try {
                String regionId = options.optString("regionId", "");
                String styleUrl = options.optString("styleUrl", Style.MAPBOX_STREETS);
                boolean deleteStylePack = options.optBoolean("deleteStylePack", true);

                if (regionId.trim().isEmpty()) {
                    callback.error("regionId is required.");
                    return;
                }

                TileStore tileStore = TileStore.create();
                tileStore.removeTileRegion(regionId);

                if (deleteStylePack) {
                    OfflineManager offlineManager = new OfflineManager();
                    offlineManager.removeStylePack(styleUrl);
                }

                callback.success();
            } catch (Throwable e) {
                callback.error(sanitizeError("Failed to delete offline region.", e));
            }
        });
    }

    private void registerOfflineDownloadProgressCallback(CallbackContext callback) {
        offlineDownloadProgressCallback = callback;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    private void sendOfflineProgress(String phase, long completed, long required) {
        try {
            JSONObject payload = new JSONObject();
            payload.put("type", "offlineDownloadProgress");
            payload.put("phase", phase);
            payload.put("completed", completed);
            payload.put("required", required);
            payload.put("percent", required > 0 ? Math.round((completed * 100.0) / required) : 0);
            long now = System.currentTimeMillis();
            if (now - lastKeepCallbackOfflineMs >= CALLBACK_RATE_LIMIT_MS) {
                lastKeepCallbackOfflineMs = now;
                sendKeepCallback(offlineDownloadProgressCallback, payload);
            }
        } catch (Exception ignored) {
        }
    }

    private void setWaypointSelectionEnabled(JSONObject options, CallbackContext callback) {
        installMapClickListener();
        waypointSelectionEnabled = options.optBoolean("enabled", true);
        autoAddWaypointMarker = options.optBoolean("autoAddMarker", false);
        callback.success();
    }

    private void registerWaypointSelectedCallback(CallbackContext callback) {
        waypointSelectedCallback = callback;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    private void registerMarkerClickCallback(CallbackContext callback) {
        markerClickCallback = callback;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    private void registerTrackingStatusCallback(CallbackContext callback) {
        trackingStatusCallback = callback;
        PluginResult result = new PluginResult(PluginResult.Status.NO_RESULT);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
        fireTrackingStatusChanged();
    }

    private void fireTrackingStatusChanged() {
        if (trackingStatusCallback == null) {
            return;
        }

        try {
            JSONObject payload = new JSONObject();
            payload.put("userLocation", isUserLocationEnabled);
            payload.put("userTracking", isUserTrackingEnabled);
            payload.put("deviceHeading", isDeviceHeadingEnabled);
            payload.put("headingFollowMode", isHeadingFollowModeEnabled);
            sendKeepCallback(trackingStatusCallback, payload);
        } catch (Exception ignored) {
        }
    }

    private void installMapClickListener() {
        if (mapView == null) {
            return;
        }

        if (mapClickListener != null) {
            GesturesPlugin oldGestures = mapView.getPlugin(Plugin.MAPBOX_GESTURES_PLUGIN_ID);
            if (oldGestures != null) {
                oldGestures.removeOnMapClickListener(mapClickListener);
            }
        }

        GesturesPlugin gestures = mapView.getPlugin(Plugin.MAPBOX_GESTURES_PLUGIN_ID);
        if (gestures == null) {
            return;
        }

        mapClickListener = point -> {
            return handleMapPointSelected(point);
        };

        gestures.addOnMapClickListener(mapClickListener);
    }

    private boolean handleMapPointSelected(Point point) {
        long now = System.currentTimeMillis();
        if (now - lastMapSelectionCallbackMs < 400L) {
            return true;
        }

        if (sendMarkerClickIfNear(point)) {
            lastMapSelectionCallbackMs = now;
            return true;
        }

        if (!waypointSelectionEnabled) {
            return false;
        }

        String id = "";
        if (autoAddWaypointMarker) {
            id = String.valueOf(System.currentTimeMillis());
            addMarkerInternal(id, point.latitude(), point.longitude());
        }

        try {
            JSONObject payload = new JSONObject();
            payload.put("type", "waypointSelected");
            payload.put("id", id);
            payload.put("latitude", point.latitude());
            payload.put("longitude", point.longitude());
            if (now - lastKeepCallbackWaypointMs >= CALLBACK_RATE_LIMIT_MS) {
                lastKeepCallbackWaypointMs = now;
                sendKeepCallback(waypointSelectedCallback, payload);
            }
            lastMapSelectionCallbackMs = now;
        } catch (Exception ignored) {
        }

        return true;
    }

    private void handleRawTouchForTap(MotionEvent event) {
        if (mapView == null) {
            return;
        }

        if (event.getAction() == MotionEvent.ACTION_DOWN) {
            rawTapDownX = event.getX();
            rawTapDownY = event.getY();
            rawTapDownMs = System.currentTimeMillis();
            return;
        }

        if (event.getAction() != MotionEvent.ACTION_UP) {
            return;
        }

        float dx = Math.abs(event.getX() - rawTapDownX);
        float dy = Math.abs(event.getY() - rawTapDownY);
        long duration = System.currentTimeMillis() - rawTapDownMs;

        if (dx > 24.0f || dy > 24.0f || duration > 600L) {
            return;
        }

        Point point = mapView.getMapboxMap().coordinateForPixel(
            new ScreenCoordinate(event.getX(), event.getY())
        );
        handleMapPointSelected(point);
    }

    private boolean ensurePointAnnotationManager() {
        if (mapView == null) {
            return false;
        }

        if (pointAnnotationManager != null) {
            return true;
        }

        AnnotationPlugin annotationPlugin = mapView.getPlugin(Plugin.MAPBOX_ANNOTATION_PLUGIN_ID);
        if (annotationPlugin == null) {
            return false;
        }

        pointAnnotationManager = PointAnnotationManagerKt.createPointAnnotationManager(annotationPlugin, null);
        pointAnnotationManager.addClickListener(annotation -> {
            String recordId = markerRecordIds.get(annotation.getId());
            if (recordId == null) {
                recordId = "";
            }

            try {
                JSONObject payload = new JSONObject();
                payload.put("type", "markerClicked");
                payload.put("id", recordId);
                payload.put("latitude", annotation.getPoint().latitude());
                payload.put("longitude", annotation.getPoint().longitude());
                long now = System.currentTimeMillis();
                if (now - lastKeepCallbackMarkerMs >= CALLBACK_RATE_LIMIT_MS) {
                    lastKeepCallbackMarkerMs = now;
                    sendKeepCallback(markerClickCallback, payload);
                }
            } catch (Exception ignored) {
            }

            return true;
        });

        return true;
    }

    private boolean ensureBoundaryAnnotationManager() {
        if (mapView == null) {
            return false;
        }

        if (boundaryAnnotationManager != null) {
            return true;
        }

        AnnotationPlugin annotationPlugin = mapView.getPlugin(Plugin.MAPBOX_ANNOTATION_PLUGIN_ID);
        if (annotationPlugin == null) {
            return false;
        }

        boundaryAnnotationManager = PolygonAnnotationManagerKt.createPolygonAnnotationManager(annotationPlugin, null);
        return true;
    }

    private boolean sendMarkerClickIfNear(Point point) {
        if (markerPointsByRecordId.isEmpty()) {
            return false;
        }

        String nearestId = "";
        Point nearestPoint = null;
        float nearestDistance = Float.MAX_VALUE;
        float[] distance = new float[1];

        for (Map.Entry<String, Point> entry : markerPointsByRecordId.entrySet()) {
            Point markerPoint = entry.getValue();
            Location.distanceBetween(
                point.latitude(),
                point.longitude(),
                markerPoint.latitude(),
                markerPoint.longitude(),
                distance
            );

            if (distance[0] < nearestDistance) {
                nearestDistance = distance[0];
                nearestId = entry.getKey();
                nearestPoint = markerPoint;
            }
        }

        if (nearestPoint == null || nearestDistance > 150.0f) {
            return false;
        }

        try {
            JSONObject payload = new JSONObject();
            payload.put("type", "markerClicked");
            payload.put("id", nearestId);
            payload.put("latitude", nearestPoint.latitude());
            payload.put("longitude", nearestPoint.longitude());
            long now = System.currentTimeMillis();
            if (now - lastKeepCallbackMarkerMs >= CALLBACK_RATE_LIMIT_MS) {
                lastKeepCallbackMarkerMs = now;
                sendKeepCallback(markerClickCallback, payload);
            }
        } catch (Exception ignored) {
        }

        return true;
    }

    private void addMarker(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            String id = options.optString("id", String.valueOf(System.currentTimeMillis()));
            double latitude = options.optDouble("latitude", 0.0);
            double longitude = options.optDouble("longitude", 0.0);

            if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
                callback.error("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].");
                return;
            }

            if (!addMarkerInternal(id, latitude, longitude)) {
                callback.error("Marker manager is not available.");
                return;
            }

            try {
                JSONObject result = new JSONObject();
                result.put("id", id);
                callback.success(result);
            } catch (Exception e) {
                callback.error(sanitizeError("An internal error occurred.", e));
            }
        });
    }

    private void loadMarkers(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            if (!ensurePointAnnotationManager()) {
                callback.error("Marker manager is not available.");
                return;
            }

            if (options.optBoolean("replace", true)) {
                clearMarkersInternal();
            }

            JSONArray markers = options.optJSONArray("markers");
            if (markers == null) {
                callback.success();
                return;
            }

            if (markers.length() > MAX_MARKERS) {
                callback.error("Too many markers: maximum allowed is " + MAX_MARKERS + ".");
                return;
            }

            for (int i = 0; i < markers.length(); i++) {
                JSONObject marker = markers.optJSONObject(i);
                if (marker == null) {
                    continue;
                }

                double markerLat = marker.optDouble("latitude", 0.0);
                double markerLng = marker.optDouble("longitude", 0.0);
                if (!isValidLatitude(markerLat) || !isValidLongitude(markerLng)) {
                    continue;
                }

                addMarkerInternal(
                    marker.optString("id", String.valueOf(i)),
                    markerLat,
                    markerLng
                );
            }

            callback.success();
        });
    }

    private boolean addMarkerInternal(String id, double latitude, double longitude) {
        if (!ensurePointAnnotationManager()) {
            return false;
        }

        removeMarkerInternal(id);

        PointAnnotationOptions markerOptions = new PointAnnotationOptions()
            .withPoint(Point.fromLngLat(longitude, latitude))
            .withIconImage(createWaypointMarkerBitmap())
            .withIconAnchor(IconAnchor.BOTTOM)
            .withIconSize(1.0);

        PointAnnotation annotation = pointAnnotationManager.create(markerOptions);
        markerRecordIds.put(annotation.getId(), id);
        markerAnnotationsByRecordId.put(id, annotation);
        markerPointsByRecordId.put(id, Point.fromLngLat(longitude, latitude));
        return true;
    }

    private void removeMarker(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            removeMarkerInternal(options.optString("id", ""));
            callback.success();
        });
    }

    private void removeMarkerInternal(String id) {
        if (pointAnnotationManager == null || id == null || id.isEmpty()) {
            return;
        }

        PointAnnotation annotation = markerAnnotationsByRecordId.remove(id);
        if (annotation != null) {
            pointAnnotationManager.delete(annotation);
            markerRecordIds.remove(annotation.getId());
        }
        markerPointsByRecordId.remove(id);
    }

    private void clearMarkers(CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            clearMarkersInternal();
            callback.success();
        });
    }

    private void clearMarkersInternal() {
        if (pointAnnotationManager != null) {
            List<PointAnnotation> annotations = new ArrayList<>(pointAnnotationManager.getAnnotations());
            for (PointAnnotation annotation : annotations) {
                pointAnnotationManager.delete(annotation);
            }
        }

        markerRecordIds.clear();
        markerAnnotationsByRecordId.clear();
        markerPointsByRecordId.clear();
    }

    private void loadBoundaries(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            boundaryVisible = options.optBoolean("visible", true);
            boundaryAnnotationOptions.clear();
            clearBoundaryAnnotations();

            JSONArray boundaries = options.optJSONArray("boundaries");
            if (boundaries != null) {
                if (boundaries.length() > MAX_BOUNDARIES) {
                    callback.error("Too many boundaries: maximum allowed is " + MAX_BOUNDARIES + ".");
                    return;
                }

                String fillColor = options.optString("fillColor", "#2E7D32");
                double fillOpacity = options.optDouble("fillOpacity", 0.18);
                String lineColor = options.optString("lineColor", "#1B5E20");

                for (int i = 0; i < boundaries.length(); i++) {
                    JSONObject boundary = boundaries.optJSONObject(i);
                    PolygonAnnotationOptions boundaryOptions = boundaryOptionsFromJson(boundary, fillColor, fillOpacity, lineColor);
                    if (boundaryOptions != null) {
                        boundaryAnnotationOptions.add(boundaryOptions);
                    }
                }
            }

            applyBoundaryVisibility();

            try {
                JSONObject result = new JSONObject();
                result.put("count", boundaryAnnotationOptions.size());
                callback.success(result);
            } catch (Exception e) {
                callback.error(sanitizeError("An internal error occurred.", e));
            }
        });
    }

    private void setBoundaryVisibility(JSONObject options, CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            boundaryVisible = options.optBoolean("visible", true);
            applyBoundaryVisibility();
            callback.success();
        });
    }

    private void clearBoundaries(CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            clearBoundariesInternal();
            callback.success();
        });
    }

    private PolygonAnnotationOptions boundaryOptionsFromJson(JSONObject boundary, String fillColor, double fillOpacity, String lineColor) {
        if (boundary == null) {
            return null;
        }

        JSONArray geometry = boundary.optJSONArray("geometry");
        if (geometry == null) {
            return null;
        }

        List<Point> ring = new ArrayList<>();
        for (int i = 0; i < geometry.length(); i++) {
            JSONObject coordinate = geometry.optJSONObject(i);
            if (coordinate == null) {
                continue;
            }

            double latitude = readFiniteDouble(coordinate, "lat", "latitude");
            double longitude = readFiniteDouble(coordinate, "lon", "lng", "longitude");
            if (!Double.isNaN(latitude) && !Double.isNaN(longitude) && isValidLatitude(latitude) && isValidLongitude(longitude)) {
                ring.add(Point.fromLngLat(longitude, latitude));
            }
        }

        if (ring.size() < 3) {
            return null;
        }

        Point firstPoint = ring.get(0);
        Point lastPoint = ring.get(ring.size() - 1);
        if (firstPoint.latitude() != lastPoint.latitude() || firstPoint.longitude() != lastPoint.longitude()) {
            ring.add(firstPoint);
        }

        return new PolygonAnnotationOptions()
            .withPoints(Collections.singletonList(ring))
            .withFillColor(fillColor)
            .withFillOpacity(fillOpacity)
            .withFillOutlineColor(lineColor);
    }

    private static boolean isValidLatitude(double lat) {
        return !Double.isNaN(lat) && !Double.isInfinite(lat) && lat >= -90.0 && lat <= 90.0;
    }

    private static boolean isValidLongitude(double lon) {
        return !Double.isNaN(lon) && !Double.isInfinite(lon) && lon >= -180.0 && lon <= 180.0;
    }

    private double readFiniteDouble(JSONObject object, String... keys) {
        for (String key : keys) {
            if (!object.has(key)) {
                continue;
            }

            double value = object.optDouble(key, Double.NaN);
            if (!Double.isNaN(value) && !Double.isInfinite(value)) {
                return value;
            }
        }

        return Double.NaN;
    }

    private void applyBoundaryVisibility() {
        if (!boundaryVisible) {
            clearBoundaryAnnotations();
            return;
        }

        if (!ensureBoundaryAnnotationManager()) {
            return;
        }

        clearBoundaryAnnotations();
        for (PolygonAnnotationOptions options : boundaryAnnotationOptions) {
            boundaryAnnotations.add(boundaryAnnotationManager.create(options));
        }
    }

    private void clearBoundaryAnnotations() {
        if (boundaryAnnotationManager != null) {
            for (PolygonAnnotation annotation : new ArrayList<>(boundaryAnnotations)) {
                boundaryAnnotationManager.delete(annotation);
            }
        }
        boundaryAnnotations.clear();
    }

    private void clearBoundariesInternal() {
        boundaryAnnotationOptions.clear();
        clearBoundaryAnnotations();
        boundaryVisible = true;
    }

    private Bitmap createWaypointMarkerBitmap() {
        int width = 72;
        int height = 96;
        float centerX = width / 2.0f;
        float circleRadius = 25.0f;
        float circleCenterY = 32.0f;

        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);

        Paint shadowPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        shadowPaint.setColor(Color.argb(65, 0, 0, 0));
        canvas.drawOval(centerX - 16.0f, height - 16.0f, centerX + 16.0f, height - 8.0f, shadowPaint);

        Path pinPath = new Path();
        pinPath.addCircle(centerX, circleCenterY, circleRadius, Path.Direction.CW);
        pinPath.moveTo(centerX - 14.0f, circleCenterY + 19.0f);
        pinPath.quadTo(centerX - 5.0f, circleCenterY + 52.0f, centerX, height - 10.0f);
        pinPath.quadTo(centerX + 5.0f, circleCenterY + 52.0f, centerX + 14.0f, circleCenterY + 19.0f);
        pinPath.close();

        Paint pinPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        pinPaint.setColor(Color.rgb(220, 38, 38));
        canvas.drawPath(pinPath, pinPaint);

        Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeWidth(3.0f);
        strokePaint.setColor(Color.WHITE);
        canvas.drawPath(pinPath, strokePaint);

        Paint centerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        centerPaint.setColor(Color.WHITE);
        canvas.drawCircle(centerX, circleCenterY, 10.0f, centerPaint);

        Paint innerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        innerPaint.setStyle(Paint.Style.STROKE);
        innerPaint.setStrokeWidth(2.0f);
        innerPaint.setColor(Color.argb(40, 0, 0, 0));
        canvas.drawCircle(centerX, circleCenterY, 10.0f, innerPaint);

        return bitmap;
    }

    private void sendKeepCallback(CallbackContext callback, JSONObject payload) {
        if (callback == null) {
            return;
        }

        PluginResult result = new PluginResult(PluginResult.Status.OK, payload);
        result.setKeepCallback(true);
        callback.sendPluginResult(result);
    }

    private void getCamera(CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            if (mapView == null) {
                callback.error("Map is not initialized.");
                return;
            }

            try {
                JSONObject result = new JSONObject();
                result.put("latitude", mapView.getMapboxMap().getCameraState().getCenter().latitude());
                result.put("longitude", mapView.getMapboxMap().getCameraState().getCenter().longitude());
                result.put("zoom", mapView.getMapboxMap().getCameraState().getZoom());
                result.put("bearing", mapView.getMapboxMap().getCameraState().getBearing());
                result.put("pitch", mapView.getMapboxMap().getCameraState().getPitch());
                callback.success(result);
            } catch (Exception e) {
                callback.error(sanitizeError("An internal error occurred.", e));
            }
        });
    }

    private void getCurrentLocationAccuracy(final CallbackContext callbackContext) {
        if (!hasLocationPermission()) {
            callbackContext.success("Unknown");
            return;
        }

        LocationManager locationManager =
            (LocationManager) cordova.getActivity()
                .getSystemService(Context.LOCATION_SERVICE);

        if (locationManager == null) {
            callbackContext.success("Unknown");
            return;
        }

        Location bestLocation = getBestAvailableLocation(locationManager);

        if (bestLocation == null || !bestLocation.hasAccuracy()) {
            callbackContext.success("Unknown");
            return;
        }

        callbackContext.success(getAccuracyLabel(bestLocation.getAccuracy()));
    }

    private Location getBestAvailableLocation(LocationManager locationManager) {
        Location gpsLocation = null;
        Location networkLocation = null;

        try {
            gpsLocation = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER);
        } catch (SecurityException ignored) {
        }

        try {
            networkLocation = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER);
        } catch (SecurityException ignored) {
        }

        long now = System.currentTimeMillis();

        boolean gpsValid =
            gpsLocation != null &&
            gpsLocation.hasAccuracy() &&
            now - gpsLocation.getTime() <= MAX_LOCATION_AGE_MS;

        boolean networkValid =
            networkLocation != null &&
            networkLocation.hasAccuracy() &&
            now - networkLocation.getTime() <= MAX_LOCATION_AGE_MS;

        if (gpsValid && networkValid) {
            return gpsLocation.getAccuracy() <= networkLocation.getAccuracy()
                ? gpsLocation
                : networkLocation;
        }

        if (gpsValid) {
            return gpsLocation;
        }

        if (networkValid) {
            return networkLocation;
        }

        return null;
    }

    private void close(CallbackContext callback) {
        cordova.getActivity().runOnUiThread(() -> {
            closeInternal();
            callback.success();
        });
    }

    private void cancelCurrentDownload() {
        if (activeStylePackDownload != null) {
            activeStylePackDownload.cancel();
            activeStylePackDownload = null;
        }
        if (activeTileRegionDownload != null) {
            activeTileRegionDownload.cancel();
            activeTileRegionDownload = null;
        }
        activeOfflineManager = null;
        activeOfflineTileStore = null;
    }

    private void closeInternal() {
        stopHeadingFollowMode();
        stopUserTracking();
        cancelMoveToCurrentLocation();

        if (mapView != null) {
            try {
                mapView.onStop();
                mapView.onDestroy();
            } catch (Throwable ignored) {
                // MapView may already be partially torn down after a failed initialization.
            }
        }

        if (rootView != null && rootView.getParent() instanceof ViewGroup) {
            ((ViewGroup) rootView.getParent()).removeView(rootView);
        }

        mapView = null;
        rootView = null;
        pointAnnotationManager = null;
        boundaryAnnotationManager = null;
        boundaryAnnotationOptions.clear();
        boundaryAnnotations.clear();
        boundaryVisible = true;
        markerRecordIds.clear();
        markerAnnotationsByRecordId.clear();
        markerPointsByRecordId.clear();
        waypointSelectedCallback = null;
        markerClickCallback = null;
        offlineDownloadProgressCallback = null;
        trackingStatusCallback = null;
        cancelCurrentDownload();
        isOfflineDownloading = false;
        waypointSelectionEnabled = false;
        autoAddWaypointMarker = false;
        isUserLocationEnabled = false;
        isUserTrackingEnabled = false;
        isDeviceHeadingEnabled = false;
        isHeadingFollowModeEnabled = false;
        mapClickListener = null;
        touchableRects.clear();
    }

    private void addBehindWebView(View nativeView) {
        View webViewView = webView.getView();
        webViewView.setBackgroundColor(Color.TRANSPARENT);
        installTouchRouter(webViewView);

        if (webViewView.getParent() instanceof ViewGroup) {
            ViewGroup parent = (ViewGroup) webViewView.getParent();
            int webViewIndex = parent.indexOfChild(webViewView);
            parent.addView(nativeView, Math.max(0, webViewIndex));
            return;
        }

        ViewGroup decor = (ViewGroup) cordova.getActivity().getWindow().getDecorView();
        decor.addView(nativeView, 0);
    }

    private void installTouchRouter(View webViewView) {
        webViewView.setOnTouchListener((view, event) -> {
            if (mapView == null || isInsideTouchableRect(event.getX(), event.getY())) {
                return false;
            }

            handleRawTouchForTap(event);

            MotionEvent mapEvent = MotionEvent.obtain(event);
            try {
                mapView.dispatchTouchEvent(mapEvent);
            } finally {
                mapEvent.recycle();
            }
            return true;
        });
    }

    private boolean isInsideTouchableRect(float x, float y) {
        for (TouchRect rect : touchableRects) {
            if (rect.contains(x, y)) {
                return true;
            }
        }

        return false;
    }

    private FrameLayout.LayoutParams layoutParamsFromOptions(JSONObject options) {
        if (!options.optBoolean("inline", false)) {
            return new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            );
        }

        int screenWidth = cordova.getActivity().getResources().getDisplayMetrics().widthPixels;
        int screenHeight = cordova.getActivity().getResources().getDisplayMetrics().heightPixels;

        int x = clamp((int) options.optDouble("x", 0.0), 0, screenWidth - 1);
        int y = clamp((int) options.optDouble("y", 0.0), 0, screenHeight - 1);
        int width = clamp((int) options.optDouble("width", 1.0), 1, screenWidth - x);
        int height = clamp((int) options.optDouble("height", 1.0), 1, screenHeight - y);

        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(width, height);
        params.leftMargin = x;
        params.topMargin = y;
        return params;
    }

    private int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(value, Math.max(min, max)));
    }

    private String sanitizeError(String contextMessage, Throwable t) {
        Log.e("MapboxPlugin", contextMessage, t);
        return contextMessage;
    }

    private String sanitizeError(String contextMessage, Object t) {
        Log.e("MapboxPlugin", contextMessage + ": " + t);
        return contextMessage;
    }

    private static double clamp(double value, double min, double max) {
        return Math.max(min, Math.min(max, value));
    }

    private static byte toZoomByte(double value) {
        return (byte) Math.max(0, Math.min(Math.round(value), 127));
    }

    private static class TouchRect {
        private final double x;
        private final double y;
        private final double width;
        private final double height;

        private TouchRect(double x, double y, double width, double height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }

        private boolean contains(double pointX, double pointY) {
            return pointX >= x && pointX <= x + width && pointY >= y && pointY <= y + height;
        }
    }

    @Override
    public void onResume(boolean multitasking) {
        super.onResume(multitasking);
        if (mapView != null) {
            mapView.onStart();
        }
    }

    @Override
    public void onPause(boolean multitasking) {
        if (mapView != null) {
            mapView.onStop();
        }
        super.onPause(multitasking);
    }

    @Override
    public void onDestroy() {
        closeInternal();
        super.onDestroy();
    }

    @Override
    public void onReset() {
        cancelMoveToCurrentLocation();
        waypointSelectedCallback = null;
        markerClickCallback = null;
        offlineDownloadProgressCallback = null;
        lastKeepCallbackOfflineMs = 0L;
        lastKeepCallbackWaypointMs = 0L;
        lastKeepCallbackMarkerMs = 0L;
    }
}
