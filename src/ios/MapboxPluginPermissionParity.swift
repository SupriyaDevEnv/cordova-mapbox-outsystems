import Foundation
import CoreLocation

/// Adds a first-run location authorization flow in front of MapboxPluginParity.
/// Location-dependent Cordova actions are queued while iOS shows the native
/// permission dialog and are resumed automatically after the user grants access.
@objc(MapboxPluginPermissionParity)
class MapboxPluginPermissionParity: MapboxPluginParity {
    private enum PendingLocationAction {
        case enableUserLocation(CDVInvokedUrlCommand)
        case setDeviceHeadingEnabled(CDVInvokedUrlCommand)
        case setHeadingFollowMode(CDVInvokedUrlCommand)
        case setUserTrackingEnabled(CDVInvokedUrlCommand)
        case moveToCurrentLocation(CDVInvokedUrlCommand)
        case startPathTracking(CDVInvokedUrlCommand)
    }

    private let permissionLocationManager = CLLocationManager()
    private var pendingLocationActions: [PendingLocationAction] = []
    private var locationPermissionRequestInFlight = false

    @objc(enableUserLocation:)
    override func enableUserLocation(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.enableUserLocation(command))
    }

    @objc(setDeviceHeadingEnabled:)
    override func setDeviceHeadingEnabled(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.setDeviceHeadingEnabled(command))
    }

    @objc(setHeadingFollowMode:)
    override func setHeadingFollowMode(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.setHeadingFollowMode(command))
    }

    @objc(setUserTrackingEnabled:)
    override func setUserTrackingEnabled(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.setUserTrackingEnabled(command))
    }

    @objc(moveToCurrentLocation:)
    override func moveToCurrentLocation(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.moveToCurrentLocation(command))
    }

    @objc(startPathTracking:)
    override func startPathTracking(command: CDVInvokedUrlCommand) {
        runWhenLocationAuthorized(.startPathTracking(command))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === permissionLocationManager else {
            return
        }

        let status = manager.authorizationStatus
        if status == .notDetermined {
            return
        }

        locationPermissionRequestInFlight = false
        let actions = pendingLocationActions
        pendingLocationActions.removeAll()

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            for action in actions {
                resume(action)
            }
        } else {
            for action in actions {
                fail(action, message: "Location permission is not granted.")
            }
        }
    }

    override func closeInternal() {
        for action in pendingLocationActions {
            fail(action, message: "Location request was cancelled.")
        }
        pendingLocationActions.removeAll()
        locationPermissionRequestInFlight = false
        permissionLocationManager.delegate = nil
        super.closeInternal()
    }

    private func runWhenLocationAuthorized(_ action: PendingLocationAction) {
        runForSession {
            self.permissionLocationManager.delegate = self
            let status = self.permissionLocationManager.authorizationStatus

            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.resume(action)
                return
            }

            if status == .denied || status == .restricted {
                self.fail(action, message: "Location permission is not granted.")
                return
            }

            guard self.pendingLocationActions.count < 32 else {
                self.fail(action, message: "Too many pending location requests."); return
            }
            self.pendingLocationActions.append(action)
            if !self.locationPermissionRequestInFlight {
                self.locationPermissionRequestInFlight = true
                self.permissionLocationManager.requestWhenInUseAuthorization()
            }
        }
    }

    private func resume(_ action: PendingLocationAction) {
        switch action {
        case .enableUserLocation(let command):
            super.enableUserLocation(command: command)
        case .setDeviceHeadingEnabled(let command):
            super.setDeviceHeadingEnabled(command: command)
        case .setHeadingFollowMode(let command):
            super.setHeadingFollowMode(command: command)
        case .setUserTrackingEnabled(let command):
            super.setUserTrackingEnabled(command: command)
        case .moveToCurrentLocation(let command):
            super.moveToCurrentLocation(command: command)
        case .startPathTracking(let command):
            super.startPathTracking(command: command)
        }
    }

    private func fail(_ action: PendingLocationAction, message: String) {
        let callbackId: String
        switch action {
        case .enableUserLocation(let command),
             .setDeviceHeadingEnabled(let command),
             .setHeadingFollowMode(let command),
             .setUserTrackingEnabled(let command),
             .moveToCurrentLocation(let command),
             .startPathTracking(let command):
            callbackId = command.callbackId
        }

        let result = CDVPluginResult(
            status: CDVCommandStatus_ERROR,
            messageAs: message
        )
        commandDelegate.send(result, callbackId: callbackId)
    }
}
