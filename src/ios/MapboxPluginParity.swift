import Foundation
import CoreLocation
import UIKit
import MapboxMaps

/// Adds the Cordova actions that already exist on Android but were missing on iOS.
/// The base MapboxPlugin keeps the existing implementation; this subclass only
/// supplies parity actions and behavior differences that need to match Android.
@objc(MapboxPluginParity)
class MapboxPluginParity: MapboxPlugin {
    private let mapboxSdkVersion = "11.30.0"
    private let maxLocationAge: TimeInterval = 30
    private let locationAccuracyCallbackInterval: TimeInterval = 0.5
    private let trackingCameraInterval: TimeInterval = 0.4
    private let locationSmoothingFactor: Double = 0.35
    private let trackingCameraAnimationDuration: TimeInterval = 0.25

    private var locationAccuracyCallbackId: String?
    private var accuracyLocationManager: CLLocationManager?
    private var lastLocationAccuracyUpdate: TimeInterval = 0
    private var lastTrackingLocationUpdate: TimeInterval = 0
    private var smoothedTrackingCoordinate: CLLocationCoordinate2D?
    private var parityPathTrackingActive = false
    private let locationFilter = LocationFilter()

    private var moveLocationManager: CLLocationManager?
    private var moveLocationCallbackId: String?
    private var moveLocationZoom: Double?

    @objc(getMapboxVersion:)
    func getMapboxVersion(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        let result = CDVPluginResult(
            status: CDVCommandStatus_OK,
            messageAs: mapboxSdkVersion
        )
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(resizeMap:)
    func resizeMap(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        // iOS setViewport already resizes/repositions both the MapView and its
        // touch overlay, so use the same path for resizeMap.
        super.setViewport(command: command)
    }

    @objc(registerLocationAccuracyCallback:)
    func registerLocationAccuracyCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        locationAccuracyCallbackId = command.callbackId
        lastLocationAccuracyUpdate = 0

        let result: CDVPluginResult! = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: command.callbackId)

        runForSession {
            if self.accuracyLocationManager == nil {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone
                self.accuracyLocationManager = manager
            }

            if CLLocationManager.authorizationStatus() == .notDetermined {
                self.accuracyLocationManager?.requestWhenInUseAuthorization()
            }

            self.accuracyLocationManager?.startUpdatingLocation()
        }
    }

    @objc(getCurrentLocationAccuracy:)
    func getCurrentLocationAccuracy(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard CLLocationManager.authorizationStatus() == .authorizedWhenInUse
                    || CLLocationManager.authorizationStatus() == .authorizedAlways else {
                self.sendAccuracyResult(accuracy: -1, label: "Unknown", command: command)
                return
            }

            if self.accuracyLocationManager == nil {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone
                self.accuracyLocationManager = manager
            }

            guard self.accuracyLocationManager?.accuracyAuthorization == .fullAccuracy else {
                self.sendAccuracyResult(accuracy: -1, label: "Unknown", command: command)
                return
            }

            guard let location = self.accuracyLocationManager?.location,
                  location.horizontalAccuracy >= 0,
                  abs(location.timestamp.timeIntervalSinceNow) <= self.maxLocationAge else {
                self.sendAccuracyResult(accuracy: -1, label: "Unknown", command: command)
                return
            }

            let accuracy = location.horizontalAccuracy
            self.sendAccuracyResult(
                accuracy: accuracy,
                label: self.accuracyLabel(for: accuracy),
                command: command
            )
        }
    }

    @objc(setUserTrackingEnabled:)
    override func setUserTrackingEnabled(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        let enabled = boolOption(options["enabled"], defaultValue: true)
        resetTrackingSmoothing()
        if !enabled {
            parityPathTrackingActive = false
        }
        super.setUserTrackingEnabled(command: command)
    }

    @objc(startPathTracking:)
    override func startPathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        parityPathTrackingActive = true
        resetTrackingSmoothing()
        super.startPathTracking(command: command)
    }

    @objc(stopPathTracking:)
    override func stopPathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        super.stopPathTracking(command: command)
        parityPathTrackingActive = false
        resetTrackingSmoothing()
    }

    @objc(moveToCurrentLocation:)
    override func moveToCurrentLocation(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.activeMapView() != nil else {
                self.sendParityError("Map is not initialized.", command: command)
                return
            }

            let authorization = CLLocationManager.authorizationStatus()
            if authorization == .denied || authorization == .restricted {
                self.sendParityError("Location permission is not granted.", command: command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            self.moveLocationZoom = options["zoom"] == nil
                ? nil
                : self.doubleValue(options["zoom"], defaultValue: 0)
            self.resumeCameraFollowing()
            self.moveLocationCallbackId = command.callbackId

            if self.moveLocationManager == nil {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = kCLDistanceFilterNone
                self.moveLocationManager = manager
            }

            if authorization == .notDetermined {
                self.moveLocationManager?.requestWhenInUseAuthorization()
            }

            self.moveLocationManager?.startUpdatingLocation()
        }
    }

    @objc(setLayerVisibility:)
    func setLayerVisibility(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let layerId = (options["layerId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = self.boolOption(options["visible"], defaultValue: true)

            guard !layerId.isEmpty else {
                self.sendParityError("layerId is required", command: command)
                return
            }

            guard let mapView = self.activeMapView() else {
                self.sendParityError("Map is not initialized.", command: command)
                return
            }

            guard mapView.mapboxMap.isStyleLoaded else {
                self.sendParityError("Style is not loaded yet.", command: command)
                return
            }

            let exists = mapView.mapboxMap.allLayerIdentifiers.contains { $0.id == layerId }
            guard exists else {
                self.sendParityError("Layer not found in current style: \(layerId)", command: command)
                return
            }

            do {
                try mapView.mapboxMap.setLayerProperty(
                    for: layerId,
                    property: "visibility",
                    value: visible ? "visible" : "none"
                )
                self.sendParitySuccess(command)
            } catch {
                self.sendParityError("Failed to change layer visibility.", command: command)
            }
        }
    }

    @objc(getLayerIds:)
    func getLayerIds(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.activeMapView() else {
                self.sendParityError("Map is not initialized.", command: command)
                return
            }

            guard mapView.mapboxMap.isStyleLoaded else {
                self.sendParityError("Style is not loaded yet.", command: command)
                return
            }

            let ids = mapView.mapboxMap.allLayerIdentifiers.map { $0.id }
            let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: ids)
            self.forgetCallback(command.callbackId)
            self.commandDelegate.send(result, callbackId: command.callbackId)
        }
    }

    override func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }

        if manager === moveLocationManager {
            handleMoveToCurrentLocation(location, manager: manager)
            return
        }

        if manager === accuracyLocationManager {
            sendLocationAccuracyUpdate(location)
            return
        }

        guard isTrackingLocationManager(manager) else { return }

        // Accuracy updates are independent from camera throttling so the UI can
        // receive fresh GPS quality information even while camera updates are gated.
        sendLocationAccuracyUpdate(location)

        let rawCoordinate = location.coordinate
        guard rawCoordinate.latitude.isFinite,
              rawCoordinate.longitude.isFinite,
              rawCoordinate.latitude >= -90,
              rawCoordinate.latitude <= 90,
              rawCoordinate.longitude >= -180,
              rawCoordinate.longitude <= 180 else {
            return
        }

        // The accuracy-weighted filter sees every fix, before the camera throttle below.
        var weightedCoordinate: CLLocationCoordinate2D?
        if accuracyWeightedFilter {
            guard let estimate = locationFilter.update(
                latitude: rawCoordinate.latitude,
                longitude: rawCoordinate.longitude,
                accuracy: location.horizontalAccuracy,
                timeMs: Int64(location.timestamp.timeIntervalSince1970 * 1000),
                speed: location.speed >= 0 ? location.speed : -1.0
            ) else {
                logLocationDiagnostic("dropped-filter", location, cam: smoothedTrackingCoordinate)
                return
            }
            weightedCoordinate = CLLocationCoordinate2D(latitude: estimate.latitude, longitude: estimate.longitude)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTrackingLocationUpdate >= trackingCameraInterval else {
            logLocationDiagnostic("throttled", location, cam: smoothedTrackingCoordinate)
            return
        }
        lastTrackingLocationUpdate = now

        let cameraCoordinate: CLLocationCoordinate2D
        if let weighted = weightedCoordinate {
            cameraCoordinate = weighted
        } else if let previous = smoothedTrackingCoordinate {
            cameraCoordinate = CLLocationCoordinate2D(
                latitude: previous.latitude
                    + (rawCoordinate.latitude - previous.latitude) * locationSmoothingFactor,
                longitude: previous.longitude
                    + (rawCoordinate.longitude - previous.longitude) * locationSmoothingFactor
            )
        } else {
            // Accept the first valid fix immediately. iOS has no 25 m gate here,
            // so the camera does not wait for a high-accuracy cold-start fix.
            cameraCoordinate = rawCoordinate
        }
        smoothedTrackingCoordinate = cameraCoordinate
        logLocationDiagnostic("accepted", location, cam: cameraCoordinate)

        if parityPathTrackingActive {
            // Preserve the inherited path recorder, but feed it the same smoothed
            // coordinate used by the camera so path tracking does not reintroduce
            // raw GPS jitter.
            let smoothedLocation = CLLocation(
                coordinate: cameraCoordinate,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                course: location.course,
                speed: location.speed,
                timestamp: location.timestamp
            )
            super.locationManager(manager, didUpdateLocations: [smoothedLocation])
        }

        runForSession {
            guard self.isTrackingLocationManager(manager), self.isCameraFollowingUser else { return }
            guard let mapView = self.activeMapView() else {
                return
            }
            mapView.camera.ease(
                to: CameraOptions(center: cameraCoordinate),
                duration: self.trackingCameraAnimationDuration
            )
        }
    }

    // Opt-in field-test log (initialize option locationDiagnostics). Writes coordinates to the console: never enable in production.
    // On iOS the blue dot is drawn by Mapbox from the raw location; `cam` is the filtered camera/path coordinate.
    private func logLocationDiagnostic(_ tag: String, _ location: CLLocation, cam: CLLocationCoordinate2D?) {
        guard locationDiagnostics else { return }
        let camText = cam.map { String(format: "%.7f,%.7f", $0.latitude, $0.longitude) } ?? "none"
        NSLog("MapboxPlugin: gps %@ raw=%.7f,%.7f acc=%.1f speed=%.2f t=%lld cam=%@",
              tag, location.coordinate.latitude, location.coordinate.longitude,
              location.horizontalAccuracy, location.speed,
              Int64(location.timestamp.timeIntervalSince1970 * 1000), camText)
    }

    override func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if manager === moveLocationManager, let callbackId = moveLocationCallbackId {
            stopMoveLocationUpdates()
            sendParityError(
                "Failed to get current location.",
                callbackId: callbackId
            )
            return
        }

        super.locationManager(manager, didFailWithError: error)
    }

    override func closeInternal() {
        stopAccuracyMonitoring()
        stopMoveLocationUpdates()
        parityPathTrackingActive = false
        resetTrackingSmoothing()
        super.closeInternal()
    }

    private func resetTrackingSmoothing() {
        lastTrackingLocationUpdate = 0
        smoothedTrackingCoordinate = nil
        locationFilter.reset()
    }

    private func handleMoveToCurrentLocation(_ location: CLLocation, manager: CLLocationManager) {
        guard let callbackId = moveLocationCallbackId else {
            return
        }

        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              coordinate.latitude >= -90, coordinate.latitude <= 90,
              coordinate.longitude >= -180, coordinate.longitude <= 180 else {
            stopMoveLocationUpdates()
            sendParityError(
                "Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].",
                callbackId: callbackId
            )
            return
        }

        let zoom = moveLocationZoom
        stopMoveLocationUpdates()

        runForSession {
            guard let mapView = self.activeMapView() else {
                self.sendParityError("Map is not initialized.", callbackId: callbackId)
                return
            }

            if self.isCameraFollowingUser {
                if let zoom = zoom {
                    mapView.mapboxMap.setCamera(to: CameraOptions(center: coordinate, zoom: zoom))
                } else {
                    mapView.mapboxMap.setCamera(to: CameraOptions(center: coordinate))
                }
            }

            let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : -1
            let result = CDVPluginResult(
                status: CDVCommandStatus_OK,
                messageAs: [
                    "latitude": coordinate.latitude,
                    "longitude": coordinate.longitude,
                    "accuracy": accuracy,
                    "accuracyLabel": self.accuracyLabel(for: accuracy)
                ]
            )
            self.forgetCallback(callbackId)
            self.commandDelegate.send(result, callbackId: callbackId)
        }
    }

    private func sendLocationAccuracyUpdate(_ location: CLLocation) {
        guard let callbackId = locationAccuracyCallbackId,
              location.horizontalAccuracy >= 0 else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLocationAccuracyUpdate >= locationAccuracyCallbackInterval else {
            return
        }
        lastLocationAccuracyUpdate = now

        let payload: [String: Any] = [
            "type": "locationAccuracy",
            "accuracy": Int(location.horizontalAccuracy.rounded()),
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]

        let result: CDVPluginResult! = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: callbackId)
    }

    private func sendAccuracyResult(
        accuracy: CLLocationAccuracy,
        label: String,
        command: CDVInvokedUrlCommand
    ) {
        let result = CDVPluginResult(
            status: CDVCommandStatus_OK,
            messageAs: [
                "accuracy": accuracy,
                "accuracyLabel": label
            ]
        )
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func accuracyLabel(for accuracy: CLLocationAccuracy) -> String {
        if accuracy < 0 {
            return "Unknown"
        } else if accuracy <= 5 {
            return "Very accurate"
        } else if accuracy <= 15 {
            return "Accurate"
        } else if accuracy <= 30 {
            return "Moderately"
        } else if accuracy <= 100 {
            return "Low"
        } else {
            return "Poor"
        }
    }

    private func stopAccuracyMonitoring() {
        accuracyLocationManager?.stopUpdatingLocation()
        accuracyLocationManager?.delegate = nil
        accuracyLocationManager = nil
        locationAccuracyCallbackId = nil
        lastLocationAccuracyUpdate = 0
    }

    private func stopMoveLocationUpdates() {
        moveLocationManager?.stopUpdatingLocation()
        moveLocationManager?.delegate = nil
        moveLocationManager = nil
        moveLocationCallbackId = nil
        moveLocationZoom = nil
    }

    private func activeMapView() -> MapView? {
        guard let root = webView.superview else {
            return nil
        }
        return findMapView(in: root)
    }

    private func findMapView(in view: UIView) -> MapView? {
        if let mapView = view as? MapView {
            return mapView
        }

        for subview in view.subviews {
            if let mapView = findMapView(in: subview) {
                return mapView
            }
        }

        return nil
    }

    private func doubleValue(_ value: Any?, defaultValue: Double) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        return defaultValue
    }

    private func sendParitySuccess(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendParityError(_ message: String, command: CDVInvokedUrlCommand) {
        sendParityError(message, callbackId: command.callbackId)
    }

    private func sendParityError(_ message: String, callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        forgetCallback(callbackId)
        commandDelegate.send(result, callbackId: callbackId)
    }
}
