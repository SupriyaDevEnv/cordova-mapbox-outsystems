import Foundation
import CoreLocation
import UIKit
import MapboxMaps

/// Adds the Cordova actions that already exist on Android but were missing on iOS.
/// The base MapboxPlugin keeps the existing implementation; this subclass only
/// supplies the parity actions and delegates existing actions to the base class.
@objc(MapboxPluginParity)
class MapboxPluginParity: MapboxPlugin {
    private let mapboxSdkVersion = "11.20.2"
    private let maxLocationAge: TimeInterval = 30
    private let locationAccuracyCallbackInterval: TimeInterval = 0.5

    private var locationAccuracyCallbackId: String?
    private var accuracyLocationManager: CLLocationManager?
    private var lastLocationAccuracyUpdate: TimeInterval = 0

    @objc(getMapboxVersion:)
    func getMapboxVersion(command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(
            status: CDVCommandStatus_OK,
            messageAs: mapboxSdkVersion
        )
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    @objc(resizeMap:)
    func resizeMap(command: CDVInvokedUrlCommand) {
        // iOS setViewport already resizes/repositions both the MapView and its
        // touch overlay, so use the same path for resizeMap.
        super.setViewport(command: command)
    }

    @objc(registerLocationAccuracyCallback:)
    func registerLocationAccuracyCallback(command: CDVInvokedUrlCommand) {
        locationAccuracyCallbackId = command.callbackId
        lastLocationAccuracyUpdate = 0

        let result = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: command.callbackId)

        DispatchQueue.main.async {
            if self.accuracyLocationManager == nil {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
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
        DispatchQueue.main.async {
            guard CLLocationManager.authorizationStatus() == .authorizedWhenInUse
                    || CLLocationManager.authorizationStatus() == .authorizedAlways else {
                self.sendAccuracyResult(accuracy: -1, label: "Unknown", command: command)
                return
            }

            if self.accuracyLocationManager == nil {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyBest
                self.accuracyLocationManager = manager
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

    @objc(setLayerVisibility:)
    func setLayerVisibility(command: CDVInvokedUrlCommand) {
        DispatchQueue.main.async {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            let layerId = (options["layerId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = options["visible"] as? Bool ?? true

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
        DispatchQueue.main.async {
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
            self.commandDelegate.send(result, callbackId: command.callbackId)
        }
    }

    override func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if manager !== accuracyLocationManager {
            super.locationManager(manager, didUpdateLocations: locations)
        }

        guard let location = locations.last else {
            return
        }
        sendLocationAccuracyUpdate(location)
    }

    override func close(command: CDVInvokedUrlCommand) {
        stopAccuracyMonitoring()
        super.close(command: command)
    }

    override func onReset() {
        stopAccuracyMonitoring()
        super.onReset()
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

        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
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

    private func sendParitySuccess(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendParityError(_ message: String, command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        commandDelegate.send(result, callbackId: command.callbackId)
    }
}
