import Foundation
import Security
import CoreLocation
import UIKit
import MapboxMaps
import Turf

@objc(MapboxPlugin)
class MapboxPlugin: CDVPlugin, CLLocationManagerDelegate, UIGestureRecognizerDelegate {
    private var sessionGeneration: UInt64 = 0
    func runForSession(_ work: @escaping () -> Void) {
        runForGeneration(sessionGeneration, work)
    }

    private func runForGeneration(_ generation: UInt64, _ work: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.sessionGeneration == generation else { return }
            work()
        }
    }

    private var mapView: MapView?
    private var mapTouchOverlay: MapTouchOverlayView?
    private var annotations: PointAnnotationManager?
    private var markers: [String: PointAnnotation] = [:]
    private var boundaryAnnotationManager: PolygonAnnotationManager?
    private var boundaryAnnotations: [PolygonAnnotation] = []
    private var lineAnnotationManager: PolylineAnnotationManager?
    private var pathAnnotation: PolylineAnnotation?
    private var pathPoints: [CLLocationCoordinate2D] = []
    private var isPathTrackingActive = false
    private var pathTrackingStartTime: TimeInterval = 0
    private var isPathVisible = true
    private var pathLineColor: String = "#FF0000"
    private var pathLineWidth: Double = 3.0
    private var pathLineOpacity: Double = 1.0
    private var waypointSelectedCallbackId: String?
    private var markerClickCallbackId: String?
    private var offlineDownloadProgressCallbackId: String?
    private var activeStylePackDownload: Cancelable?
    private var activeTileRegionDownload: Cancelable?
    private var isOfflineDownloading = false
    private var waypointSelectionEnabled = false
    private var autoAddWaypointMarker = false
    private var cancelables = Set<AnyCancelable>()
    private var headingLocationManager: CLLocationManager?
    private var moveToCurrentLocationCallbackId: String?
    private var moveToCurrentLocationZoom: Double?
    private var lastHeadingBearing: CLLocationDirection = -1
    private var lastHeadingUpdate: TimeInterval = 0
    private var isUserTrackingEnabled = false
    private var isUserLocationEnabled = false
    private var isDeviceHeadingEnabled = false
    private var isHeadingFollowModeEnabled = false
    private var trackingStatusCallbackId: String?
    private var lastUserTrackingUpdate: TimeInterval = 0
    private var lastKeepCallbackOfflineTs: TimeInterval = 0
    private var lastKeepCallbackWaypointTs: TimeInterval = 0
    private var lastKeepCallbackMarkerTs: TimeInterval = 0
    private let callbackRateLimit: TimeInterval = 0.1
    private let maxMarkers = 10000
    private let maxBoundaries = 1000
    private let maxOfflineRadiusKm: Double = 50.0
    private let minOfflineZoom: UInt8 = 2
    private let maxOfflineZoom: UInt8 = 18
    private var boundaryVisible = true

    @objc(ping:)
    func ping(command: CDVInvokedUrlCommand) {
        sendSuccess([
            "status": "ok",
            "service": "MapboxPlugin",
            "class": "MapboxPlugin"
        ], command)
    }

    @objc(initialize:)
    func initialize(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let options = command.argument(at: 0) as? [String: Any] else {
                self.sendError("Options are required.", command)
                return
            }

            guard self.validInput(options, command) else { return }
            let token = self.getAccessToken()

            guard !token.isEmpty else {
                self.sendError("A public pk.* Mapbox token is required. Configure MAPBOX_ACCESS_TOKEN in OutSystems Extensibility Configuration.", command)
                return
            }

            let latitude = self.doubleOption(options["latitude"], defaultValue: 0)
            let longitude = self.doubleOption(options["longitude"], defaultValue: 0)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let zoom = self.doubleOption(options["zoom"], defaultValue: 12)
            let bearing = self.doubleOption(options["bearing"], defaultValue: 0)
            let pitch = self.doubleOption(options["pitch"], defaultValue: 0)
            let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
                return
            }
            let behindWebView = options["behindWebView"] as? Bool ?? false

            self.closeInternal()

            MapboxOptions.accessToken = token

            let camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom,
                bearing: bearing,
                pitch: pitch
            )

            let styleURI = StyleURI(rawValue: styleUrl) ?? .streets
            let initOptions = MapInitOptions(cameraOptions: camera, styleURI: styleURI)

            let isInline = options["inline"] as? Bool ?? false
            let mapView = MapView(
                frame: isInline ? self.frameFromOptions(options) : self.webView.bounds,
                mapInitOptions: initOptions
            )
            mapView.autoresizingMask = isInline ? [] : [.flexibleWidth, .flexibleHeight]

            if behindWebView, let superview = self.webView.superview {
                self.makeWebViewTransparent()
                superview.insertSubview(mapView, belowSubview: self.webView)
                self.installMapTouchOverlay(in: superview, frame: mapView.frame)
            } else {
                self.webView.superview?.addSubview(mapView)
            }

            self.mapView = mapView
            self.annotations = mapView.annotations.makePointAnnotationManager()
            self.installMapTapHandler(on: mapView)

            if !isInline {
                let closeButton = UIButton(type: .system)
                closeButton.setTitle("Close", for: .normal)
                closeButton.backgroundColor = UIColor.white
                closeButton.layer.cornerRadius = 6
                closeButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
                closeButton.addTarget(self, action: #selector(self.closeFromButton), for: .touchUpInside)
                closeButton.translatesAutoresizingMaskIntoConstraints = false
                mapView.addSubview(closeButton)

                NSLayoutConstraint.activate([
                    closeButton.topAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 12),
                    closeButton.trailingAnchor.constraint(equalTo: mapView.trailingAnchor, constant: -16)
                ])
            }

            self.sendSuccess(["status": "initialized"], command)
        }
    }

    @objc(setCamera:)
    func setCamera(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let latitude = self.doubleOption(options["latitude"], defaultValue: mapView.cameraState.center.latitude)
            let longitude = self.doubleOption(options["longitude"], defaultValue: mapView.cameraState.center.longitude)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let zoom = self.doubleOption(options["zoom"], defaultValue: mapView.cameraState.zoom)
            let bearing = self.doubleOption(options["bearing"], defaultValue: mapView.cameraState.bearing)
            let pitch = self.doubleOption(options["pitch"], defaultValue: mapView.cameraState.pitch)

            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom,
                bearing: bearing,
                pitch: pitch
            ))

            self.sendSuccess(command)
        }
    }

    @objc(flyTo:)
    func flyTo(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let latitude = self.doubleOption(options["latitude"], defaultValue: mapView.cameraState.center.latitude)
            let longitude = self.doubleOption(options["longitude"], defaultValue: mapView.cameraState.center.longitude)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let zoom = self.doubleOption(options["zoom"], defaultValue: mapView.cameraState.zoom)
            let bearing = self.doubleOption(options["bearing"], defaultValue: mapView.cameraState.bearing)
            let pitch = self.doubleOption(options["pitch"], defaultValue: mapView.cameraState.pitch)

            let camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom,
                bearing: bearing,
                pitch: pitch
            )

            let duration = (options["duration"] as? Double).map { $0 / 1000.0 }
            mapView.camera.fly(to: camera, duration: duration)

            self.sendSuccess(command)
        }
    }

    @objc(setViewport:)
    func setViewport(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            mapView.frame = self.frameFromOptions(options)
            self.mapTouchOverlay?.frame = mapView.frame
            self.sendSuccess(command)
        }
    }

    @objc(setTouchableRects:)
    func setTouchableRects(command: CDVInvokedUrlCommand) {
        runForSession {
            let rects = command.argument(at: 0) as? [[String: Any]] ?? []

            let maxRects = 20
            guard rects.count <= maxRects else {
                self.sendError("Too many touchable rects. Maximum is \(maxRects).", command)
                return
            }

            let mapFrame = self.mapView?.frame ?? .zero
            self.mapTouchOverlay?.touchableRects = rects.compactMap {
                self.touchRectFromOptions($0, mapViewFrame: mapFrame)
            }
            self.sendSuccess(command)
        }
    }

    @objc(enableUserLocation:)
    func enableUserLocation(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            self.requestLocationAuthorizationIfNeeded()
            mapView.location.options.puckType = .puck2D()
            mapView.location.options.puckBearingEnabled = true
            self.isUserLocationEnabled = true
            self.fireTrackingStatusChanged()
            self.sendSuccess(command)
        }
    }

    @objc(setDeviceHeadingEnabled:)
    func setDeviceHeadingEnabled(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let enabled = options["enabled"] as? Bool ?? true

            if enabled {
                mapView.location.options.puckType = .puck2D(.makeDefault(showBearing: true))
                mapView.location.options.puckBearing = .heading
            }

            mapView.location.options.puckBearingEnabled = enabled
            self.isDeviceHeadingEnabled = enabled
            self.fireTrackingStatusChanged()
            self.sendSuccess(command)
        }
    }

    @objc(setHeadingFollowMode:)
    func setHeadingFollowMode(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let enabled = options["enabled"] as? Bool ?? true

            if !enabled {
                self.stopHeadingFollowMode()
                self.sendSuccess(command)
                return
            }

            mapView.location.options.puckType = .puck2D(.makeDefault(showBearing: true))
            mapView.location.options.puckBearing = .heading
            mapView.location.options.puckBearingEnabled = true

            self.startHeadingFollowMode(command)
        }
    }

    @objc(setUserTrackingEnabled:)
    func setUserTrackingEnabled(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let enabled = options["enabled"] as? Bool ?? true

            if !enabled {
                self.stopUserTracking()
                self.sendSuccess(command)
                return
            }

            self.startUserTracking(command)
        }
    }

    @objc(moveToCurrentLocation:)
    func moveToCurrentLocation(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            self.moveToCurrentLocationZoom = options["zoom"] == nil
                ? nil
                : self.doubleOption(options["zoom"], defaultValue: 0)

            self.requestLocationAuthorizationIfNeeded()
            self.moveToCurrentLocationCallbackId = command.callbackId
            self.headingLocationManager?.startUpdatingLocation()
        }
    }

    private func startHeadingFollowMode(_ command: CDVInvokedUrlCommand) {
        guard CLLocationManager.headingAvailable() else {
            sendError("Device heading sensor is not available.", command)
            return
        }

        if headingLocationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.headingFilter = 1
            headingLocationManager = manager
        }

        if CLLocationManager.authorizationStatus() == .notDetermined {
            headingLocationManager?.requestWhenInUseAuthorization()
        }

        headingLocationManager?.startUpdatingHeading()
        isHeadingFollowModeEnabled = true
        fireTrackingStatusChanged()
        sendSuccess(command)
    }

    private func startUserTracking(_ command: CDVInvokedUrlCommand) {
        if headingLocationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.headingFilter = 1
            manager.desiredAccuracy = kCLLocationAccuracyBest
            headingLocationManager = manager
        }

        if CLLocationManager.authorizationStatus() == .notDetermined {
            headingLocationManager?.requestWhenInUseAuthorization()
        }

        isUserTrackingEnabled = true
        fireTrackingStatusChanged()
        headingLocationManager?.startUpdatingLocation()
        sendSuccess(command)
    }

    private func stopUserTracking() {
        isUserTrackingEnabled = false
        fireTrackingStatusChanged()
        if moveToCurrentLocationCallbackId == nil {
            headingLocationManager?.stopUpdatingLocation()
        }
        lastUserTrackingUpdate = 0
    }

    private func stopHeadingFollowMode() {
        headingLocationManager?.stopUpdatingHeading()
        lastHeadingBearing = -1
        lastHeadingUpdate = 0
        isHeadingFollowModeEnabled = false
        fireTrackingStatusChanged()
    }

    private func requestLocationAuthorizationIfNeeded() {
        if headingLocationManager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            manager.headingFilter = 1
            manager.desiredAccuracy = kCLLocationAccuracyBest
            headingLocationManager = manager
        }

        if CLLocationManager.authorizationStatus() == .notDetermined {
            headingLocationManager?.requestWhenInUseAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard manager === headingLocationManager else { return }
        var bearing = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard bearing >= 0 else {
            return
        }

        let now = Date().timeIntervalSince1970
        if now - lastHeadingUpdate < 0.08 {
            return
        }

        if lastHeadingBearing >= 0 {
            var diff = abs(bearing - lastHeadingBearing)
            diff = min(diff, 360.0 - diff)

            if diff < 1.5 {
                return
            }

            bearing = lastHeadingBearing + shortestBearingDelta(from: lastHeadingBearing, to: bearing) * 0.25
            if bearing < 0 {
                bearing += 360.0
            } else if bearing >= 360.0 {
                bearing -= 360.0
            }
        }

        lastHeadingBearing = bearing
        lastHeadingUpdate = now

        runForSession {
            self.mapView?.mapboxMap.setCamera(to: CameraOptions(bearing: bearing))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === headingLocationManager else { return }
        guard let location = locations.last else {
            return
        }

        if let callbackId = moveToCurrentLocationCallbackId {
            moveToCurrentLocationCallbackId = nil

            let coordinate = location.coordinate
            var camera = CameraOptions(center: coordinate)
            if let zoom = moveToCurrentLocationZoom {
                camera = CameraOptions(center: coordinate, zoom: zoom)
            }
            moveToCurrentLocationZoom = nil

            runForSession {
                self.mapView?.mapboxMap.setCamera(to: camera)
                if !self.isUserTrackingEnabled {
                    manager.stopUpdatingLocation()
                }

                self.sendSuccess([
                    "latitude": coordinate.latitude,
                    "longitude": coordinate.longitude
                ], callbackId: callbackId)
            }
            return
        }

        guard isUserTrackingEnabled else {
            return
        }

        let now = Date().timeIntervalSince1970
        if now - lastUserTrackingUpdate < 0.5 {
            return
        }

        lastUserTrackingUpdate = now
        let coordinate = location.coordinate

        runForSession {
            self.mapView?.mapboxMap.setCamera(to: CameraOptions(center: coordinate))

            if self.isPathTrackingActive {
                guard self.pathPoints.count < MapboxSecurity.maxPoints else {
                    self.stopUserTracking()
                    return // Keep the recording available to stopPathTracking().
                }
                self.pathPoints.append(coordinate)
                self.updatePathAnnotation()
            }
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let callbackId = moveToCurrentLocationCallbackId else {
            return
        }

        moveToCurrentLocationCallbackId = nil
        moveToCurrentLocationZoom = nil

        if !isUserTrackingEnabled {
            manager.stopUpdatingLocation()
        }

        sendError(sanitizeError(contextMessage: "Failed to get current location.", error: error), callbackId: callbackId)
    }

    private func shortestBearingDelta(from: CLLocationDirection, to: CLLocationDirection) -> CLLocationDirection {
        return (to - from + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
    }

    @objc(addMarker:)
    func addMarker(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }

            let id: String
            if let rawId = options["id"] {
                guard let idStr = rawId as? String else {
                    self.sendError("Invalid id: must be a string.", command)
                    return
                }
                guard !idStr.isEmpty else {
                    self.sendError("Invalid id: must not be empty.", command)
                    return
                }
                id = idStr
            } else {
                id = String(Int(Date().timeIntervalSince1970 * 1000))
            }

            let latitude = self.doubleOption(options["latitude"], defaultValue: 0)
            let longitude = self.doubleOption(options["longitude"], defaultValue: 0)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            guard self.markers[id] != nil || self.markers.count < self.maxMarkers,
                  id.utf8.count <= 256 else { self.sendError("Marker/id limit exceeded.", command); return }
            self.addMarkerInternal(id: id, latitude: latitude, longitude: longitude)
            self.sendSuccess(["id": id], command)
        }
    }

    @objc(loadMarkers:)
    func loadMarkers(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let replace = options["replace"] as? Bool ?? true
            let markers = options["markers"] as? [[String: Any]] ?? []
            var ids = replace ? Set<String>() : Set(self.markers.keys)
            for (index, marker) in markers.enumerated() {
                let id = marker["id"] as? String ?? String(index)
                guard !id.isEmpty, id.utf8.count <= 256 else { self.sendError("Invalid marker id.", command); return }
                ids.insert(id)
            }
            guard markers.count <= self.maxMarkers, ids.count <= self.maxMarkers else {
                self.sendError("Too many markers: maximum total is \(self.maxMarkers).", command); return
            }
            if replace { self.clearMarkersInternal() }
            for (index, marker) in markers.enumerated() {
                let id = marker["id"] as? String ?? String(index)
                let latitude = self.doubleOption(marker["latitude"], defaultValue: 0)
                let longitude = self.doubleOption(marker["longitude"], defaultValue: 0)
                guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                    continue
                }
                self.addMarkerInternal(id: id, latitude: latitude, longitude: longitude, publish: false)
            }
            self.annotations?.annotations = Array(self.markers.values)

            self.sendSuccess(command)
        }
    }

    @objc(removeMarker:)
    func removeMarker(command: CDVInvokedUrlCommand) {
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let id = options["id"] as? String ?? ""
            self.markers.removeValue(forKey: id)
            self.annotations?.annotations = Array(self.markers.values)
            self.sendSuccess(command)
        }
    }

    @objc(clearMarkers:)
    func clearMarkers(command: CDVInvokedUrlCommand) {
        runForSession {
            self.clearMarkersInternal()
            self.sendSuccess(command)
        }
    }

    @objc(loadBoundaries:)
    func loadBoundaries(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let boundaries = options["boundaries"] as? [[String: Any]] ?? []
            guard boundaries.count <= self.maxBoundaries else {
                self.sendError("Too many boundaries: maximum allowed is \(self.maxBoundaries).", command)
                return
            }
            var vertices = 0
            for boundary in boundaries {
                vertices += (boundary["geometry"] as? [Any])?.count ?? 0
                guard vertices <= MapboxSecurity.maxPoints else { self.sendError("Too many boundary vertices.", command); return }
            }
            self.boundaryVisible = options["visible"] as? Bool ?? true
            self.boundaryAnnotations = self.boundaryAnnotationsFromOptions(options, boundaries: boundaries)
            self.applyBoundaryVisibility()
            self.sendSuccess(["count": self.boundaryAnnotations.count], command)
        }
    }

    @objc(setBoundaryVisibility:)
    func setBoundaryVisibility(command: CDVInvokedUrlCommand) {
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            self.boundaryVisible = options["visible"] as? Bool ?? true
            self.applyBoundaryVisibility()
            self.sendSuccess(command)
        }
    }

    @objc(clearBoundaries:)
    func clearBoundaries(command: CDVInvokedUrlCommand) {
        runForSession {
            self.clearBoundariesInternal()
            self.sendSuccess(command)
        }
    }

    // --- Path Tracking Methods ---

    private func ensureLineAnnotationManager() -> Bool {
        guard let mapView = mapView else { return false }
        if lineAnnotationManager != nil { return true }
        lineAnnotationManager = mapView.annotations.makePolylineAnnotationManager()
        return lineAnnotationManager != nil
    }

    private func updatePathAnnotation() {
        guard pathPoints.count >= 2, ensureLineAnnotationManager() else { return }

        if pathAnnotation != nil {
            lineAnnotationManager?.annotations.removeAll()
            pathAnnotation = nil
        }

        guard isPathVisible else { return }

        var annotation = PolylineAnnotation(lineCoordinates: pathPoints)
        annotation.lineColor = StyleColor(colorOption(pathLineColor, defaultColor: .red))
        annotation.lineWidth = pathLineWidth
        annotation.lineOpacity = pathLineOpacity
        pathAnnotation = annotation
        lineAnnotationManager?.annotations.append(annotation)
    }

    @objc(startPathTracking:)
    func startPathTracking(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            if self.isPathTrackingActive {
                self.sendError("Path tracking is already active. Call stopPathTracking first.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            self.isPathTrackingActive = true
            self.isPathVisible = true
            self.pathTrackingStartTime = Date().timeIntervalSince1970
            self.pathPoints.removeAll()
            self.pathAnnotation = nil

            self.pathLineColor = options["lineColor"] as? String ?? "#FF0000"
            self.pathLineWidth = options["lineWidth"] as? Double ?? 3.0
            self.pathLineOpacity = options["lineOpacity"] as? Double ?? 1.0

            let trackCamera = options["trackCamera"] as? String ?? "true"
            if trackCamera == "true" {
                self.startUserTracking(command)
            } else {
                self.sendSuccess(["status": "started"], command)
            }
        }
    }

    @objc(stopPathTracking:)
    func stopPathTracking(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.isPathTrackingActive else {
                self.sendError("Path tracking is not active.", command)
                return
            }

            self.isPathTrackingActive = false
            let duration = Date().timeIntervalSince1970 - self.pathTrackingStartTime

            var totalDistance: Double = 0
            for (previous, current) in zip(self.pathPoints, self.pathPoints.dropFirst()) {
                let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                let to = CLLocation(latitude: current.latitude, longitude: current.longitude)
                totalDistance += from.distance(from: to)
            }

            let pointsArray: [[String: Double]] = self.pathPoints.map { ["lat": $0.latitude, "lon": $0.longitude] }
            self.sendSuccess([
                "points": pointsArray,
                "distance": (totalDistance * 100).rounded() / 100,
                "duration": (duration * 1000).rounded()
            ], command)
        }
    }

    @objc(loadPath:)
    func loadPath(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            if self.isPathTrackingActive {
                self.sendError("Cannot load a path while path tracking is active. Stop tracking first.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            guard let pointsArray = options["points"] as? [[String: Any]], pointsArray.count >= 2, pointsArray.count <= MapboxSecurity.maxPoints else {
                self.sendError("A path requires between 2 and 20000 points.", command)
                return
            }

            let lineColorHex = options["lineColor"] as? String ?? "#FF0000"
            let lineWidth = options["lineWidth"] as? Double ?? 3.0
            let lineOpacity = options["lineOpacity"] as? Double ?? 1.0

            self.pathLineColor = lineColorHex
            self.pathLineWidth = lineWidth
            self.pathLineOpacity = lineOpacity
            self.isPathVisible = true

            self.pathPoints.removeAll()
            for pointDict in pointsArray {
                let lat = self.doubleOption(pointDict["lat"] ?? pointDict["latitude"], defaultValue: Double.nan)
                let lon = self.doubleOption(pointDict["lon"] ?? pointDict["lng"] ?? pointDict["longitude"], defaultValue: Double.nan)
                guard lat.isFinite, lon.isFinite, self.isValidLatitude(lat), self.isValidLongitude(lon) else { continue }
                self.pathPoints.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }

            guard self.pathPoints.count >= 2 else {
                self.sendError("A path requires at least 2 valid points.", command)
                return
            }

            guard self.ensureLineAnnotationManager() else {
                self.sendError("Polyline annotation manager is not available.", command)
                return
            }

            if self.pathAnnotation != nil {
                self.lineAnnotationManager?.annotations.removeAll()
                self.pathAnnotation = nil
            }

            var annotation = PolylineAnnotation(lineCoordinates: self.pathPoints)
            annotation.lineColor = StyleColor(self.colorOption(self.pathLineColor, defaultColor: .red))
            annotation.lineWidth = self.pathLineWidth
            annotation.lineOpacity = self.pathLineOpacity
            self.pathAnnotation = annotation
            self.lineAnnotationManager?.annotations.append(annotation)

            self.sendSuccess([
                "status": "loaded",
                "pointCount": self.pathPoints.count
            ], command)
        }
    }

    @objc(clearPaths:)
    func clearPaths(command: CDVInvokedUrlCommand) {
        runForSession {
            if self.pathAnnotation != nil {
                self.lineAnnotationManager?.annotations.removeAll()
                self.pathAnnotation = nil
            }
            self.pathPoints.removeAll()
            self.sendSuccess(command)
        }
    }

    @objc(setPathVisibility:)
    func setPathVisibility(command: CDVInvokedUrlCommand) {
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let visible = options["visible"] as? Bool ?? true

            guard !self.pathPoints.isEmpty else {
                self.sendError("No path is loaded. Use loadPath or startPathTracking first.", command)
                return
            }

            self.isPathVisible = visible

            if visible {
                if self.pathAnnotation == nil {
                    self.updatePathAnnotation()
                }
            } else {
                if self.pathAnnotation != nil {
                    self.lineAnnotationManager?.annotations.removeAll()
                    self.pathAnnotation = nil
                }
            }

            self.sendSuccess(command)
        }
    }

    @objc(downloadOfflineRegion:)
    func downloadOfflineRegion(command: CDVInvokedUrlCommand) {
        sendOfflineProgress(phase: "started", completed: 0, required: 100)
        runForSession {
            self.sendOfflineProgress(phase: "native-entered", completed: 0, required: 100)

            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let latitude = self.doubleOption(options["latitude"], defaultValue: 0)
            let longitude = self.doubleOption(options["longitude"], defaultValue: 0)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let radiusKm = self.doubleOption(options["radiusKm"], defaultValue: 10)
            guard let minZoom = MapboxSecurity.zoom(self.doubleOption(options["minZoom"], defaultValue: 10)),
                  let maxZoom = MapboxSecurity.zoom(self.doubleOption(options["maxZoom"], defaultValue: 16)), minZoom <= maxZoom else {
                self.sendError("Offline zoom must be between 2 and 18 with minZoom <= maxZoom.", command); return
            }
            let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
                return
            }
            let regionId = options["regionId"] as? String
                ?? "offline-\(Int(latitude * 100000))-\(Int(longitude * 100000))"

            guard let styleURI = StyleURI(rawValue: styleUrl) else {
                self.sendError("Invalid styleUrl.", command)
                return
            }

            self.startOfflineDownload(
                regionId: regionId,
                latitude: latitude,
                longitude: longitude,
                radiusKm: radiusKm,
                minZoom: minZoom,
                maxZoom: maxZoom,
                styleURI: styleURI,
                geometry: nil,
                command: command
            )
        }
    }

    @objc(downloadOfflineRegionForRect:)
    func downloadOfflineRegionForRect(command: CDVInvokedUrlCommand) {
        sendOfflineProgress(phase: "started", completed: 0, required: 100)
        runForSession {
            self.sendOfflineProgress(phase: "native-entered", completed: 0, required: 100)

            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let x = self.doubleOption(options["x"], defaultValue: 0)
            let y = self.doubleOption(options["y"], defaultValue: 0)
            let width = self.doubleOption(options["width"], defaultValue: 1)
            let height = self.doubleOption(options["height"], defaultValue: 1)
            guard [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1000000 }), width > 0, height > 0 else {
                self.sendError("Invalid offline rectangle.", command); return
            }
            guard let minZoom = MapboxSecurity.zoom(self.doubleOption(options["minZoom"], defaultValue: 10)),
                  let maxZoom = MapboxSecurity.zoom(self.doubleOption(options["maxZoom"], defaultValue: 16)), minZoom <= maxZoom else {
                self.sendError("Offline zoom must be between 2 and 18 with minZoom <= maxZoom.", command); return
            }
            let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
                return
            }
            let regionId = options["regionId"] as? String ?? "offline-rect-\(Int(Date().timeIntervalSince1970 * 1000))"

            guard let styleURI = StyleURI(rawValue: styleUrl) else {
                self.sendError("Invalid styleUrl.", command)
                return
            }

            let topLeft = mapView.mapboxMap.coordinate(for: CGPoint(x: x, y: y))
            let topRight = mapView.mapboxMap.coordinate(for: CGPoint(x: x + width, y: y))
            let bottomRight = mapView.mapboxMap.coordinate(for: CGPoint(x: x + width, y: y + height))
            let bottomLeft = mapView.mapboxMap.coordinate(for: CGPoint(x: x, y: y + height))
            let center = mapView.mapboxMap.coordinate(for: CGPoint(x: x + width / 2, y: y + height / 2))

            let polygon = Polygon([[
                topLeft,
                topRight,
                bottomRight,
                bottomLeft,
                topLeft
            ]])

            self.startOfflineDownload(
                regionId: regionId,
                latitude: center.latitude,
                longitude: center.longitude,
                radiusKm: 0,
                minZoom: minZoom,
                maxZoom: maxZoom,
                styleURI: styleURI,
                geometry: polygon.geometry,
                command: command
            )
        }
    }

    private func startOfflineDownload(
        regionId: String,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minZoom: UInt8,
        maxZoom: UInt8,
        styleURI: StyleURI,
        geometry: Geometry?,
        command: CDVInvokedUrlCommand
    ) {
        guard !isOfflineDownloading else {
            sendError("An offline region download is already in progress.", command)
            return
        }
        guard radiusKm.isFinite, radiusKm >= 0, radiusKm <= maxOfflineRadiusKm,
              !regionId.isEmpty, regionId.utf8.count <= 256 else {
            sendError("Invalid offline radius or region id.", command); return
        }
        let downloadGeneration = sessionGeneration
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let polygon = Polygon(center: center, radius: radiusKm * 1000, vertices: 64)
        let regionGeometry = geometry ?? polygon.geometry
        guard case .polygon(let regionPolygon) = regionGeometry else {
            sendError("Offline geometry must be a polygon.", command); return
        }
        let coordinates = regionPolygon.coordinates.flatMap { $0 }
        guard let south = coordinates.map({ $0.latitude }).min(),
              let north = coordinates.map({ $0.latitude }).max(),
              let west = coordinates.map({ $0.longitude }).min(),
              let east = coordinates.map({ $0.longitude }).max(),
              MapboxSecurity.offlineBounds(south: south, west: west, north: north, east: east, zoom: Double(maxZoom)) else {
            sendError("Offline region exceeds the geographic or 50000-tile budget.", command); return
        }
        let boundedRadiusKm = max(0, min(radiusKm, maxOfflineRadiusKm))
        let boundedMinZoom = max(minOfflineZoom, min(minZoom, maxOfflineZoom))
        let boundedMaxZoom = max(boundedMinZoom, min(maxZoom, maxOfflineZoom))
        isOfflineDownloading = true
        cancelCurrentDownload()
        let offlineManager = OfflineManager()
        sendOfflineProgress(phase: "style-start", completed: 0, required: 100)

        guard let stylePackOptions = StylePackLoadOptions(
            glyphsRasterizationMode: .ideographsRasterizedLocally,
            metadata: ["regionId": regionId],
            acceptExpired: false
        ) else {
            isOfflineDownloading = false
            sendError("Failed to create style pack options.", command)
            return
        }

        activeStylePackDownload = offlineManager.loadStylePack(
            for: styleURI,
            loadOptions: stylePackOptions
        ) { progress in
            self.runForGeneration(downloadGeneration) {
                self.sendOfflineProgress(
                    phase: "style",
                    completed: UInt64(progress.completedResourceCount),
                    required: UInt64(progress.requiredResourceCount)
                )
            }
        } completion: { result in
            self.runForGeneration(downloadGeneration) {
                switch result {
                case .success:
                    self.sendOfflineProgress(phase: "tiles-start", completed: 0, required: 100)
                    self.downloadOfflineTiles(
                        offlineManager: offlineManager,
                        downloadGeneration: downloadGeneration,
                        regionId: regionId,
                        latitude: latitude,
                        longitude: longitude,
                        radiusKm: boundedRadiusKm,
                        minZoom: boundedMinZoom,
                        maxZoom: boundedMaxZoom,
                        styleURI: styleURI,
                        geometry: geometry,
                        command: command
                    )
                case .failure(let error):
                    self.isOfflineDownloading = false
                    self.sendError(self.sanitizeError(contextMessage: "Failed to download style pack.", error: error), command)
                }
            }
        }
    }

    private func downloadOfflineTiles(
        offlineManager: OfflineManager,
        downloadGeneration: UInt64,
        regionId: String,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minZoom: UInt8,
        maxZoom: UInt8,
        styleURI: StyleURI,
        geometry: Geometry? = nil,
        command: CDVInvokedUrlCommand
    ) {
        guard downloadGeneration == sessionGeneration else { return }
        let descriptorOptions = TilesetDescriptorOptions(
            styleURI: styleURI,
            zoomRange: minZoom...maxZoom,
            tilesets: nil
        )
        let descriptor = offlineManager.createTilesetDescriptor(for: descriptorOptions)
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let polygon = Polygon(center: center, radius: radiusKm * 1000.0, vertices: 64)

        guard let loadOptions = TileRegionLoadOptions(
            geometry: geometry ?? polygon.geometry,
            descriptors: [descriptor],
            metadata: ["regionId": regionId],
            acceptExpired: false
        ) else {
            isOfflineDownloading = false
            sendError("Failed to create tile region options.", command)
            return
        }

        activeTileRegionDownload = TileStore.default.loadTileRegion(
            forId: regionId,
            loadOptions: loadOptions
        ) { progress in
            self.runForGeneration(downloadGeneration) {
                self.sendOfflineProgress(
                    phase: "tiles",
                    completed: UInt64(progress.completedResourceCount),
                    required: UInt64(progress.requiredResourceCount)
                )
            }
        } completion: { result in
            self.runForGeneration(downloadGeneration) {
                self.isOfflineDownloading = false
                switch result {
                case .success:
                    self.sendSuccess([
                        "regionId": regionId,
                        "latitude": latitude,
                        "longitude": longitude,
                        "radiusKm": radiusKm
                    ], command)
                case .failure(let error):
                    self.sendError(self.sanitizeError(contextMessage: "Failed to download tile region.", error: error), command)
                }
            }
        }
    }

    @objc(showOfflineRegion:)
    func showOfflineRegion(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let latitude = self.doubleOption(options["latitude"], defaultValue: 0)
            let longitude = self.doubleOption(options["longitude"], defaultValue: 0)

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let zoom = self.doubleOption(options["zoom"], defaultValue: 13)
            let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
                return
            }
            let styleURI = StyleURI(rawValue: styleUrl) ?? .streets

            mapView.mapboxMap.loadStyle(styleURI)
            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom
            ))
            self.sendSuccess(command)
        }
    }

    @objc(deleteOfflineRegion:)
    func deleteOfflineRegion(command: CDVInvokedUrlCommand) {
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        guard self.validInput(options, command) else { return }
        let regionId = options["regionId"] as? String ?? ""
        let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
        guard self.styleAllowed(styleUrl) else {
            self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
            return
        }
        let deleteStylePack = options["deleteStylePack"] as? Bool ?? true

        guard !regionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError("regionId is required.", command)
            return
        }

        TileStore.default.removeTileRegion(forId: regionId)

        if deleteStylePack, let styleURI = StyleURI(rawValue: styleUrl) {
            OfflineManager().removeStylePack(for: styleURI)
        }

        sendSuccess(command)
    }

    @objc(setWaypointSelectionEnabled:)
    func setWaypointSelectionEnabled(command: CDVInvokedUrlCommand) {
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        guard self.validInput(options, command) else { return }
        waypointSelectionEnabled = options["enabled"] as? Bool ?? true
        autoAddWaypointMarker = options["autoAddMarker"] as? Bool ?? false
        sendSuccess(command)
    }

    @objc(registerWaypointSelectedCallback:)
    func registerWaypointSelectedCallback(command: CDVInvokedUrlCommand) {
        waypointSelectedCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerMarkerClickCallback:)
    func registerMarkerClickCallback(command: CDVInvokedUrlCommand) {
        markerClickCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerOfflineDownloadProgressCallback:)
    func registerOfflineDownloadProgressCallback(command: CDVInvokedUrlCommand) {
        offlineDownloadProgressCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerTrackingStatusCallback:)
    func registerTrackingStatusCallback(command: CDVInvokedUrlCommand) {
        trackingStatusCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
        fireTrackingStatusChanged()
    }

    private func fireTrackingStatusChanged() {
        sendKeepCallback(trackingStatusCallbackId, payload: [
            "userLocation": isUserLocationEnabled,
            "userTracking": isUserTrackingEnabled,
            "deviceHeading": isDeviceHeadingEnabled,
            "headingFollowMode": isHeadingFollowModeEnabled
        ])
    }

    private func sendOfflineProgress(phase: String, completed: UInt64, required: UInt64) {
        let percent = required > 0 ? Int(round((Double(completed) * 100.0) / Double(required))) : 0
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackOfflineTs >= callbackRateLimit else { return }
        lastKeepCallbackOfflineTs = now
        sendKeepCallback(offlineDownloadProgressCallbackId, payload: [
            "type": "offlineDownloadProgress",
            "phase": phase,
            "completed": completed,
            "required": required,
            "percent": percent
        ])
    }

    private func installMapTapHandler(on mapView: MapView) {
        cancelables.removeAll()
        mapView.gestures.onMapTap.observe { [weak self] context in
            guard let self = self else {
                return
            }

            if self.sendMarkerClickIfNear(context.coordinate) {
                return
            }

            guard self.waypointSelectionEnabled else {
                return
            }

            var id = ""
            if self.autoAddWaypointMarker {
                id = String(Int(Date().timeIntervalSince1970 * 1000))
                self.addMarkerInternal(
                    id: id,
                    latitude: context.coordinate.latitude,
                    longitude: context.coordinate.longitude
                )
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastKeepCallbackWaypointTs >= self.callbackRateLimit else { return }
            self.lastKeepCallbackWaypointTs = now
            self.sendKeepCallback(self.waypointSelectedCallbackId, payload: [
                "type": "waypointSelected",
                "id": id,
                "latitude": context.coordinate.latitude,
                "longitude": context.coordinate.longitude
            ])
        }.store(in: &cancelables)
    }

    private func addMarkerInternal(id: String, latitude: Double, longitude: Double, publish: Bool = true) {
        guard !id.isEmpty, id.utf8.count <= 256,
              markers[id] != nil || markers.count < maxMarkers else { return }
        guard var manager = annotations else {
            return
        }

        var marker = PointAnnotation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
        marker.image = .init(image: createWaypointMarkerImage(), name: "waypoint-marker")
        marker.iconAnchor = .bottom
        marker.tapHandler = { [weak self, id] context in
            guard let self = self else { return true }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastKeepCallbackMarkerTs >= self.callbackRateLimit else { return true }
            self.lastKeepCallbackMarkerTs = now
            self.sendKeepCallback(self.markerClickCallbackId, payload: [
                "type": "markerClicked",
                "id": id,
                "latitude": context.coordinate.latitude,
                "longitude": context.coordinate.longitude
            ])
            return true
        }

        markers[id] = marker
        if publish { manager.annotations = Array(markers.values) }
        annotations = manager
    }

    private func clearMarkersInternal() {
        markers.removeAll()
        annotations?.annotations = []
    }

    private func boundaryAnnotationsFromOptions(_ options: [String: Any], boundaries: [[String: Any]]) -> [PolygonAnnotation] {
        let fillColor = colorOption(options["fillColor"], defaultColor: UIColor(red: 46 / 255, green: 125 / 255, blue: 50 / 255, alpha: 1))
        let fillOpacity = doubleOption(options["fillOpacity"], defaultValue: 0.18)
        let outlineColor = colorOption(options["lineColor"], defaultColor: UIColor(red: 27 / 255, green: 94 / 255, blue: 32 / 255, alpha: 1))

        return boundaries.compactMap { boundary in
            guard let geometry = boundary["geometry"] as? [[String: Any]] else {
                return nil
            }

            var ring = geometry.compactMap { point -> CLLocationCoordinate2D? in
                let latitude = doubleOption(point["lat"] ?? point["latitude"], defaultValue: Double.nan)
                let longitude = doubleOption(point["lon"] ?? point["lng"] ?? point["longitude"], defaultValue: Double.nan)
                guard latitude.isFinite, longitude.isFinite,
                      isValidLatitude(latitude), isValidLongitude(longitude) else {
                    return nil
                }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }

            guard ring.count >= 3 else {
                return nil
            }

            if let first = ring.first, let last = ring.last,
               first.latitude != last.latitude || first.longitude != last.longitude {
                ring.append(first)
            }

            var annotation = PolygonAnnotation(polygon: Polygon([ring]))
            annotation.fillColor = StyleColor(fillColor)
            annotation.fillOpacity = fillOpacity
            annotation.fillOutlineColor = StyleColor(outlineColor)
            return annotation
        }
    }

    private func applyBoundaryVisibility() {
        guard let mapView = mapView else {
            return
        }

        if boundaryAnnotationManager == nil {
            boundaryAnnotationManager = mapView.annotations.makePolygonAnnotationManager()
        }

        boundaryAnnotationManager?.annotations = boundaryVisible ? boundaryAnnotations : []
    }

    private func clearBoundariesInternal() {
        boundaryAnnotations.removeAll()
        boundaryAnnotationManager?.annotations = []
        boundaryVisible = true
    }

    private func sendMarkerClickIfNear(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let tapLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var nearestId = ""
        var nearestMarker: PointAnnotation?
        var nearestDistance = CLLocationDistance.greatestFiniteMagnitude

        for (id, marker) in markers {
            let markerLocation = CLLocation(
                latitude: marker.point.coordinates.latitude,
                longitude: marker.point.coordinates.longitude
            )
            let distance = tapLocation.distance(from: markerLocation)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestId = id
                nearestMarker = marker
            }
        }

        guard let marker = nearestMarker, nearestDistance <= 75 else {
            return false
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackMarkerTs >= callbackRateLimit else { return true }
        lastKeepCallbackMarkerTs = now
        sendKeepCallback(markerClickCallbackId, payload: [
            "type": "markerClicked",
            "id": nearestId,
            "latitude": marker.point.coordinates.latitude,
            "longitude": marker.point.coordinates.longitude
        ])
        return true
    }

    private func createWaypointMarkerImage() -> UIImage {
        let size = CGSize(width: 72, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cg = context.cgContext
            let centerX = size.width / 2
            let circleCenterY: CGFloat = 32
            let circleRadius: CGFloat = 25

            cg.setFillColor(UIColor.black.withAlphaComponent(0.24).cgColor)
            cg.fillEllipse(in: CGRect(x: centerX - 16, y: size.height - 16, width: 32, height: 8))

            let path = UIBezierPath()
            path.addArc(
                withCenter: CGPoint(x: centerX, y: circleCenterY),
                radius: circleRadius,
                startAngle: 0,
                endAngle: CGFloat.pi * 2,
                clockwise: true
            )
            path.move(to: CGPoint(x: centerX - 14, y: circleCenterY + 19))
            path.addQuadCurve(
                to: CGPoint(x: centerX, y: size.height - 10),
                controlPoint: CGPoint(x: centerX - 5, y: circleCenterY + 52)
            )
            path.addQuadCurve(
                to: CGPoint(x: centerX + 14, y: circleCenterY + 19),
                controlPoint: CGPoint(x: centerX + 5, y: circleCenterY + 52)
            )
            path.close()

            UIColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1).setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 3
            path.stroke()

            UIColor.white.setFill()
            UIBezierPath(
                ovalIn: CGRect(x: centerX - 10, y: circleCenterY - 10, width: 20, height: 20)
            ).fill()

            UIColor.black.withAlphaComponent(0.16).setStroke()
            let innerRing = UIBezierPath(
                ovalIn: CGRect(x: centerX - 10, y: circleCenterY - 10, width: 20, height: 20)
            )
            innerRing.lineWidth = 2
            innerRing.stroke()
        }
    }

    @objc(getCamera:)
    func getCamera(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let state = mapView.cameraState
            self.sendSuccess([
                "latitude": state.center.latitude,
                "longitude": state.center.longitude,
                "zoom": state.zoom,
                "bearing": state.bearing,
                "pitch": state.pitch
            ], command)
        }
    }

    @objc(close:)
    func close(command: CDVInvokedUrlCommand) {
        DispatchQueue.main.async {
            self.closeInternal()
            self.sendSuccess(command)
        }
    }

    @objc(setMapStyle:)
    func setMapStyle(command: CDVInvokedUrlCommand) {
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            guard let styleUrl = options["styleUrl"] as? String, !styleUrl.isEmpty else {
                self.sendError("styleUrl is required", command)
                return
            }

            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed.", command); return
            }
            let styleURI = StyleURI(rawValue: styleUrl) ?? StyleURI.streets
            mapView.mapboxMap.loadStyle(styleURI)
            self.sendSuccess(["status": "styleChanged"], command)
        }
    }

    private func cancelCurrentDownload() {
        activeStylePackDownload?.cancel()
        activeTileRegionDownload?.cancel()
        activeStylePackDownload = nil
        activeTileRegionDownload = nil
    }

    func closeInternal() {
        sessionGeneration &+= 1
        trackingStatusCallbackId = nil
        headingLocationManager?.stopUpdatingLocation()
        headingLocationManager?.stopUpdatingHeading()
        headingLocationManager?.delegate = nil
        headingLocationManager = nil
        stopHeadingFollowMode()
        stopUserTracking()
        markers.removeAll()
        annotations = nil
        clearBoundariesInternal()
        boundaryAnnotationManager = nil
        lineAnnotationManager?.annotations.removeAll()
        lineAnnotationManager = nil
        pathAnnotation = nil
        pathPoints.removeAll()
        isPathTrackingActive = false
        pathTrackingStartTime = 0
        isPathVisible = true
        pathLineColor = "#FF0000"
        pathLineWidth = 3.0
        pathLineOpacity = 1.0
        waypointSelectedCallbackId = nil
        markerClickCallbackId = nil
        offlineDownloadProgressCallbackId = nil
        trackingStatusCallbackId = nil
        moveToCurrentLocationCallbackId = nil
        moveToCurrentLocationZoom = nil
        cancelCurrentDownload()
        isOfflineDownloading = false
        isUserLocationEnabled = false
        isUserTrackingEnabled = false
        isDeviceHeadingEnabled = false
        isHeadingFollowModeEnabled = false
        waypointSelectionEnabled = false
        autoAddWaypointMarker = false
        lastKeepCallbackOfflineTs = 0
        lastKeepCallbackWaypointTs = 0
        lastKeepCallbackMarkerTs = 0
        cancelables.removeAll()
        mapTouchOverlay?.removeFromSuperview()
        mapTouchOverlay = nil
        mapView?.removeFromSuperview()
        mapView = nil
    }

    @objc private func closeFromButton() {
        closeInternal()
    }

    override func onReset() {
        closeInternal()
        super.onReset()
    }

    private func getAccessToken() -> String {
        // Erase the obsolete cache; the bundled public token is authoritative.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.outsystems.mapbox",
            kSecAttrAccount as String: "mapbox_access_token"
        ]
        SecItemDelete(query as CFDictionary)
        let token = preferenceValue("MAPBOX_ACCESS_TOKEN").trimmingCharacters(in: .whitespacesAndNewlines)
        return MapboxSecurity.publicToken(token) ? token : ""
    }

    private func styleAllowed(_ style: String) -> Bool {
        let hosts = preferenceValue("MAPBOX_ALLOWED_STYLE_HOSTS")
        return MapboxSecurity.styleAllowed(style, hosts: hosts.isEmpty ? "api.mapbox.com" : hosts)
    }

    private func validInput(_ options: [String: Any], _ command: CDVInvokedUrlCommand) -> Bool {
        guard JSONSerialization.isValidJSONObject(options),
              let data = try? JSONSerialization.data(withJSONObject: options),
              data.count <= MapboxSecurity.maxInputBytes else {
            sendError("Map input exceeds the 4 MiB limit or is invalid.", command)
            return false
        }
        return true
    }

    private func preferenceValue(_ key: String) -> String {
        if let value = commandDelegate.settings[key] as? String, !value.isEmpty {
            return value == "__MAPBOX_ACCESS_TOKEN_NOT_SET__" ? "" : value
        }
        let lowerKey = key.lowercased()
        if let value = commandDelegate.settings[lowerKey] as? String, !value.isEmpty {
            return value == "__MAPBOX_ACCESS_TOKEN_NOT_SET__" ? "" : value
        }
        return ""
    }

    private func frameFromOptions(_ options: [String: Any]) -> CGRect {
        var x = doubleOption(options["x"], defaultValue: 0)
        var y = doubleOption(options["y"], defaultValue: 0)
        var width = doubleOption(options["width"], defaultValue: Double(webView.bounds.width))
        var height = doubleOption(options["height"], defaultValue: Double(webView.bounds.height))

        let scale = Double(UIScreen.main.scale)
        let bounds = webView.bounds
        let appearsDevicePixelScaled = scale > 1
            && (width > Double(bounds.width) + 1 || height > Double(bounds.height) + 1)

        if appearsDevicePixelScaled {
            x /= scale
            y /= scale
            width /= scale
            height /= scale
        }

        return CGRect(x: x, y: y, width: max(width, 1), height: max(height, 1))
    }

    private func touchRectFromOptions(_ options: [String: Any], mapViewFrame: CGRect) -> CGRect {
        var x = doubleOption(options["x"], defaultValue: 0)
        var y = doubleOption(options["y"], defaultValue: 0)
        var width = doubleOption(options["width"], defaultValue: 0)
        var height = doubleOption(options["height"], defaultValue: 0)

        let scale = Double(UIScreen.main.scale)
        if scale > 1 {
            x /= scale
            y /= scale
            width /= scale
            height /= scale
        }

        let rect = CGRect(x: x, y: y, width: max(width, 0), height: max(height, 0))
        guard rect.width > 0, rect.height > 0 else { return .null }
        return rect.intersection(mapViewFrame)
    }

    private func installMapTouchOverlay(in superview: UIView, frame: CGRect) {
        let overlay = MapTouchOverlayView(frame: frame)
        overlay.backgroundColor = UIColor.clear
        overlay.autoresizingMask = []

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMapOverlayPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        overlay.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleMapOverlayPinch(_:)))
        pinch.delegate = self
        overlay.addGestureRecognizer(pinch)

        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleMapOverlayRotation(_:)))
        rotation.delegate = self
        overlay.addGestureRecognizer(rotation)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMapOverlayTap(_:)))
        tap.delegate = self
        overlay.addGestureRecognizer(tap)

        superview.addSubview(overlay)
        mapTouchOverlay = overlay
    }

    @objc private func handleMapOverlayPan(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView = mapView, let overlay = mapTouchOverlay else {
            return
        }

        if recognizer.state == .changed {
            let translation = recognizer.translation(in: overlay)
            let centerPoint = CGPoint(
                x: mapView.bounds.midX - translation.x,
                y: mapView.bounds.midY - translation.y
            )
            let center = mapView.mapboxMap.coordinate(for: centerPoint)

            mapView.mapboxMap.setCamera(to: CameraOptions(center: center))
            recognizer.setTranslation(.zero, in: overlay)
        }
    }

    @objc private func handleMapOverlayPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let mapView = mapView else {
            return
        }

        if recognizer.state == .changed {
            let zoomDelta = log2(Double(recognizer.scale))
            mapView.mapboxMap.setCamera(to: CameraOptions(
                zoom: mapView.cameraState.zoom + zoomDelta
            ))
            recognizer.scale = 1
        }
    }

    @objc private func handleMapOverlayRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard let mapView = mapView else {
            return
        }

        if recognizer.state == .changed {
            let deltaDegrees = Double(recognizer.rotation) * 180.0 / .pi
            mapView.mapboxMap.setCamera(to: CameraOptions(
                bearing: mapView.cameraState.bearing - deltaDegrees
            ))
            recognizer.rotation = 0
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    @objc private func handleMapOverlayTap(_ recognizer: UITapGestureRecognizer) {
        guard let mapView = mapView, let overlay = mapTouchOverlay else {
            return
        }

        let point = recognizer.location(in: overlay)
        let coordinate = mapView.mapboxMap.coordinate(for: point)

        if sendMarkerClickIfNear(coordinate) {
            return
        }

        guard waypointSelectionEnabled else {
            return
        }

        var id = ""
        if autoAddWaypointMarker {
            id = String(Int(Date().timeIntervalSince1970 * 1000))
            addMarkerInternal(id: id, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackWaypointTs >= callbackRateLimit else { return }
        lastKeepCallbackWaypointTs = now
        sendKeepCallback(waypointSelectedCallbackId, payload: [
            "type": "waypointSelected",
            "id": id,
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude
        ])
    }

    private func doubleOption(_ value: Any?, defaultValue: Double) -> Double {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Float {
            return Double(value)
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        if let value = value as? String, let parsedValue = Double(value) {
            return parsedValue
        }

        return defaultValue
    }

    private func isValidLatitude(_ lat: Double) -> Bool {
        lat.isFinite && lat >= -90 && lat <= 90
    }

    private func isValidLongitude(_ lon: Double) -> Bool {
        lon.isFinite && lon >= -180 && lon <= 180
    }

    private func sanitizeError(contextMessage: String, error: Error) -> String {
        NSLog("MapboxPlugin: %@", contextMessage)
        return contextMessage
    }

    private func colorOption(_ value: Any?, defaultColor: UIColor) -> UIColor {
        guard let rawValue = value as? String else {
            return defaultColor
        }

        var hex = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        guard hex.count == 6 || hex.count == 8, let colorValue = UInt64(hex, radix: 16) else {
            return defaultColor
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if hex.count == 8 {
            red = CGFloat((colorValue & 0xff000000) >> 24) / 255
            green = CGFloat((colorValue & 0x00ff0000) >> 16) / 255
            blue = CGFloat((colorValue & 0x0000ff00) >> 8) / 255
            alpha = CGFloat(colorValue & 0x000000ff) / 255
        } else {
            red = CGFloat((colorValue & 0xff0000) >> 16) / 255
            green = CGFloat((colorValue & 0x00ff00) >> 8) / 255
            blue = CGFloat(colorValue & 0x0000ff) / 255
            alpha = 1
        }

        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func makeWebViewTransparent() {
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
    }

    private func sendSuccess(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendSuccess(_ payload: [String: Any], _ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendSuccess(_ payload: [String: Any], callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        commandDelegate.send(result, callbackId: callbackId)
    }

    private func sendNoResultKeepCallback(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendKeepCallback(_ callbackId: String?, payload: [String: Any]) {
        guard let callbackId = callbackId else {
            return
        }

        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: callbackId)
    }

    private func sendError(_ message: String, _ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendError(_ message: String, callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        commandDelegate.send(result, callbackId: callbackId)
    }
}

private class MapTouchOverlayView: UIView {
    var touchableRects: [CGRect] = []

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let superview = superview else {
            return true
        }

        let superviewPoint = convert(point, to: superview)

        for rect in touchableRects {
            if rect.contains(superviewPoint) {
                return false
            }
        }

        return true
    }
}
