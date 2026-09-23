package com.outsystems.mapbox;

import android.Manifest;
import android.content.pm.PackageManager;

import org.apache.cordova.CallbackContext;
import org.json.JSONArray;
import org.json.JSONException;

import java.util.ArrayList;
import java.util.List;

/**
 * Adds a first-run runtime location permission flow in front of the existing
 * MapboxPluginEntry implementation. Location-dependent Cordova actions are
 * queued while Android shows the native permission dialog and are resumed
 * automatically after the user grants permission.
 */
public class MapboxPluginPermissionEntry extends MapboxPluginEntry {
    private static final int LOCATION_PERMISSION_REQUEST_CODE = 7341;

    private final List<PendingAction> pendingLocationActions = new ArrayList<>();
    private boolean locationPermissionRequestInFlight = false;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) {
        if (!requiresLocationPermission(action) || hasLocationPermission()) {
            return super.execute(action, args, callbackContext);
        }

        synchronized (pendingLocationActions) {
            if (pendingLocationActions.size() >= 32 || args.toString().length() > MapboxSecurity.MAX_INPUT_CHARS) {
                callbackContext.error("Too many pending location requests or input too large.");
                return true;
            }
            pendingLocationActions.add(new PendingAction(action, args, callbackContext));
        }

        requestLocationPermissionIfNeeded();
        return true;
    }

    private boolean requiresLocationPermission(String action) {
        return "enableUserLocation".equals(action)
            || "setDeviceHeadingEnabled".equals(action)
            || "setUserTrackingEnabled".equals(action)
            || "startPathTracking".equals(action)
            || "moveToCurrentLocation".equals(action);
    }

    private boolean hasLocationPermission() {
        return cordova.hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            || cordova.hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION);
    }

    private void requestLocationPermissionIfNeeded() {
        synchronized (pendingLocationActions) {
            if (locationPermissionRequestInFlight) {
                return;
            }
            locationPermissionRequestInFlight = true;
        }

        cordova.requestPermissions(
            this,
            LOCATION_PERMISSION_REQUEST_CODE,
            new String[] {
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            }
        );
    }

    @Override
    public void onRequestPermissionResult(
        int requestCode,
        String[] permissions,
        int[] grantResults
    ) throws JSONException {
        if (requestCode != LOCATION_PERMISSION_REQUEST_CODE) {
            super.onRequestPermissionResult(requestCode, permissions, grantResults);
            return;
        }

        List<PendingAction> actions;
        synchronized (pendingLocationActions) {
            locationPermissionRequestInFlight = false;
            actions = new ArrayList<>(pendingLocationActions);
            pendingLocationActions.clear();
        }

        boolean granted = false;
        for (int result : grantResults) {
            if (result == PackageManager.PERMISSION_GRANTED) {
                granted = true;
                break;
            }
        }

        if (!granted) {
            for (PendingAction action : actions) {
                action.callbackContext.error("Location permission is not granted.");
            }
            return;
        }

        for (PendingAction action : actions) {
            super.execute(action.action, action.args, action.callbackContext);
        }
    }

    @Override
    protected void cancelPendingLocationActions() {
        synchronized (pendingLocationActions) {
            for (PendingAction action : pendingLocationActions) {
                action.callbackContext.error("Location request was cancelled.");
            }
            pendingLocationActions.clear();
        }
    }

    private static final class PendingAction {
        private final String action;
        private final JSONArray args;
        private final CallbackContext callbackContext;

        private PendingAction(
            String action,
            JSONArray args,
            CallbackContext callbackContext
        ) {
            this.action = action;
            this.args = args;
            this.callbackContext = callbackContext;
        }
    }
}
