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

    private var moveLocationManager: CLLocationManager?
    private var moveLocationCallbackId: String?
    private var moveLocationZoom: Double?
    private let moveLocationTimeout: TimeInterval = 15
    private var moveLocationTimeoutWork: DispatchWorkItem?

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
            self.ensureAccuracyLocationManager()

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

            self.ensureAccuracyLocationManager()

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
        let enabled = options["enabled"] as? Bool ?? true
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
    func moveToCurrentLocation(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let authorization = CLLocationManager.authorizationStatus()
            if authorization == .denied || authorization == .restricted {
                self.sendError("Location permission is not granted.", command)
                return
            }

            if let previous = self.moveLocationCallbackId {
                // Settle the earlier request, as Android does, instead of orphaning it.
                self.stopMoveLocationUpdates()
                self.sendError("Location request superseded.", callbackId: previous)
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            self.moveLocationZoom = options["zoom"] == nil
                ? nil
                : self.doubleOption(options["zoom"], defaultValue: 0)
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

            // Without a fix (indoors, no signal) the request would otherwise never
            // settle and GPS would stay on until the map closed.
            let callbackId: String = command.callbackId
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.moveLocationCallbackId == callbackId else { return }
                self.stopMoveLocationUpdates()
                self.sendError("No valid location update received within 15 seconds.", callbackId: callbackId)
            }
            self.moveLocationTimeoutWork = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + self.moveLocationTimeout, execute: timeout)
        }
    }

    @objc(setLayerVisibility:)
    func setLayerVisibility(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            let layerId = (options["layerId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = options["visible"] as? Bool ?? true

            guard !layerId.isEmpty else {
                self.sendError("layerId is required", command)
                return
            }

            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let exists = mapView.mapboxMap.allLayerIdentifiers.contains { $0.id == layerId }
            guard exists else {
                self.sendError("Layer not found in current style: \(layerId)", command)
                return
            }

            do {
                try mapView.mapboxMap.setLayerProperty(
                    for: layerId,
                    property: "visibility",
                    value: visible ? "visible" : "none"
                )
                self.sendSuccess(command)
            } catch {
                self.sendError("Failed to change layer visibility.", command)
            }
        }
    }

    // MARK: - Style layer groups (Android parity)
    //
    // Groups are the Mapbox Studio folders stored in each layer's
    // metadata["mapbox:group"], matching the Android implementation.

    @objc(getLayersByGroup:)
    func getLayersByGroup(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let groupId = self.requiredGroupId(command) else { return }
            guard let map = self.loadedStyleMap(command, notInitialized: "Map is not initialized.",
                                                notLoaded: "Style is not loaded.") else { return }
            let layers: [[String: Any]] = map.allLayerIdentifiers
                .filter { self.layerGroup(map, $0.id) == groupId }
                .map { ["id": $0.id, "name": $0.id, "type": $0.type.rawValue] }
            self.sendSuccess([
                "groupId": groupId,
                "totalLayers": layers.count,
                "layers": layers
            ], command)
        }
    }

    @objc(setLayerGroupVisibility:)
    func setLayerGroupVisibility(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let groupId = self.requiredGroupId(command) else { return }
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            let visible = options["visible"] as? Bool ?? true
            guard let map = self.loadedStyleMap(command, notInitialized: "Map is not initialized.",
                                                notLoaded: "Style is not loaded.") else { return }

            let layerIds = map.allLayerIdentifiers.map { $0.id }.filter {
                (self.layerGroup(map, $0) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == groupId
            }
            var updatedLayers: [String] = []
            var failedLayers: [[String: String]] = []
            for layerId in layerIds {
                do {
                    try map.setLayerProperty(for: layerId, property: "visibility",
                                             value: visible ? "visible" : "none")
                } catch {
                    failedLayers.append([
                        "layerId": layerId,
                        "error": error.localizedDescription
                    ])
                    continue
                }
                updatedLayers.append(layerId)
            }

            if updatedLayers.isEmpty {
                let errorResult: [String: Any] = [
                    "groupId": groupId,
                    "matchedLayers": layerIds.count,
                    "updatedCount": 0,
                    "failedLayers": failedLayers
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: errorResult)
                    guard let message = String(data: data, encoding: .utf8) else {
                        self.sendError("Failed to encode group visibility error.", command)
                        return
                    }
                    self.sendError(message, command)
                } catch {
                    self.sendError(
                        "Failed to encode group visibility error: \(error.localizedDescription)",
                        command
                    )
                }
                return
            }

            self.sendSuccess([
                "groupId": groupId,
                "visible": visible,
                "updatedCount": updatedLayers.count,
                "updatedLayers": updatedLayers,
                "failedCount": failedLayers.count,
                "failedLayers": failedLayers
            ], command)
        }
    }

    @objc(ToggleOverlays:)
    func ToggleOverlays(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            let groupId = (options["groupId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = options["visible"] as? Bool ?? true

            guard !groupId.isEmpty else {
                self.sendError("groupId is required", command)
                return
            }

            guard let map = self.loadedStyleMap(
                command,
                notInitialized: "Map is not initialized.",
                notLoaded: "Style is not loaded."
            ) else { return }

            do {
                guard var styleRoot = try JSONSerialization.jsonObject(
                    with: Data(map.styleJSON.utf8)
                ) as? [String: Any],
                      var layers = styleRoot["layers"] as? [Any] else {
                    self.sendError("No root-level layers found in style JSON", command)
                    return
                }

                let requestedVisibility = visible ? "visible" : "none"
                var matchedLayers: [String] = []
                var updatedLayers: [String] = []

                for index in layers.indices {
                    guard var layer = layers[index] as? [String: Any],
                          let metadata = layer["metadata"] as? [String: Any] else {
                        continue
                    }

                    let layerGroup = (metadata["mapbox:group"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard layerGroup == groupId else { continue }

                    let layerId = (layer["id"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !layerId.isEmpty else { continue }

                    matchedLayers.append(layerId)
                    var layout = layer["layout"] as? [String: Any] ?? [:]
                    layout["visibility"] = requestedVisibility
                    layer["layout"] = layout
                    layers[index] = layer
                    updatedLayers.append(layerId)
                }

                if matchedLayers.isEmpty {
                    self.sendSuccess([
                        "groupId": groupId,
                        "visible": visible,
                        "matchedCount": 0,
                        "message": "No layers found for this group"
                    ], command)
                    return
                }

                styleRoot["layers"] = layers
                let data = try JSONSerialization.data(withJSONObject: styleRoot)
                guard let styleJSON = String(data: data, encoding: .utf8) else {
                    self.sendError("Failed to serialize updated style JSON.", command)
                    return
                }

                self.loadReadyStyleJSON(
                    styleJSON,
                    successPayload: [
                        "method": "ROOT_STYLE_JSON_RELOAD",
                        "groupId": groupId,
                        "visible": visible,
                        "requestedVisibility": requestedVisibility,
                        "matchedCount": matchedLayers.count,
                        "updatedCount": updatedLayers.count,
                        "matchedLayers": matchedLayers,
                        "updatedLayers": updatedLayers,
                        "message": "Group visibility updated successfully"
                    ],
                    command: command
                )
            } catch {
                self.sendError(
                    "Failed to update group visibility: \(error.localizedDescription)",
                    command
                )
            }
        }
    }

    private func requiredGroupId(_ command: CDVInvokedUrlCommand) -> String? {
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        let groupId = (options["groupId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupId.isEmpty else {
            sendError("groupId is required", command)
            return nil
        }
        return groupId
    }

    private func loadedStyleMap(_ command: CDVInvokedUrlCommand, notInitialized: String,
                                notLoaded: String) -> MapboxMap? {
        guard let mapView = mapView else {
            sendError(notInitialized, command)
            return nil
        }
        // A style that has not finished loading reports no layers. (isStyleLoaded is
        // deliberately avoided: it was removed from this file in the Nov 13 iOS build fix.)
        guard !mapView.mapboxMap.allLayerIdentifiers.isEmpty else {
            sendError(notLoaded, command)
            return nil
        }
        return mapView.mapboxMap
    }

    private func layerMetadata(_ map: MapboxMap, _ layerId: String) -> [String: Any]? {
        // try? keeps this compiling whether or not the SDK marks layerProperty as throwing.
        (try? map.layerProperty(for: layerId, property: "metadata"))?.value as? [String: Any]
    }

    private func layerGroup(_ map: MapboxMap, _ layerId: String) -> String? {
        layerMetadata(map, layerId)?["mapbox:group"] as? String
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

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTrackingLocationUpdate >= trackingCameraInterval else {
            return
        }
        lastTrackingLocationUpdate = now

        let cameraCoordinate: CLLocationCoordinate2D
        if let previous = smoothedTrackingCoordinate {
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
            guard self.isTrackingLocationManager(manager), self.isCameraFollowingUser,
                  !self.isRecenterAnimating else { return }
            guard let mapView = self.mapView else {
                return
            }
            mapView.camera.ease(
                to: CameraOptions(center: cameraCoordinate),
                duration: self.trackingCameraAnimationDuration
            )
        }
    }

    override func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if manager === moveLocationManager, let callbackId = moveLocationCallbackId {
            stopMoveLocationUpdates()
            sendError(
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

    private func ensureAccuracyLocationManager() {
        guard accuracyLocationManager == nil else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        accuracyLocationManager = manager
    }

    private func resetTrackingSmoothing() {
        lastTrackingLocationUpdate = 0
        smoothedTrackingCoordinate = nil
    }

    private func handleMoveToCurrentLocation(_ location: CLLocation, manager: CLLocationManager) {
        guard let callbackId = moveLocationCallbackId else {
            return
        }

        // iOS usually reports its last cached fix first. Wait for a fresh fix with a
        // valid accuracy, as Android does; the timeout settles the request otherwise.
        guard location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) <= maxLocationAge else {
            return
        }

        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              coordinate.latitude >= -90, coordinate.latitude <= 90,
              coordinate.longitude >= -180, coordinate.longitude <= 180 else {
            stopMoveLocationUpdates()
            sendError(
                "Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].",
                callbackId: callbackId
            )
            return
        }

        let zoom = moveLocationZoom
        stopMoveLocationUpdates()

        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", callbackId: callbackId)
                return
            }

            if self.isCameraFollowingUser {
                self.smoothedTrackingCoordinate = coordinate
                self.runRecenterAnimation(to: CameraOptions(center: coordinate, zoom: zoom.map { CGFloat($0) }))
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
        moveLocationTimeoutWork?.cancel()
        moveLocationTimeoutWork = nil
        moveLocationManager?.stopUpdatingLocation()
        moveLocationManager?.delegate = nil
        moveLocationManager = nil
        moveLocationCallbackId = nil
        moveLocationZoom = nil
    }

}
