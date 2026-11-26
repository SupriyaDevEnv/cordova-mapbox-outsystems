import Foundation
import CoreFoundation
import CryptoKit
import Security
import CoreLocation
import UIKit
import WebKit
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

    private var sessionCallbacks: [String: Bool] = [:]
    private var streamCallbacks: [String: String] = [:]
    private var closeCallbackId: String?
    private var savedWebViewAppearance: (Bool, UIColor?, UIColor?)?

    func rememberCommand(_ command: CDVInvokedUrlCommand) {
        guard let id = command.callbackId else { return }
        let method = command.methodName ?? ""
        let stream = method.hasPrefix("register")
        if stream, let old = streamCallbacks[method], old != id {
            releaseCallback(old)
        }
        if stream { streamCallbacks[method] = id }
        sessionCallbacks[id] = stream
    }

    func forgetCallback(_ id: String) {
        sessionCallbacks.removeValue(forKey: id)
        streamCallbacks = streamCallbacks.filter { $0.value != id }
    }

    func releaseCallback(_ id: String) {
        forgetCallback(id)
        // Cordova 7 imports this initializer as nullable; Cordova 8 as nonnull.
        let result: CDVPluginResult! = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(false)
        commandDelegate.send(result, callbackId: id)
    }

    @objc(registerCloseCallback:)
    func registerCloseCallback(command: CDVInvokedUrlCommand) {
        if let old = closeCallbackId { releaseCallback(old) }
        closeCallbackId = command.callbackId
        if mapView == nil {
            sendSuccess(command)
            closeCallbackId = nil
        }
    }

    private(set) var mapView: MapView?
    private var initialCameraMinZoom: CGFloat?
    private var initialCameraMaxZoom: CGFloat?
    private var offlineRegionCameraBoundsActive = false
    private var activeOfflineRegionStore: TileStore?
    private var activeOfflineRegionId: String?
    private var activeOfflineDownloadStore: TileStore?
    private var mapTouchOverlay: MapTouchOverlayView?
    private var annotations: PointAnnotationManager?
    private var markers: [String: PointAnnotation] = [:]
    private var markerStyles: [String: MarkerStyle] = [:]
    private var pendingMarkerImages: [String: [String]] = [:]
    private let markerIcons = MarkerIcons()
    private let markerImageNotAllowed =
        "Marker imageUrl must be an HTTPS URL on an allowed host or a base64 image data URI up to 256 KiB."
    private var boundaryAnnotationManager: PolygonAnnotationManager?
    private var boundaryAnnotations: [PolygonAnnotation] = []
    private var isBoundaryDrawing = false
    private var boundaryDrawingPoints: [CLLocationCoordinate2D] = []
    private var boundaryDrawingLineAnnotationManager: PolylineAnnotationManager?
    private var boundaryDrawingLine: PolylineAnnotation?
    private var boundaryDrawingPointAnnotationManager: CircleAnnotationManager?
    private var boundaryDrawingPointAnnotations: [CircleAnnotation] = []
    private var boundaryDrawingPolygonAnnotationManager: PolygonAnnotationManager?
    private var boundaryDrawingPolygon: PolygonAnnotation?
    private var completedBoundaryDrawingPolygons: [PolygonAnnotation] = []
    private var lineAnnotationManager: PolylineAnnotationManager?
    private var pathAnnotations: [PolylineAnnotation] = []
    private var currentSegmentAnnotation: PolylineAnnotation?
    private var pathPoints: [CLLocationCoordinate2D] = []
    private var isPathTrackingActive = false
    private var isPathTrackingPaused = false
    private var pathTrackingStartTime: TimeInterval = 0
    private var pathPausedTotal: TimeInterval = 0
    private var pathPauseStart: TimeInterval = 0
    private var isPathVisible = true
    private var pathLineColor: String = "#FF0000"
    private var pathLineWidth: Double = 3.0
    private var pathLineOpacity: Double = 1.0
    private var pathSegments: [[CLLocationCoordinate2D]] = []
    private var currentSegment: [CLLocationCoordinate2D] = []
    // The live line is drawn in pieces of pathChunkPoints, so each GPS fix redraws only the
    // newest piece instead of the whole recording. Finished pieces are kept in
    // pathAnnotations like any other drawn line.
    private let pathChunkPoints = 500
    private var liveChunkIds: [String] = []
    private var liveChunkStart = 0
    private var liveChunkFirst: CLLocationCoordinate2D?
    private var waypointSelectedCallbackId: String?
    private var markerClickCallbackId: String?
    private var mapTapCallbackId: String?
    private var boundaryAreaCallbackId: String?
    private var offlineDownloadProgressCallbackId: String?
    private var compassCallbackId: String?
    private var lastCompassBearing: Double = -1
    private var lastCompassVisible = false
    private var activeStylePackDownload: Cancelable?
    private var activeTileRegionDownload: Cancelable?
    private var isOfflineDownloading = false
    // Incremented for each download and on cancel; stale download callbacks are ignored.
    private var offlineDownloadToken: UInt64 = 0
    private var activeDownloadCommand: CDVInvokedUrlCommand?
    private var waypointSelectionEnabled = false
    private var autoAddWaypointMarker = false
    private var cancelables = Set<AnyCancelable>()
    private var compassSubscription: AnyCancelable?
    private var headingLocationManager: CLLocationManager?
    private var lastHeadingBearing: CLLocationDirection = -1
    private var lastHeadingUpdate: TimeInterval = 0
    private var isUserTrackingEnabled = false
    private(set) var isCameraFollowingUser = false
    private var isUserLocationEnabled = false
    private var isDeviceHeadingEnabled = false
    private var isHeadingFollowModeEnabled = false
    private var trackingStatusCallbackId: String?
    private var lastUserTrackingUpdate: TimeInterval = 0
    private var lastKeepCallbackOfflineTs: TimeInterval = 0
    private var lastKeepCallbackWaypointTs: TimeInterval = 0
    private var lastKeepCallbackMarkerTs: TimeInterval = 0
    private var lastKeepCallbackMapTapTs: TimeInterval = 0
    private var lastBoundaryDrawingTapTs: TimeInterval = 0
    private let callbackRateLimit: TimeInterval = 0.1
    private let maxMarkers = 10000
    private let maxBoundaries = 1000
    private let maxOfflineRadiusKm: Double = 50.0
    // Stored offline regions; each is already limited to about 50,000 tiles.
    private let maxOfflineRegions = 20
    private let minOfflineZoom: UInt8 = 2
    private let maxOfflineZoom: UInt8 = 18
    // Total vertices accepted in a downloadOfflineRegion polygon (all rings).
    private let maxOfflinePolygonPoints = 1000
    private var boundaryVisible = true

    @objc(ping:)
    func ping(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        sendSuccess([
            "status": "ok",
            "service": "MapboxPlugin",
            "class": "MapboxPlugin"
        ], command)
    }

    private func optionalCameraZoom(_ options: [String: Any], _ key: String) throws -> CGFloat? {
        guard let value = options[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              (0...25.5).contains(number.doubleValue) else {
            throw NSError(domain: "MapboxPlugin", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(key) must be a finite number between 0 and 25.5."
            ])
        }
        return CGFloat(number.doubleValue)
    }

    @objc(initialize:)
    func initialize(command: CDVInvokedUrlCommand) {
        DispatchQueue.main.async {
            guard let options = command.argument(at: 0) as? [String: Any] else {
                self.sendError("Options are required.", command)
                return
            }

            guard self.validInput(options, command) else { return }
            let minZoom: CGFloat?
            let maxZoom: CGFloat?
            do {
                minZoom = try self.optionalCameraZoom(options, "minZoom")
                maxZoom = try self.optionalCameraZoom(options, "maxZoom")
            } catch {
                self.sendError(error.localizedDescription, command)
                return
            }
            if let minZoom = minZoom, let maxZoom = maxZoom, minZoom > maxZoom {
                self.sendError("minZoom must be less than or equal to maxZoom.", command)
                return
            }
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
            self.initialCameraMinZoom = minZoom
            self.initialCameraMaxZoom = maxZoom
            self.offlineRegionCameraBoundsActive = false
            self.rememberCommand(command)

            MapboxOptions.accessToken = token

            let camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom,
                bearing: bearing,
                pitch: pitch
            )

            let styleURI = StyleURI(rawValue: styleUrl) ?? .streets
            let initOptions = MapInitOptions(cameraOptions: camera, styleURI: nil)

            let isInline = options["inline"] as? Bool ?? false
            let mapView = MapView(
                frame: isInline ? self.frameFromOptions(options) : self.webView.bounds,
                mapInitOptions: initOptions
            )

            if minZoom != nil || maxZoom != nil {
                do {
                    try mapView.mapboxMap.setCameraBounds(with: CameraBoundsOptions(
                        maxZoom: maxZoom, minZoom: minZoom
                    ))
                    // Reapply after bounds: MapInitOptions may have clamped zoom to SDK defaults.
                    mapView.mapboxMap.setCamera(to: camera)
                } catch {
                    self.sendError("Camera zoom bounds conflict with the map's default bounds.", command)
                    return
                }
            }

            mapView.ornaments.options.compass.visibility = .hidden
            mapView.ornaments.options.scaleBar.visibility = .hidden

            mapView.autoresizingMask = isInline ? [] : [.flexibleWidth, .flexibleHeight]

            if behindWebView, let superview = self.webView.superview {
                self.makeWebViewTransparent()

                // frameFromOptions() returns coordinates relative to the WebView.
                // Convert them to the WebView's superview coordinate system
                // before adding the native Mapbox view.
                let mapFrameInWebView = self.frameFromOptions(options)

                let mapFrameInSuperview =
                    self.webView.convert(mapFrameInWebView, to: superview)

                mapView.frame = mapFrameInSuperview

                superview.insertSubview(mapView, belowSubview: self.webView)

                self.installMapTouchOverlay(
                    in: superview,
                    frame: mapFrameInSuperview
                )
            } else {
                self.webView.superview?.addSubview(mapView)
            }

            self.mapView = mapView
            mapView.gestures.panGestureRecognizer.addTarget(self, action: #selector(self.pauseCameraFollowForGesture(_:)))
            mapView.gestures.pinchGestureRecognizer.addTarget(self, action: #selector(self.pauseCameraFollowForGesture(_:)))
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

            self.loadReadyStyle(styleURI, status: "initialized", command: command)
        }
    }

    private struct OfflineStoreEntry {
        let store: TileStore
        let isolated: Bool
    }

    private struct OfflineRegionEntry {
        let region: TileRegion
        let isolated: Bool
    }

    private func offlineRegionRoot(create: Bool) throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(domain: "MapboxPlugin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Offline storage is unavailable."])
        }
        let root = support.appendingPathComponent("mapbox-offline-regions", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func offlineRegionDirectory(_ regionId: String, create: Bool) throws -> URL {
        let digest = SHA256.hash(data: Data(regionId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = try offlineRegionRoot(create: create)
            .appendingPathComponent(digest, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func offlineRegionTileStore(_ regionId: String) throws -> TileStore {
        _ = TileStore.default
        let tilePath = try offlineRegionDirectory(regionId, create: true)
            .appendingPathComponent("tiles", isDirectory: true)
        try FileManager.default.createDirectory(at: tilePath, withIntermediateDirectories: true)
        return TileStore.shared(for: tilePath)
    }

    private func existingOfflineRegionTileStore(_ regionId: String) -> TileStore? {
        guard let directory = try? offlineRegionDirectory(regionId, create: false) else { return nil }
        let tilePath = directory.appendingPathComponent("tiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: tilePath.path) else { return nil }
        return TileStore.shared(for: tilePath)
    }

    private func offlineRegionDataPath(_ regionId: String) throws -> URL {
        let path = try offlineRegionDirectory(regionId, create: true)
            .appendingPathComponent("map-data", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func isOfflineRegionMarkedComplete(_ regionId: String) -> Bool {
        guard let directory = try? offlineRegionDirectory(regionId, create: false) else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".complete").path
        )
    }

    private func setOfflineRegionComplete(_ regionId: String, complete: Bool) throws {
        let marker = try offlineRegionDirectory(regionId, create: true)
            .appendingPathComponent(".complete")
        if complete {
            try Data().write(to: marker, options: .atomic)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    private func offlineRegionStores() throws -> [OfflineStoreEntry] {
        _ = TileStore.default
        var stores: [OfflineStoreEntry] = []
        let root = try offlineRegionRoot(create: false)
        if FileManager.default.fileExists(atPath: root.path) {
            let directories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
                let tilePath = directory.appendingPathComponent("tiles", isDirectory: true)
                if values.isDirectory == true && FileManager.default.fileExists(atPath: tilePath.path) {
                    stores.append(OfflineStoreEntry(store: TileStore.shared(for: tilePath), isolated: true))
                }
            }
        }
        stores.append(OfflineStoreEntry(store: TileStore.default, isolated: false))
        return stores
    }

    private func loadOfflineRegions(
        _ stores: [OfflineStoreEntry],
        index: Int = 0,
        regions: [String: OfflineRegionEntry] = [:],
        completion: @escaping ([String: OfflineRegionEntry]?, String?) -> Void
    ) {
        guard index < stores.count else {
            completion(regions, nil)
            return
        }
        let entry = stores[index]
        entry.store.allTileRegions { result in
            switch result {
            case .success(let tileRegions):
                var updated = regions
                for region in tileRegions {
                    if updated[region.id] == nil || entry.isolated {
                        updated[region.id] = OfflineRegionEntry(region: region, isolated: entry.isolated)
                    }
                }
                self.loadOfflineRegions(stores, index: index + 1, regions: updated, completion: completion)
            case .failure:
                completion(nil, "Failed to read offline regions.")
            }
        }
    }

    /// Opens only a region downloaded on this device. The region is checked before any
    /// view is shown, no online starting style is loaded, and Mapbox network access is
    /// switched off until the map closes so only downloaded data is displayed.
    @objc(initializeOffline:)
    func initializeOffline(command: CDVInvokedUrlCommand) {
        DispatchQueue.main.async {
            guard let options = command.argument(at: 0) as? [String: Any] else {
                self.sendError("Options are required.", command)
                return
            }
            guard self.validInput(options, command) else { return }

            let regionId = (options["regionId"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regionId.isEmpty else {
                self.sendError("regionId is required.", command)
                return
            }
            guard regionId.utf8.count <= 256 else {
                self.sendError("Invalid region id.", command)
                return
            }

            let minZoom: CGFloat?
            let maxZoom: CGFloat?
            do {
                minZoom = try self.optionalCameraZoom(options, "minZoom")
                maxZoom = try self.optionalCameraZoom(options, "maxZoom")
            } catch {
                self.sendError(error.localizedDescription, command)
                return
            }
            if let minZoom = minZoom, let maxZoom = maxZoom, minZoom > maxZoom {
                self.sendError("minZoom must be less than or equal to maxZoom.", command)
                return
            }
            let token = self.getAccessToken()
            guard !token.isEmpty else {
                self.sendError("A public pk.* Mapbox token is required. Configure MAPBOX_ACCESS_TOKEN in OutSystems Extensibility Configuration.", command)
                return
            }

            guard self.isOfflineRegionMarkedComplete(regionId) else {
                self.sendError("Offline region '\(regionId)' is not isolated on this device. Download it again.", command)
                return
            }

            let generation = self.sessionGeneration
            let regionStore: TileStore
            do {
                regionStore = try self.offlineRegionTileStore(regionId)
            } catch {
                self.sendError(self.sanitizeError(contextMessage: "Failed to prepare isolated offline storage.", error: error), command)
                return
            }
            regionStore.tileRegionGeometry(forId: regionId) { result in
                DispatchQueue.main.async {
                    guard generation == self.sessionGeneration else {
                        self.sendError("Map closed; operation cancelled.", command)
                        return
                    }
                    guard case .success = result else {
                        self.sendError("Offline region '\(regionId)' is not downloaded on this device.", command)
                        return
                    }
                    self.openOfflineMapView(regionId: regionId, options: options,
                                            minZoom: minZoom, maxZoom: maxZoom,
                                            token: token, regionStore: regionStore, command: command)
                }
            }
        }
    }

    private func openOfflineMapView(regionId: String, options: [String: Any],
                                    minZoom: CGFloat?, maxZoom: CGFloat?,
                                    token: String, regionStore: TileStore,
                                    command: CDVInvokedUrlCommand) {
        self.closeInternal()
        self.activeOfflineRegionStore = regionStore
        self.activeOfflineRegionId = regionId
        self.initialCameraMinZoom = minZoom
        self.initialCameraMaxZoom = maxZoom
        self.offlineRegionCameraBoundsActive = false
        self.rememberCommand(command)

        MapboxOptions.accessToken = token

        // Placeholder camera; showDownloadedRegion centres and fits the region.
        let camera = CameraOptions(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            zoom: 12
        )
        let isInline = options["inline"] as? Bool ?? false
        let behindWebView = options["behindWebView"] as? Bool ?? true
        // A per-region cache prevents tiles previously viewed elsewhere from leaking in.
        let previousTileStore = MapboxMapsOptions.tileStore
        let previousDataPath = MapboxMapsOptions.dataPath
        let mapView: MapView
        do {
            MapboxMapsOptions.tileStore = regionStore
            MapboxMapsOptions.dataPath = try offlineRegionDataPath(regionId)
            // No starting style: the online default map is never requested.
            let initOptions = MapInitOptions(cameraOptions: camera, styleURI: nil)
            mapView = MapView(
                frame: isInline ? self.frameFromOptions(options) : self.webView.bounds,
                mapInitOptions: initOptions
            )
        } catch {
            MapboxMapsOptions.tileStore = previousTileStore
            MapboxMapsOptions.dataPath = previousDataPath
            sendError(sanitizeError(contextMessage: "Failed to initialize the offline map.", error: error), command)
            closeInternal()
            return
        }
        MapboxMapsOptions.tileStore = previousTileStore
        MapboxMapsOptions.dataPath = previousDataPath

        if minZoom != nil || maxZoom != nil {
            do {
                try mapView.mapboxMap.setCameraBounds(with: CameraBoundsOptions(
                    maxZoom: maxZoom, minZoom: minZoom
                ))
                // Reapply after bounds: MapInitOptions may have clamped zoom to SDK defaults.
                mapView.mapboxMap.setCamera(to: camera)
            } catch {
                self.sendError("Camera zoom bounds conflict with the map's default bounds.", command)
                return
            }
        }

        mapView.ornaments.options.compass.visibility = .hidden
        mapView.ornaments.options.scaleBar.visibility = .hidden

        mapView.autoresizingMask = isInline ? [] : [.flexibleWidth, .flexibleHeight]

        if behindWebView, let superview = self.webView.superview {
            self.makeWebViewTransparent()

            // frameFromOptions() returns coordinates relative to the WebView.
            // Convert them to the WebView's superview coordinate system
            // before adding the native Mapbox view.
            let mapFrameInWebView = self.frameFromOptions(options)

            let mapFrameInSuperview =
                self.webView.convert(mapFrameInWebView, to: superview)

            mapView.frame = mapFrameInSuperview

            superview.insertSubview(mapView, belowSubview: self.webView)

            self.installMapTouchOverlay(
                in: superview,
                frame: mapFrameInSuperview
            )
        } else {
            self.webView.superview?.addSubview(mapView)
        }

        self.mapView = mapView
        mapView.gestures.panGestureRecognizer.addTarget(self, action: #selector(self.pauseCameraFollowForGesture(_:)))
        mapView.gestures.pinchGestureRecognizer.addTarget(self, action: #selector(self.pauseCameraFollowForGesture(_:)))
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

        // Only downloaded data from now on; closeInternal() reconnects.
        OfflineSwitch.shared.isMapboxStackConnected = false

        self.showDownloadedRegion(regionId: regionId, options: options, command: command)
    }

    @objc(setCamera:)
    func setCamera(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            guard let camera = self.cameraFromOptions(options, mapView: mapView, command) else { return }
            mapView.mapboxMap.setCamera(to: camera)

            self.sendSuccess(command)
        }
    }

    /// Camera for setCamera/flyTo: omitted values keep the current camera. Returns nil
    /// after reporting the error when the coordinates are invalid.
    private func cameraFromOptions(_ options: [String: Any], mapView: MapView,
                                   _ command: CDVInvokedUrlCommand) -> CameraOptions? {
        let latitude = doubleOption(options["latitude"], defaultValue: mapView.cameraState.center.latitude)
        let longitude = doubleOption(options["longitude"], defaultValue: mapView.cameraState.center.longitude)

        guard isValidLatitude(latitude), isValidLongitude(longitude) else {
            sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
            return nil
        }

        let zoom = doubleOption(options["zoom"], defaultValue: mapView.cameraState.zoom)
        let bearing = doubleOption(options["bearing"], defaultValue: mapView.cameraState.bearing)
        let pitch = doubleOption(options["pitch"], defaultValue: mapView.cameraState.pitch)
        return CameraOptions(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            zoom: zoom,
            bearing: bearing,
            pitch: pitch
        )
    }

    @objc(resetMapBearing:)
    func resetMapBearing(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            mapView.camera.ease(
                to: CameraOptions(bearing: 0),
                duration: 0.4
            )

            self.sendSuccess(command)
        }
    }

    @objc(flyTo:)
    func flyTo(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            guard let camera = self.cameraFromOptions(options, mapView: mapView, command) else { return }

            let duration = (options["duration"] as? Double)
                .flatMap { $0.isFinite ? min(max($0, 0), 10000) / 1000.0 : nil }
            mapView.camera.fly(to: camera, duration: duration)

            self.sendSuccess(command)
        }
    }

    @objc(setViewport:)
    func setViewport(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let newFrame = self.frameFromOptions(options)

            if let superview = mapView.superview,
               self.webView.superview === superview {

                let convertedFrame =
                    self.webView.convert(newFrame, to: superview)

                mapView.frame = convertedFrame
                self.mapTouchOverlay?.frame = convertedFrame

            } else {

                mapView.frame = newFrame
                self.mapTouchOverlay?.frame = newFrame
            }

            self.sendSuccess(command)
        }
    }

    @objc(setTouchableRects:)
    func setTouchableRects(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let rects = command.argument(at: 0) as? [[String: Any]] ?? []

            let maxRects = 256
            guard rects.count <= maxRects else {
                self.sendError("Too many touchable rects. Maximum is \(maxRects).", command)
                return
            }

            self.mapTouchOverlay?.touchableRects = rects.compactMap {
                self.touchRectFromOptions($0)
            }
            self.sendSuccess(command)
        }
    }

    @objc(enableUserLocation:)
    func enableUserLocation(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
        rememberCommand(command)
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
        rememberCommand(command)
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
        rememberCommand(command)
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

    private func startHeadingFollowMode(_ command: CDVInvokedUrlCommand) {
        guard CLLocationManager.headingAvailable() else {
            sendError("Device heading sensor is not available.", command)
            return
        }

        requestLocationAuthorizationIfNeeded()
        headingLocationManager?.startUpdatingHeading()
        isHeadingFollowModeEnabled = true
        fireTrackingStatusChanged()
        sendSuccess(command)
    }

    private func startUserTracking(_ command: CDVInvokedUrlCommand) {
        requestLocationAuthorizationIfNeeded()
        isUserTrackingEnabled = true
        resumeCameraFollowing()
        fireTrackingStatusChanged()
        headingLocationManager?.startUpdatingLocation()
        sendSuccess(command)
    }

    private func stopUserTracking() {
        isUserTrackingEnabled = false
        isCameraFollowingUser = false
        fireTrackingStatusChanged()
        headingLocationManager?.stopUpdatingLocation()
        lastUserTrackingUpdate = 0
    }

    private(set) var isRecenterAnimating = false
    private var recenterAnimationGeneration: UInt64 = 0

    func resetRecenterAnimation() {
        recenterAnimationGeneration &+= 1
        isRecenterAnimating = false
    }

    func runRecenterAnimation(to camera: CameraOptions) {
        guard let mapView = mapView else { return }
        recenterAnimationGeneration &+= 1
        let generation = recenterAnimationGeneration
        isRecenterAnimating = true
        mapView.camera.fly(to: camera, duration: 1.5) { [weak self] _ in
            guard let self = self, self.recenterAnimationGeneration == generation else { return }
            self.isRecenterAnimating = false
        }
    }

    func resumeCameraFollowing() {
        isCameraFollowingUser = true
    }

    func isTrackingLocationManager(_ manager: CLLocationManager) -> Bool {
        isUserTrackingEnabled && manager === headingLocationManager
    }

    @objc private func pauseCameraFollowForGesture(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        guard isCameraFollowingUser else { return }
        isCameraFollowingUser = false
        resetRecenterAnimation()
        mapView?.camera.cancelAnimations()
    }

    private func stopHeadingFollowMode() {
        headingLocationManager?.stopUpdatingHeading()
        lastHeadingBearing = -1
        lastHeadingUpdate = 0
        isHeadingFollowModeEnabled = false
        fireTrackingStatusChanged()
    }

    /// Creates the shared heading/location manager once and asks for permission if needed.
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
            guard !self.isRecenterAnimating else { return }
            self.mapView?.mapboxMap.setCamera(to: CameraOptions(bearing: bearing))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === headingLocationManager else { return }
        guard let location = locations.last else {
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
            guard self.isTrackingLocationManager(manager) else { return }
            if self.isCameraFollowingUser && !self.isRecenterAnimating {
                self.mapView?.mapboxMap.setCamera(to: CameraOptions(center: coordinate))
            }

            if self.isPathTrackingActive && !self.isPathTrackingPaused {
                guard self.pathPoints.count < MapboxSecurity.maxPoints else {
                    self.stopUserTracking()
                    return // Keep the recording available to stopPathTracking().
                }
                self.pathPoints.append(coordinate)
                self.currentSegment.append(coordinate)
                self.updatePathAnnotation()
            }
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Tracking keeps running after a transient failure; one-shot location requests are
        // answered by MapboxPluginParity, which overrides this method.
    }

    private func shortestBearingDelta(from: CLLocationDirection, to: CLLocationDirection) -> CLLocationDirection {
        return (to - from + 540.0).truncatingRemainder(dividingBy: 360.0) - 180.0
    }

    @objc(addMarker:)
    func addMarker(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }

            let id: String
            if let rawId = options["id"] {
                guard let idStr = self.stringOption(rawId) else {
                    self.sendError("Invalid id: must be a string, number, or boolean.", command)
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
            let isFind = options["isFind"] as? Bool ?? false
            guard let style = self.markerStyle(isFind: isFind, pinColor: options["pinColor"], imageUrl: options["imageUrl"], pinStyle: options["pinStyle"], isOnline: options["isOnline"] as? Bool ?? true, isPublic: options["isPublic"] as? Bool ?? true, findGiven: (options["isFind"] as? Bool) != nil) else {
                self.sendError(self.markerImageNotAllowed, command)
                return
            }
            self.addMarkerInternal(id: id, latitude: latitude, longitude: longitude, style: style)
            self.sendSuccess(["id": id], command)
        }
    }

    @objc(loadMarkers:)
    func loadMarkers(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
            var styles: [MarkerStyle] = []
            for (index, marker) in markers.enumerated() {
                let id = marker["Id"].flatMap(self.stringOption) ?? String(index)
                guard !id.isEmpty, id.utf8.count <= 256 else { self.sendError("Invalid marker id.", command); return }
                let isFind = marker["IsFind"] as? Bool ?? false
                guard let style = self.markerStyle(isFind: isFind, pinColor: marker["PinColor"], imageUrl: marker["ImageUrl"], pinStyle: marker["PinStyle"], isOnline: marker["IsOnline"] as? Bool ?? true, isPublic: marker["IsPublic"] as? Bool ?? true, findGiven: (marker["IsFind"] as? Bool) != nil) else {
                    self.sendError(self.markerImageNotAllowed, command); return
                }
                styles.append(style)
                ids.insert(id)
            }
            guard markers.count <= self.maxMarkers, ids.count <= self.maxMarkers else {
                self.sendError("Too many markers: maximum total is \(self.maxMarkers).", command); return
            }
            if replace { self.clearMarkersInternal() }
            for (index, marker) in markers.enumerated() {
                let id = marker["Id"].flatMap(self.stringOption) ?? String(index)
                let latitude = self.doubleOption(marker["Latitude"], defaultValue: 0)
                let longitude = self.doubleOption(marker["Longitude"], defaultValue: 0)
                guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                    continue
                }
                self.addMarkerInternal(id: id, latitude: latitude, longitude: longitude, style: styles[index], publish: false)
            }
            self.annotations?.annotations = Array(self.markers.values)

            self.sendSuccess(command)
        }
    }

    @objc(removeMarker:)
    func removeMarker(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            guard let id = options["id"] as? String, !id.isEmpty else {
                self.sendError("markerId must be a non-empty string.", command)
                return
            }
            self.markers.removeValue(forKey: id)
            self.markerStyles.removeValue(forKey: id)
            // Keep shared downloads alive without retaining the removed marker.
            for imageUrl in Array(self.pendingMarkerImages.keys) {
                self.pendingMarkerImages[imageUrl]?.removeAll { $0 == id }
            }
            self.annotations?.annotations = Array(self.markers.values)
            self.sendSuccess(command)
        }
    }

    @objc(clearMarkers:)
    func clearMarkers(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            self.clearMarkersInternal()
            self.sendSuccess(command)
        }
    }

    @objc(loadBoundaries:)
    func loadBoundaries(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
        rememberCommand(command)
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
        rememberCommand(command)
        runForSession {
            self.clearBoundariesInternal()
            self.sendSuccess(command)
        }
    }

    @objc(startBoundaryDrawing:)
    func startBoundaryDrawing(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            guard self.ensureBoundaryDrawingAnnotationManagers() else {
                self.sendError("Unable to initialize drawing managers.", command)
                return
            }

            self.clearBoundaryDrawingInternal()
            self.isBoundaryDrawing = true
            self.lastBoundaryDrawingTapTs = 0
            self.sendSuccess(command)
        }
    }

    @objc(undoBoundaryPoint:)
    func undoBoundaryPoint(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.isBoundaryDrawing else {
                self.sendError("Boundary drawing is not active.", command)
                return
            }

            guard !self.boundaryDrawingPoints.isEmpty else {
                self.sendError("No points available to undo.", command)
                return
            }

            self.boundaryDrawingPoints.removeLast()
            self.redrawBoundaryDrawing()
            self.notifyBoundaryAreaChanged()
            self.sendSuccess(command)
        }
    }

    @objc(saveBoundaryDrawing:)
    func saveBoundaryDrawing(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.isBoundaryDrawing else {
                self.sendError("Boundary drawing is not active.", command)
                return
            }

            guard self.boundaryDrawingPoints.count >= 3 else {
                self.sendError("At least 3 points are required.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }

            let geometry = self.boundaryDrawingPoints.map { point in
                ["lat": point.latitude, "lon": point.longitude]
            }
            let result: [String: Any] = [
                "name": options["name"] as? String ?? "",
                "geometry": geometry,
                "count": self.boundaryDrawingPoints.count,
                "areaAcres": self.calculateBoundaryAreaAcres(self.boundaryDrawingPoints)
            ]

            if let polygon = self.boundaryDrawingPolygon {
                self.completedBoundaryDrawingPolygons.append(polygon)
                self.boundaryDrawingPolygon = nil
            }
            self.removeActiveBoundaryDrawingLine()
            self.removeActiveBoundaryDrawingPointAnnotations()
            self.boundaryDrawingPoints.removeAll()
            self.isBoundaryDrawing = false
            self.sendSuccess(result, command)
        }
    }

    @objc(cancelBoundaryDrawing:)
    func cancelBoundaryDrawing(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            self.clearBoundaryDrawingInternal()
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

    /// Draws one polyline per finished segment. A segment needs two points to be a line.
    private func drawSegmentAnnotations() {
        guard ensureLineAnnotationManager() else { return }
        for segment in pathSegments where segment.count >= 2 {
            var annotation = PolylineAnnotation(lineCoordinates: segment)
            annotation.lineColor = StyleColor(colorOption(pathLineColor, defaultColor: .red))
            annotation.lineWidth = pathLineWidth
            annotation.lineOpacity = pathLineOpacity
            pathAnnotations.append(annotation)
            lineAnnotationManager?.annotations.append(annotation)
        }
    }

    private func updatePathAnnotation() {
        guard currentSegment.count >= 2, ensureLineAnnotationManager() else { return }

        // Delete old annotation for current segment
        if let old = currentSegmentAnnotation {
            lineAnnotationManager?.annotations.removeAll { $0.id == old.id }
            currentSegmentAnnotation = nil
        }

        guard isPathVisible else { return }

        let first = currentSegment[0]
        if liveChunkStart > currentSegment.count || liveChunkFirst?.latitude != first.latitude
            || liveChunkFirst?.longitude != first.longitude {
            // A new segment: earlier pieces now belong to finished segments.
            liveChunkStart = 0
            liveChunkIds.removeAll()
            liveChunkFirst = first
        }

        var added: [PolylineAnnotation] = []
        if let firstId = liveChunkIds.first,
           !(lineAnnotationManager?.annotations.contains { $0.id == firstId } ?? false) {
            // The path was hidden and shown again: draw this segment's finished pieces again.
            liveChunkIds.removeAll()
            var start = 0
            while start < liveChunkStart {
                let piece = pathLine(Array(currentSegment[start...(start + pathChunkPoints)]))
                added.append(piece)
                liveChunkIds.append(piece.id)
                start += pathChunkPoints
            }
        }

        // Freeze full pieces; consecutive pieces share an end point so the line is continuous.
        while currentSegment.count - liveChunkStart > pathChunkPoints + 1 {
            let piece = pathLine(Array(currentSegment[liveChunkStart...(liveChunkStart + pathChunkPoints)]))
            added.append(piece)
            liveChunkIds.append(piece.id)
            liveChunkStart += pathChunkPoints
        }

        let live = pathLine(Array(currentSegment[liveChunkStart...]))
        currentSegmentAnnotation = live
        pathAnnotations.append(contentsOf: added)
        lineAnnotationManager?.annotations.append(contentsOf: added + [live])
    }

    private func pathLine(_ coordinates: [CLLocationCoordinate2D]) -> PolylineAnnotation {
        var annotation = PolylineAnnotation(lineCoordinates: coordinates)
        annotation.lineColor = StyleColor(colorOption(pathLineColor, defaultColor: .red))
        annotation.lineWidth = pathLineWidth
        annotation.lineOpacity = pathLineOpacity
        return annotation
    }

    @objc(startPathTracking:)
    func startPathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
            self.isPathTrackingPaused = false
            self.isPathVisible = true
            self.pathTrackingStartTime = Date().timeIntervalSince1970
            self.pathPausedTotal = 0
            self.pathPauseStart = 0
            self.pathPoints.removeAll()
            self.pathAnnotations.removeAll()
            self.currentSegmentAnnotation = nil
            self.pathSegments.removeAll()
            self.currentSegment.removeAll()

            self.pathLineColor = options["lineColor"] as? String ?? "#FF0000"
            self.pathLineWidth = self.lineWidthOption(options["lineWidth"])
            self.pathLineOpacity = self.lineOpacityOption(options["lineOpacity"])

            if self.boolOption(options["trackCamera"], defaultValue: true) {
                self.startUserTracking(command)
            } else {
                self.sendSuccess(["status": "started"], command)
            }
        }
    }

    @objc(stopPathTracking:)
    func stopPathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.isPathTrackingActive else {
                self.sendError("Path tracking is not active.", command)
                return
            }

            let wasPaused = self.isPathTrackingPaused
            self.isPathTrackingActive = false
            self.isPathTrackingPaused = false
            let now = Date().timeIntervalSince1970
            if wasPaused {
                self.pathPausedTotal += now - self.pathPauseStart
            }
            // Moving time: wall-clock time minus every pause.
            let duration = max(0, now - self.pathTrackingStartTime - self.pathPausedTotal)

            // Freeze current segment annotation into the permanent list
            if let ann = self.currentSegmentAnnotation {
                self.pathAnnotations.append(ann)
                self.currentSegmentAnnotation = nil
            }

            // Finish current segment if it has points
            if !self.currentSegment.isEmpty {
                self.pathSegments.append(self.currentSegment)
                self.currentSegment.removeAll()
            }

            // Measured inside each segment so the jump across a pause adds nothing.
            var totalDistance: Double = 0
            for segment in self.pathSegments {
                for (previous, current) in zip(segment, segment.dropFirst()) {
                    let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    let to = CLLocation(latitude: current.latitude, longitude: current.longitude)
                    totalDistance += from.distance(from: to)
                }
            }

            let pointsArray: [[String: Double]] = self.pathPoints.map { ["lat": $0.latitude, "lon": $0.longitude] }

            // Build segment boundaries
            var segmentsArray: [[String: Int]] = []
            var startIndex = 0
            for segment in self.pathSegments {
                segmentsArray.append([
                    "startIndex": startIndex,
                    "endIndex": startIndex + segment.count - 1
                ])
                startIndex += segment.count
            }

            self.sendSuccess([
                "points": pointsArray,
                "distance": (totalDistance * 100).rounded() / 100,
                "duration": (duration * 1000).rounded(),
                "segments": segmentsArray,
                "segmentCount": self.pathSegments.count
            ], command)
        }
    }

    @objc(pausePathTracking:)
    func pausePathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.isPathTrackingActive else {
                self.sendError("Path tracking is not active.", command)
                return
            }

            guard !self.isPathTrackingPaused else {
                self.sendError("Path tracking is already paused.", command)
                return
            }

            self.isPathTrackingPaused = true
            self.pathPauseStart = Date().timeIntervalSince1970

            // Freeze current segment annotation into the permanent list
            if let ann = self.currentSegmentAnnotation {
                self.pathAnnotations.append(ann)
                self.currentSegmentAnnotation = nil
            }

            // Finish current segment
            if !self.currentSegment.isEmpty {
                self.pathSegments.append(self.currentSegment)
                self.currentSegment.removeAll()
            }

            self.sendSuccess([
                "status": "paused",
                "segmentCount": self.pathSegments.count
            ], command)
        }
    }

    @objc(continuePathTracking:)
    func continuePathTracking(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.isPathTrackingActive else {
                self.sendError("Path tracking is not active.", command)
                return
            }

            guard self.isPathTrackingPaused else {
                self.sendError("Path tracking is not paused. Call pausePathTracking first.", command)
                return
            }

            self.isPathTrackingPaused = false
            self.pathPausedTotal += Date().timeIntervalSince1970 - self.pathPauseStart
            self.pathPauseStart = 0
            self.currentSegment.removeAll()

            self.sendSuccess([
                "status": "continued",
                "segmentCount": self.pathSegments.count + 1
            ], command)
        }
    }

    @objc(loadPath:)
    func loadPath(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
            let lineWidth = self.lineWidthOption(options["lineWidth"])
            let lineOpacity = self.lineOpacityOption(options["lineOpacity"])

            self.pathLineColor = lineColorHex
            self.pathLineWidth = lineWidth
            self.pathLineOpacity = lineOpacity
            self.isPathVisible = true

            // Keep each valid point's original index so segment ranges still line up
            // when invalid points are skipped.
            var validPoints: [CLLocationCoordinate2D] = []
            var validIndexes: [Int] = []
            // A loaded path replaces any live segment.
            self.currentSegment.removeAll()
            for (index, pointDict) in pointsArray.enumerated() {
                let lat = self.doubleOption(pointDict["lat"] ?? pointDict["latitude"], defaultValue: Double.nan)
                let lon = self.doubleOption(pointDict["lon"] ?? pointDict["lng"] ?? pointDict["longitude"], defaultValue: Double.nan)
                guard lat.isFinite, lon.isFinite, self.isValidLatitude(lat), self.isValidLongitude(lon) else { continue }
                validPoints.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                validIndexes.append(index)
            }

            guard validPoints.count >= 2 else {
                self.sendError("A path requires at least 2 valid points.", command)
                return
            }

            self.pathPoints = validPoints

            // Optional segments keep the pause gaps; without them the path is one line.
            self.pathSegments.removeAll()
            if let segmentObjects = options["segments"] as? [[String: Any]] {
                for segmentObject in segmentObjects.prefix(1000) {
                    guard let startIndex = (segmentObject["startIndex"] as? NSNumber)?.intValue,
                          let endIndex = (segmentObject["endIndex"] as? NSNumber)?.intValue,
                          startIndex >= 0, endIndex >= startIndex else { continue }
                    var part: [CLLocationCoordinate2D] = []
                    for (position, original) in validIndexes.enumerated()
                    where original >= startIndex && original <= endIndex {
                        part.append(validPoints[position])
                    }
                    if !part.isEmpty {
                        self.pathSegments.append(part)
                    }
                }
            }
            if self.pathSegments.isEmpty {
                self.pathSegments.append(validPoints)
            }

            guard self.ensureLineAnnotationManager() else {
                self.sendError("Polyline annotation manager is not available.", command)
                return
            }

            // Clear any existing path annotations
            self.lineAnnotationManager?.annotations.removeAll()
            self.pathAnnotations.removeAll()
            self.currentSegmentAnnotation = nil

            self.drawSegmentAnnotations()

            self.sendSuccess([
                "status": "loaded",
                "pointCount": self.pathPoints.count,
                "segmentCount": self.pathSegments.count
            ], command)
        }
    }

    @objc(clearPaths:)
    func clearPaths(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            self.lineAnnotationManager?.annotations.removeAll()
            self.pathAnnotations.removeAll()
            self.currentSegmentAnnotation = nil
            self.pathPoints.removeAll()
            // Segment indices returned by stopPathTracking must match the points.
            self.pathSegments.removeAll()
            self.currentSegment.removeAll()
            self.sendSuccess(command)
        }
    }

    @objc(setPathVisibility:)
    func setPathVisibility(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let visible = self.boolOption(options["visible"], defaultValue: true)
            let wasVisible = self.isPathVisible

            self.isPathVisible = visible

            if !visible {
                // Hide: remove all annotations from map
                self.lineAnnotationManager?.annotations.removeAll()
                self.pathAnnotations.removeAll()
                self.currentSegmentAnnotation = nil
            } else {
                // Show: bring back the finished segments (only if they were hidden, so a
                // repeated call does not stack duplicates), then the live segment.
                if !wasVisible {
                    self.drawSegmentAnnotations()
                }
                self.updatePathAnnotation()
            }

            self.sendSuccess(command)
        }
    }

    @objc(downloadOfflineRegion:)
    func downloadOfflineRegion(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        sendOfflineProgress(phase: "started", completed: 0, required: 100)
        runForSession {
            self.sendOfflineProgress(phase: "native-entered", completed: 0, required: 100)

            guard self.mapView != nil else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }

            // Optional area (bounds or GeoJSON polygon) instead of centre + radius.
            let area: Polygon?
            do {
                area = try self.offlineAreaPolygon(options)
            } catch let error as OfflineAreaError {
                self.sendError(error.message, command)
                return
            } catch {
                self.sendError("Invalid offline area.", command)
                return
            }

            var latitude = self.doubleOption(options["latitude"], defaultValue: 0)
            var longitude = self.doubleOption(options["longitude"], defaultValue: 0)
            if let area = area {
                let box = self.polygonBounds(area)
                latitude = (box.south + box.north) / 2
                longitude = (box.west + box.east) / 2
            }

            guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }

            let radiusKm = area != nil ? 0 : self.doubleOption(options["radiusKm"], defaultValue: 10)
            guard let minZoom = MapboxSecurity.zoom(self.doubleOption(options["minZoom"], defaultValue: 10)),
                  let maxZoom = MapboxSecurity.zoom(self.doubleOption(options["maxZoom"], defaultValue: 16)), minZoom <= maxZoom else {
                self.sendError("Offline zoom must be between 2 and 18 with minZoom <= maxZoom.", command); return
            }
            let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
            guard self.styleAllowed(styleUrl) else {
                self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
                return
            }
            let defaultRegionId = area != nil
                ? "offline-area-\(Int(Date().timeIntervalSince1970 * 1000))"
                : "offline-\(Int(latitude * 100000))-\(Int(longitude * 100000))"
            let regionId = options["regionId"] as? String ?? defaultRegionId

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
                geometry: area?.geometry,
                wifiOnly: self.boolOption(options["wifiOnly"], defaultValue: false),
                command: command
            )
        }
    }

    @objc(downloadOfflineRegionForRect:)
    func downloadOfflineRegionForRect(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        sendOfflineProgress(phase: "started", completed: 0, required: 100)
        runForSession {
            self.sendOfflineProgress(phase: "native-entered", completed: 0, required: 100)

            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let nativeX = self.doubleOption(options["x"], defaultValue: 0)
            let nativeY = self.doubleOption(options["y"], defaultValue: 0)
            let nativeWidth = self.doubleOption(options["width"], defaultValue: 1)
            let nativeHeight = self.doubleOption(options["height"], defaultValue: 1)
            guard [nativeX, nativeY, nativeWidth, nativeHeight].allSatisfy({
                $0.isFinite && abs($0) <= 1000000
            }), nativeWidth > 0, nativeHeight > 0 else {
                self.sendError("Invalid offline rectangle.", command); return
            }
            let scale = Double(UIScreen.main.scale)
            let x = nativeX / scale
            let y = nativeY / scale
            let width = nativeWidth / scale
            let height = nativeHeight / scale
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
                wifiOnly: self.boolOption(options["wifiOnly"], defaultValue: false),
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
        wifiOnly: Bool,
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
        // A cancelled download's late Mapbox callbacks are ignored by token.
        offlineDownloadToken &+= 1
        let downloadToken = offlineDownloadToken
        activeDownloadCommand = command
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
        // Cap the number of stored regions so offline storage cannot grow without limit.
        // Re-downloading an existing region always works; fail explicitly if stores cannot be read.
        let stores: [OfflineStoreEntry]
        do {
            stores = try offlineRegionStores()
        } catch {
            isOfflineDownloading = false
            sendError(sanitizeError(contextMessage: "Failed to read offline regions.", error: error), command)
            return
        }
        loadOfflineRegions(stores) { stored, error in
            self.runForDownload(downloadGeneration, downloadToken) {
                guard let stored = stored, error == nil else {
                    self.isOfflineDownloading = false
                    self.sendError(error ?? "Failed to read offline regions.", command)
                    return
                }
                if stored.count >= self.maxOfflineRegions && stored[regionId] == nil {
                    self.isOfflineDownloading = false
                    self.sendError("Offline region limit reached: delete a region before downloading another (maximum \(self.maxOfflineRegions)).", command)
                    return
                }
                self.beginOfflineDownload(
                    downloadGeneration: downloadGeneration,
                    downloadToken: downloadToken,
                    regionId: regionId,
                    latitude: latitude,
                    longitude: longitude,
                    boundedRadiusKm: boundedRadiusKm,
                    boundedMinZoom: boundedMinZoom,
                    boundedMaxZoom: boundedMaxZoom,
                    styleURI: styleURI,
                    // Final area (circle already built) so the result reports exactly what was downloaded.
                    geometry: regionGeometry,
                    wifiOnly: wifiOnly,
                    command: command
                )
            }
        }
    }

    private func beginOfflineDownload(
        downloadGeneration: UInt64,
        downloadToken: UInt64,
        regionId: String,
        latitude: Double,
        longitude: Double,
        boundedRadiusKm: Double,
        boundedMinZoom: UInt8,
        boundedMaxZoom: UInt8,
        styleURI: StyleURI,
        geometry: Geometry?,
        wifiOnly: Bool,
        command: CDVInvokedUrlCommand
    ) {
        cancelCurrentDownload()
        let regionStore: TileStore
        let offlineManager: OfflineManager
        do {
            try setOfflineRegionComplete(regionId, complete: false)
            regionStore = try offlineRegionTileStore(regionId)
            let dataPath = try offlineRegionDataPath(regionId)
            let previousTileStore = MapboxMapsOptions.tileStore
            let previousDataPath = MapboxMapsOptions.dataPath
            MapboxMapsOptions.tileStore = regionStore
            MapboxMapsOptions.dataPath = dataPath
            offlineManager = OfflineManager()
            MapboxMapsOptions.tileStore = previousTileStore
            MapboxMapsOptions.dataPath = previousDataPath
            activeOfflineDownloadStore = regionStore
        } catch {
            isOfflineDownloading = false
            sendError(sanitizeError(contextMessage: "Failed to prepare isolated offline storage.", error: error), command)
            return
        }
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
            self.runForDownload(downloadGeneration, downloadToken) {
                self.sendOfflineProgress(
                    phase: "style",
                    completed: UInt64(progress.completedResourceCount),
                    required: UInt64(progress.requiredResourceCount),
                    completedBytes: Int64(progress.completedResourceSize)
                )
            }
        } completion: { result in
            self.runForDownload(downloadGeneration, downloadToken) {
                switch result {
                case .success:
                    self.sendOfflineProgress(phase: "tiles-start", completed: 0, required: 100)
                    self.downloadOfflineTiles(
                        offlineManager: offlineManager,
                        downloadGeneration: downloadGeneration,
                        downloadToken: downloadToken,
                        regionId: regionId,
                        latitude: latitude,
                        longitude: longitude,
                        radiusKm: boundedRadiusKm,
                        minZoom: boundedMinZoom,
                        maxZoom: boundedMaxZoom,
                        styleURI: styleURI,
                        geometry: geometry,
                        wifiOnly: wifiOnly,
                        regionStore: regionStore,
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
        downloadToken: UInt64,
        regionId: String,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minZoom: UInt8,
        maxZoom: UInt8,
        styleURI: StyleURI,
        geometry: Geometry? = nil,
        wifiOnly: Bool = false,
        regionStore: TileStore,
        command: CDVInvokedUrlCommand
    ) {
        guard downloadGeneration == sessionGeneration, downloadToken == offlineDownloadToken else { return }
        let descriptorOptions = TilesetDescriptorOptions(
            styleURI: styleURI,
            zoomRange: minZoom...maxZoom,
            tilesets: nil
        )
        let descriptor = offlineManager.createTilesetDescriptor(for: descriptorOptions)
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let polygon = Polygon(center: center, radius: radiusKm * 1000.0, vertices: 64)
        let area = geometry ?? polygon.geometry

        guard let loadOptions = TileRegionLoadOptions(
            geometry: area,
            descriptors: [descriptor],
            // Style and zooms are saved so showOfflineRegion can reopen the region by id.
            metadata: [
                "regionId": regionId,
                "styleUrl": styleURI.rawValue,
                "minZoom": Int(minZoom),
                "maxZoom": Int(maxZoom)
            ],
            acceptExpired: false,
            // wifiOnly: never use mobile data (or other metered networks) for tiles.
            networkRestriction: wifiOnly ? .disallowExpensive : .none
        ) else {
            isOfflineDownloading = false
            sendError("Failed to create tile region options.", command)
            return
        }

        activeTileRegionDownload = regionStore.loadTileRegion(
            forId: regionId,
            loadOptions: loadOptions
        ) { progress in
            self.runForDownload(downloadGeneration, downloadToken) {
                self.sendOfflineProgress(
                    phase: "tiles",
                    completed: UInt64(progress.completedResourceCount),
                    required: UInt64(progress.requiredResourceCount),
                    completedBytes: Int64(progress.completedResourceSize)
                )
            }
        } completion: { result in
            self.runForDownload(downloadGeneration, downloadToken) {
                self.isOfflineDownloading = false
                switch result {
                case .success(let region):
                    do {
                        try self.setOfflineRegionComplete(regionId, complete: true)
                        self.sendSuccess(self.offlineDownloadResult(
                            regionId: regionId,
                            latitude: latitude,
                            longitude: longitude,
                            radiusKm: radiusKm,
                            minZoom: minZoom,
                            maxZoom: maxZoom,
                            styleURI: styleURI,
                            area: area,
                            sizeBytes: region.completedResourceSize
                        ), command)
                    } catch {
                        self.sendError(self.sanitizeError(contextMessage: "Failed to save offline region state.", error: error), command)
                    }
                case .failure(let error):
                    self.sendError(self.sanitizeError(contextMessage: "Failed to download tile region.", error: error), command)
                }
            }
        }
    }

    // Like runForGeneration, but also dropped once the download was cancelled or replaced.
    private func runForDownload(_ generation: UInt64, _ downloadToken: UInt64, _ work: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.sessionGeneration == generation,
                  self.offlineDownloadToken == downloadToken else { return }
            work()
        }
    }

    // Default when the app has no measured value; real sizes vary a lot by style and area.
    private let defaultBytesPerTile: Double = 50 * 1024
    private let maxBytesPerTile: Double = 10 * 1024 * 1024

    /// Approximate download size for the same options as downloadOfflineRegion
    /// (centre + radiusKm, bounds or polygon). Counts tiles over the area's bounding box,
    /// so circles and polygons are over-estimated.
    @objc(estimateOfflineRegionSize:)
    func estimateOfflineRegionSize(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let area: Polygon
            do {
                if let given = try self.offlineAreaPolygon(options) {
                    area = given
                } else {
                    let latitude = self.doubleOption(options["latitude"], defaultValue: 0)
                    let longitude = self.doubleOption(options["longitude"], defaultValue: 0)
                    let radiusKm = self.doubleOption(options["radiusKm"], defaultValue: 10)
                    guard self.isValidLatitude(latitude), self.isValidLongitude(longitude) else {
                        self.sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                        return
                    }
                    guard radiusKm.isFinite, radiusKm >= 0, radiusKm <= self.maxOfflineRadiusKm else {
                        self.sendError("Invalid offline radius.", command)
                        return
                    }
                    area = Polygon(
                        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        radius: radiusKm * 1000.0,
                        vertices: 64
                    )
                }
            } catch let error as OfflineAreaError {
                self.sendError(error.message, command)
                return
            } catch {
                self.sendError("Invalid offline area.", command)
                return
            }
            self.sendOfflineEstimate(area: area, options: options, command: command)
        }
    }

    /// Same as estimateOfflineRegionSize for the on-screen rectangle used by
    /// downloadOfflineRegionForRect (native pixels, like the download).
    @objc(estimateOfflineRegionSizeForRect:)
    func estimateOfflineRegionSizeForRect(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }
            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }
            let nativeX = self.doubleOption(options["x"], defaultValue: 0)
            let nativeY = self.doubleOption(options["y"], defaultValue: 0)
            let nativeWidth = self.doubleOption(options["width"], defaultValue: 1)
            let nativeHeight = self.doubleOption(options["height"], defaultValue: 1)
            guard [nativeX, nativeY, nativeWidth, nativeHeight].allSatisfy({
                $0.isFinite && abs($0) <= 1000000
            }), nativeWidth > 0, nativeHeight > 0 else {
                self.sendError("Invalid offline rectangle.", command); return
            }
            let scale = Double(UIScreen.main.scale)
            let x = nativeX / scale
            let y = nativeY / scale
            let width = nativeWidth / scale
            let height = nativeHeight / scale
            let topLeft = mapView.mapboxMap.coordinate(for: CGPoint(x: x, y: y))
            let topRight = mapView.mapboxMap.coordinate(for: CGPoint(x: x + width, y: y))
            let bottomRight = mapView.mapboxMap.coordinate(for: CGPoint(x: x + width, y: y + height))
            let bottomLeft = mapView.mapboxMap.coordinate(for: CGPoint(x: x, y: y + height))
            let area = Polygon([[topLeft, topRight, bottomRight, bottomLeft, topLeft]])
            self.sendOfflineEstimate(area: area, options: options, command: command)
        }
    }

    private func sendOfflineEstimate(area: Polygon, options: [String: Any], command: CDVInvokedUrlCommand) {
        guard let minZoom = MapboxSecurity.zoom(doubleOption(options["minZoom"], defaultValue: 10)),
              let maxZoom = MapboxSecurity.zoom(doubleOption(options["maxZoom"], defaultValue: 16)), minZoom <= maxZoom else {
            sendError("Offline zoom must be between 2 and 18 with minZoom <= maxZoom.", command); return
        }
        let bytesPerTile = doubleOption(options["bytesPerTile"], defaultValue: defaultBytesPerTile)
        guard bytesPerTile > 0, bytesPerTile <= maxBytesPerTile else {
            sendError("bytesPerTile must be a positive number up to 10 MiB.", command); return
        }
        let box = polygonBounds(area)
        let tileCount = MapboxSecurity.estimatedTileCount(
            south: box.south, west: box.west, north: box.north, east: box.east,
            minZoom: Int(minZoom), maxZoom: Int(maxZoom)
        )
        let estimatedBytes = Int64((Double(tileCount) * bytesPerTile).rounded())
        sendSuccess([
            "tileCount": NSNumber(value: tileCount),
            "bytesPerTile": bytesPerTile,
            "estimatedBytes": NSNumber(value: estimatedBytes),
            "estimatedMB": (Double(estimatedBytes) / 1048576.0 * 10).rounded() / 10,
            "minZoom": Int(minZoom),
            "maxZoom": Int(maxZoom),
            "bounds": [
                "south": box.south,
                "west": box.west,
                "north": box.north,
                "east": box.east
            ],
            // false when the same request would be rejected by the download limits.
            "withinLimits": MapboxSecurity.offlineBounds(
                south: box.south, west: box.west, north: box.north, east: box.east, zoom: Double(maxZoom)
            )
        ], command)
    }

    @objc(getAvailableStorage:)
    func getAvailableStorage(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
            ])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            sendSuccess([
                "availableBytes": NSNumber(value: available),
                "totalBytes": NSNumber(value: values.volumeTotalCapacity ?? 0),
                "availableGB": (Double(available) / 1073741824.0 * 100).rounded() / 100
            ], command)
        } catch {
            sendError(sanitizeError(contextMessage: "Failed to read available storage.", error: error), command)
        }
    }

    @objc(cancelOfflineDownload:)
    func cancelOfflineDownload(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            let wasDownloading = self.isOfflineDownloading
            if wasDownloading {
                self.offlineDownloadToken &+= 1
                self.cancelCurrentDownload()
                self.isOfflineDownloading = false
                if let pending = self.activeDownloadCommand {
                    // JS turns this message into a MAPBOX_OPERATION_CANCELLED error.
                    self.sendError("Offline download cancelled.", pending)
                }
            }
            self.activeDownloadCommand = nil
            self.sendSuccess(["cancelled": wasDownloading], command)
        }
    }

    @objc(getOfflineRegionIds:)
    func getOfflineRegionIds(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        let stores: [OfflineStoreEntry]
        do {
            stores = try offlineRegionStores()
        } catch {
            sendError(sanitizeError(contextMessage: "Failed to read offline regions.", error: error), command)
            return
        }
        loadOfflineRegions(stores) { regions, error in
            DispatchQueue.main.async {
                if let regions = regions, error == nil {
                    let entries = Array(regions.values)
                    self.sendSuccess([
                        "regionIds": entries.map { $0.region.id },
                        "regions": entries.map { entry -> [String: Any] in
                            let region = entry.region
                            return [
                                "regionId": region.id,
                                "sizeBytes": NSNumber(value: region.completedResourceSize),
                                "isolated": entry.isolated,
                                // false for a download that stopped part-way.
                                "complete": region.requiredResourceCount > 0
                                    && region.completedResourceCount >= region.requiredResourceCount
                            ]
                        }
                    ], command)
                } else {
                    self.sendError(error ?? "Failed to read offline regions.", command)
                }
            }
        }
    }

    struct OfflineAreaError: Error {
        let message: String
    }

    /// Download area from `bounds` ({south, west, north, east}) or a GeoJSON `polygon`.
    /// Returns nil when neither is given; throws a user-facing message when invalid.
    private func offlineAreaPolygon(_ options: [String: Any]) throws -> Polygon? {
        let boundsValue: Any? = options["bounds"] is NSNull ? nil : options["bounds"]
        let polygonValue: Any? = options["polygon"] is NSNull ? nil : options["polygon"]
        if boundsValue != nil && polygonValue != nil {
            throw OfflineAreaError(message: "Pass either bounds or polygon, not both.")
        }
        if let value = boundsValue {
            guard let bounds = value as? [String: Any] else {
                throw OfflineAreaError(message: "bounds must be an object with south, west, north and east.")
            }
            let south = doubleOption(bounds["south"], defaultValue: .nan)
            let west = doubleOption(bounds["west"], defaultValue: .nan)
            let north = doubleOption(bounds["north"], defaultValue: .nan)
            let east = doubleOption(bounds["east"], defaultValue: .nan)
            guard isValidLatitude(south), isValidLatitude(north),
                  isValidLongitude(west), isValidLongitude(east) else {
                throw OfflineAreaError(message: "Invalid offline bounds: latitudes must be in [-90, 90], longitudes in [-180, 180].")
            }
            guard south < north, west < east else {
                throw OfflineAreaError(message: "Invalid offline bounds: south must be less than north and west less than east.")
            }
            return Polygon([[
                CLLocationCoordinate2D(latitude: south, longitude: west),
                CLLocationCoordinate2D(latitude: south, longitude: east),
                CLLocationCoordinate2D(latitude: north, longitude: east),
                CLLocationCoordinate2D(latitude: north, longitude: west),
                CLLocationCoordinate2D(latitude: south, longitude: west)
            ]])
        }
        if let value = polygonValue {
            guard let polygon = value as? [String: Any],
                  polygon["type"] as? String == "Polygon",
                  let rings = polygon["coordinates"] as? [Any], !rings.isEmpty else {
                throw OfflineAreaError(message: "polygon must be a GeoJSON Polygon with coordinates.")
            }
            var out: [[CLLocationCoordinate2D]] = []
            var total = 0
            for ringValue in rings {
                guard let ring = ringValue as? [Any] else {
                    throw OfflineAreaError(message: "Each polygon ring must be an array of [longitude, latitude] positions.")
                }
                var points: [CLLocationCoordinate2D] = []
                for positionValue in ring {
                    let position = positionValue as? [Any] ?? []
                    let lng = position.count >= 2 ? doubleOption(position[0], defaultValue: .nan) : .nan
                    let lat = position.count >= 2 ? doubleOption(position[1], defaultValue: .nan) : .nan
                    guard isValidLongitude(lng), isValidLatitude(lat) else {
                        throw OfflineAreaError(message: "Invalid polygon position: use [longitude, latitude] within valid ranges.")
                    }
                    points.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
                }
                guard let first = points.first, let last = points.last else {
                    throw OfflineAreaError(message: "Each polygon ring needs at least 3 positions.")
                }
                if first.latitude != last.latitude || first.longitude != last.longitude {
                    points.append(first)
                }
                guard points.count >= 4 else {
                    throw OfflineAreaError(message: "Each polygon ring needs at least 3 positions.")
                }
                total += points.count
                guard total <= maxOfflinePolygonPoints else {
                    throw OfflineAreaError(message: "Polygon has too many positions (maximum \(maxOfflinePolygonPoints)).")
                }
                out.append(points)
            }
            return Polygon(out)
        }
        return nil
    }

    private func polygonBounds(_ polygon: Polygon) -> (south: Double, west: Double, north: Double, east: Double) {
        let points = polygon.coordinates.flatMap { $0 }
        return (
            south: points.map { $0.latitude }.min() ?? 0,
            west: points.map { $0.longitude }.min() ?? 0,
            north: points.map { $0.latitude }.max() ?? 0,
            east: points.map { $0.longitude }.max() ?? 0
        )
    }

    private func offlineDownloadResult(
        regionId: String,
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        minZoom: UInt8,
        maxZoom: UInt8,
        styleURI: StyleURI,
        area: Geometry,
        sizeBytes: UInt64
    ) -> [String: Any] {
        var rings: [[CLLocationCoordinate2D]] = []
        if case .polygon(let polygon) = area {
            rings = polygon.coordinates
        }
        let box = polygonBounds(Polygon(rings))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "regionId": regionId,
            "latitude": latitude,
            "longitude": longitude,
            "radiusKm": radiusKm,
            // Tile data only; the region's style pack is not included.
            "sizeBytes": NSNumber(value: sizeBytes),
            "bounds": [
                "south": box.south,
                "west": box.west,
                "north": box.north,
                "east": box.east
            ],
            "polygon": [
                "type": "Polygon",
                "coordinates": rings.map { ring in ring.map { [$0.longitude, $0.latitude] } }
            ],
            "minZoom": Int(minZoom),
            "maxZoom": Int(maxZoom),
            "styleUrl": styleURI.rawValue,
            "downloadedAt": formatter.string(from: Date())
        ]
    }

    @objc(showOfflineRegion:)
    func showOfflineRegion(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let options = command.argument(at: 0) as? [String: Any] ?? [:]
            guard self.validInput(options, command) else { return }

            let regionId = (options["regionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !regionId.isEmpty {
                self.showDownloadedRegion(regionId: regionId, options: options, command: command)
                return
            }

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
            guard self.restoreInitialCameraBounds(command) else { return }

            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                zoom: zoom
            ))
            self.loadReadyStyle(styleURI, status: nil, command: command)
        }
    }

    /// Opens a region downloaded on this device: reads its outline and saved style and
    /// zooms from the tile store, centres on it and fits it on screen, then loads the
    /// style it was downloaded with. latitude, longitude, zoom and styleUrl in options
    /// override the saved values; styleUrl is only used when the region has none saved
    /// (regions downloaded by older versions).
    private func showDownloadedRegion(regionId: String, options: [String: Any], command: CDVInvokedUrlCommand) {
        guard regionId.utf8.count <= 256 else {
            sendError("Invalid region id.", command); return
        }
        guard pendingStyle == nil else {
            sendError("A style load is already in progress. Await its completion first.", command)
            return
        }
        let generation = sessionGeneration
        let regionStore: TileStore
        if self.activeOfflineRegionId == regionId, let activeStore = self.activeOfflineRegionStore {
            regionStore = activeStore
        } else if self.isOfflineRegionMarkedComplete(regionId) {
            self.sendError("Open this isolated region with initializeOffline.", command)
            return
        } else {
            regionStore = TileStore.default
        }
        regionStore.tileRegionGeometry(forId: regionId) { geometryResult in
            self.runForGeneration(generation) {
                guard case .success(let geometry) = geometryResult,
                      let box = self.geometryBounds(geometry) else {
                    self.sendError("Offline region '\(regionId)' is not downloaded on this device.", command)
                    return
                }
                regionStore.tileRegionMetadata(forId: regionId) { metadataResult in
                    self.runForGeneration(generation) {
                        var metadata: [String: Any] = [:]
                        if case .success(let value) = metadataResult, let dictionary = value as? [String: Any] {
                            metadata = dictionary
                        }
                        self.openDownloadedRegion(box: box, metadata: metadata, options: options, command: command)
                    }
                }
            }
        }
    }

    private func geometryCoordinates(_ geometry: Geometry) -> [CLLocationCoordinate2D] {
        switch geometry {
        case .point(let point): return [point.coordinates]
        case .lineString(let line): return line.coordinates
        case .polygon(let polygon): return polygon.coordinates.flatMap { $0 }
        case .multiPolygon(let multi): return multi.coordinates.flatMap { $0.flatMap { $0 } }
        case .geometryCollection(let collection): return collection.geometries.flatMap { geometryCoordinates($0) }
        default: return []
        }
    }

    /// Bounds of a stored region outline, or nil when it has no points.
    private func geometryBounds(_ geometry: Geometry) -> (south: Double, west: Double, north: Double, east: Double)? {
        let points = geometryCoordinates(geometry)
        guard let south = points.map({ $0.latitude }).min(),
              let north = points.map({ $0.latitude }).max(),
              let west = points.map({ $0.longitude }).min(),
              let east = points.map({ $0.longitude }).max() else { return nil }
        return (south: south, west: west, north: north, east: east)
    }

    /// Zoom at which the box fills about 90% of a view of the given size in points
    /// (the map's world is 512 points wide at zoom 0). Same formula as Android (dp).
    static func fitZoom(south: Double, west: Double, north: Double, east: Double,
                        viewWidth: Double, viewHeight: Double) -> Double {
        func mercatorY(_ latitude: Double) -> Double {
            let rad = max(-85.0511, min(85.0511, latitude)) * Double.pi / 180
            return (1 - log(tan(rad) + 1 / cos(rad)) / Double.pi) / 2
        }
        let spanX = (east - west) / 360
        let spanY = abs(mercatorY(south) - mercatorY(north))
        let zoomX = spanX > 0 ? log2(viewWidth * 0.9 / (512 * spanX)) : Double.infinity
        let zoomY = spanY > 0 ? log2(viewHeight * 0.9 / (512 * spanY)) : Double.infinity
        return min(zoomX, zoomY)
    }

    private func restoreInitialCameraBounds(_ command: CDVInvokedUrlCommand) -> Bool {
        guard offlineRegionCameraBoundsActive, let mapView = mapView else { return true }
        do {
            try mapView.mapboxMap.setCameraBounds(with: CameraBoundsOptions(
                bounds: CoordinateBounds.world,
                maxZoom: initialCameraMaxZoom,
                minZoom: initialCameraMinZoom
            ))
        } catch {
            sendError("Failed to restore camera bounds: \(error.localizedDescription)", command)
            return false
        }
        offlineRegionCameraBoundsActive = false
        return true
    }

    private func openDownloadedRegion(
        box: (south: Double, west: Double, north: Double, east: Double),
        metadata: [String: Any],
        options: [String: Any],
        command: CDVInvokedUrlCommand
    ) {
        guard let mapView = mapView else { sendError("Map is not initialized.", command); return }

        let savedStyle = (metadata["styleUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let styleUrl = savedStyle ?? options["styleUrl"] as? String ?? StyleURI.streets.rawValue
        guard styleAllowed(styleUrl), let styleURI = StyleURI(rawValue: styleUrl) else {
            sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
            return
        }

        var latitude = (box.south + box.north) / 2
        var longitude = (box.west + box.east) / 2
        if options["latitude"] != nil && options["longitude"] != nil {
            latitude = doubleOption(options["latitude"], defaultValue: .nan)
            longitude = doubleOption(options["longitude"], defaultValue: .nan)
            guard isValidLatitude(latitude), isValidLongitude(longitude) else {
                sendError("Invalid coordinates: latitude must be in [-90, 90], longitude in [-180, 180].", command)
                return
            }
        }

        // Keep the camera within downloaded zooms; geography remains world-wide.
        let savedMinZoom = (metadata["minZoom"] as? NSNumber)?.doubleValue ?? Double(minOfflineZoom)
        let savedMaxZoom = (metadata["maxZoom"] as? NSNumber)?.doubleValue ?? Double(maxOfflineZoom)
        let configuredMinZoom = initialCameraMinZoom.map { Double($0) } ?? Double(minOfflineZoom)
        let configuredMaxZoom = initialCameraMaxZoom.map { Double($0) } ?? Double(maxOfflineZoom)
        let minZoom = Swift.max(savedMinZoom, configuredMinZoom)
        let maxZoom = Swift.min(savedMaxZoom, configuredMaxZoom)
        guard minZoom <= maxZoom else {
            sendError("Offline region zoom range conflicts with map camera limits.", command)
            return
        }
        var zoom: Double
        if options["zoom"] != nil {
            zoom = doubleOption(options["zoom"], defaultValue: 13)
        } else {
            // Before the first layout the view can be 0 x 0; use the screen size then.
            let size = mapView.bounds.width > 0 && mapView.bounds.height > 0
                ? mapView.bounds.size : UIScreen.main.bounds.size
            zoom = MapboxPlugin.fitZoom(
                south: box.south, west: box.west, north: box.north, east: box.east,
                viewWidth: Double(size.width), viewHeight: Double(size.height)
            )
        }
        zoom = Swift.max(minZoom, Swift.min(maxZoom, zoom))

        do {
            try mapView.mapboxMap.setCameraBounds(with: CameraBoundsOptions(
                bounds: CoordinateBounds.world,
                maxZoom: CGFloat(maxZoom),
                minZoom: CGFloat(minZoom)
            ))
        } catch {
            sendError("Failed to set world camera bounds for offline map: \(error.localizedDescription)", command)
            return
        }
        offlineRegionCameraBoundsActive = true

        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            zoom: zoom
        ))
        self.loadReadyStyle(styleURI, status: nil, command: command)
    }

    @objc(deleteOfflineRegion:)
    func deleteOfflineRegion(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        guard self.validInput(options, command) else { return }
        let regionId = (options["regionId"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let styleUrl = options["styleUrl"] as? String ?? StyleURI.streets.rawValue
        guard self.styleAllowed(styleUrl) else {
            self.sendError("Style URL is not allowed. Use a Mapbox style or an approved HTTPS host.", command)
            return
        }
        // Keep this region's style pack unless explicitly asked to delete it.
        let deleteStylePack = options["deleteStylePack"] as? Bool ?? false

        guard !regionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sendError("regionId is required.", command)
            return
        }

        let legacyStore = TileStore.default
        let isolatedStore = existingOfflineRegionTileStore(regionId)
        legacyStore.removeTileRegion(forId: regionId)
        isolatedStore?.removeTileRegion(forId: regionId)
        do {
            try setOfflineRegionComplete(regionId, complete: false)
        } catch {
            sendError(sanitizeError(contextMessage: "Failed to update offline region state.", error: error), command)
            return
        }

        if deleteStylePack, let styleURI = StyleURI(rawValue: styleUrl) {
            let previousTileStore = MapboxMapsOptions.tileStore
            let previousDataPath = MapboxMapsOptions.dataPath
            let offlineManager: OfflineManager
            do {
                if let isolatedStore = isolatedStore {
                    MapboxMapsOptions.tileStore = isolatedStore
                    MapboxMapsOptions.dataPath = try offlineRegionDataPath(regionId)
                }
                offlineManager = OfflineManager()
            } catch {
                MapboxMapsOptions.tileStore = previousTileStore
                MapboxMapsOptions.dataPath = previousDataPath
                sendError(sanitizeError(contextMessage: "Failed to prepare offline style deletion.", error: error), command)
                return
            }
            MapboxMapsOptions.tileStore = previousTileStore
            MapboxMapsOptions.dataPath = previousDataPath
            offlineManager.removeStylePack(for: styleURI)
        }

        sendSuccess(command)
    }

    @objc(setWaypointSelectionEnabled:)
    func setWaypointSelectionEnabled(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        let options = command.argument(at: 0) as? [String: Any] ?? [:]
        guard self.validInput(options, command) else { return }
        waypointSelectionEnabled = options["enabled"] as? Bool ?? true
        autoAddWaypointMarker = options["autoAddMarker"] as? Bool ?? false
        sendSuccess(command)
    }

    @objc(registerWaypointSelectedCallback:)
    func registerWaypointSelectedCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        waypointSelectedCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerMarkerClickCallback:)
    func registerMarkerClickCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        markerClickCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerMapTapCallback:)
    func registerMapTapCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        mapTapCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerBoundaryAreaCallback:)
    func registerBoundaryAreaCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        boundaryAreaCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerOfflineDownloadProgressCallback:)
    func registerOfflineDownloadProgressCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        offlineDownloadProgressCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
    }

    @objc(registerTrackingStatusCallback:)
    func registerTrackingStatusCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        trackingStatusCallbackId = command.callbackId
        sendNoResultKeepCallback(command)
        fireTrackingStatusChanged()
    }

    @objc(registerCompassCallback:)
    func registerCompassCallback(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        compassCallbackId = command.callbackId
        sendNoResultKeepCallback(command)

        startCompassCameraListener()
    }

    private func startCompassCameraListener() {
        guard let mapView = mapView else {
            return
        }

        compassSubscription?.cancel()
        let generation = sessionGeneration
        let cancellable = mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            guard let self = self, self.sessionGeneration == generation, self.mapView === mapView else {
                return
            }

            let bearing = mapView.cameraState.bearing

            let normalizedBearing = ((bearing.truncatingRemainder(dividingBy: 360.0)) + 360.0)
                .truncatingRemainder(dividingBy: 360.0)

            let distanceFromNorth = min(
                normalizedBearing,
                360.0 - normalizedBearing
            )

            let visible = distanceFromNorth > 1.0

            let bearingChanged: Bool

            if self.lastCompassBearing < 0 {
                bearingChanged = true
            } else {
                bearingChanged =
                    abs(self.shortestBearingDelta(
                        from: self.lastCompassBearing,
                        to: normalizedBearing
                    )) >= 0.5
            }

            let visibilityChanged = visible != self.lastCompassVisible

            guard bearingChanged || visibilityChanged else {
                return
            }

            self.lastCompassBearing = normalizedBearing
            self.lastCompassVisible = visible

            self.sendKeepCallback(
                self.compassCallbackId,
                payload: [
                    "bearing": normalizedBearing,
                    "visible": visible
                ]
            )
        }

        compassSubscription = cancellable
    }

    private func fireTrackingStatusChanged() {
        sendKeepCallback(trackingStatusCallbackId, payload: [
            "userLocation": isUserLocationEnabled,
            "userTracking": isUserTrackingEnabled,
            "deviceHeading": isDeviceHeadingEnabled,
            "headingFollowMode": isHeadingFollowModeEnabled
        ])
    }

    /// completedBytes is -1 when unknown (start/setup phases).
    private func sendOfflineProgress(phase: String, completed: UInt64, required: UInt64, completedBytes: Int64 = -1) {
        let percent = required > 0 ? Int(round((Double(completed) * 100.0) / Double(required))) : 0
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackOfflineTs >= callbackRateLimit else { return }
        lastKeepCallbackOfflineTs = now
        var payload: [String: Any] = [
            "type": "offlineDownloadProgress",
            "phase": phase,
            "completed": completed,
            "required": required,
            "percent": percent
        ]
        if completedBytes >= 0 {
            payload["completedBytes"] = NSNumber(value: completedBytes)
            payload["completedMB"] = (Double(completedBytes) / 1048576.0 * 10).rounded() / 10
        }
        sendKeepCallback(offlineDownloadProgressCallbackId, payload: payload)
    }

    private func installMapTapHandler(on mapView: MapView) {
        cancelables.forEach { $0.cancel() }
        cancelables.removeAll()
        let generation = sessionGeneration
        mapView.gestures.onMapTap.observe { [weak self] context in
            guard let self = self, self.sessionGeneration == generation else {
                return
            }

            if self.isBoundaryDrawing {
                self.addBoundaryDrawingPoint(context.coordinate)
                return
            }

            self.sendMapTap(context.coordinate)

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

    private func sendMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard mapTapCallbackId != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackMapTapTs >= callbackRateLimit else { return }
        lastKeepCallbackMapTapTs = now
        sendKeepCallback(mapTapCallbackId, payload: [
            "type": "mapTapped",
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude
        ])
    }

    private func addMarkerInternal(id: String, latitude: Double, longitude: Double, style: MarkerStyle = .default, publish: Bool = true) {
        guard !id.isEmpty, id.utf8.count <= 256,
              markers[id] != nil || markers.count < maxMarkers else { return }
        guard var manager = annotations else {
            return
        }

        var marker = PointAnnotation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
        // Every marker uses the Find (square) / Waypoint (circle) design; pinStyle "photo"
        // is still accepted from older screens but no longer selects a different pin.
        // Private markers (isPublic: false) show a lock tile instead of their image.
        // Plain location pins (no isFind) and offline markers without an image show the classic red pin.
        marker.image = !style.isPublic
            ? markerIcons.lockedPin(color: style.color, isFind: style.isFind)
            : style.classicPin
            ? markerIcons.offlinePin(color: style.color)
            : markerIcons.pin(color: style.color, isFind: style.isFind, source: style.imageUrl)
        marker.iconAnchor = .bottom
        marker.iconSize = 0.5
        let generation = sessionGeneration
        let annotationId = marker.id
        marker.tapHandler = { [weak self, id] context in
            guard let self = self, self.sessionGeneration == generation,
                  self.markers[id]?.id == annotationId else { return true }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastKeepCallbackMarkerTs >= self.callbackRateLimit else { return true }
            self.lastKeepCallbackMarkerTs = now
            self.sendKeepCallback(self.markerClickCallbackId, payload: [
                "type": self.markerType(for: id),
                "id": id,
                "isOnline": self.markerStyles[id]?.isOnline ?? true
            ])
            return true
        }

        markers[id] = marker
        markerStyles[id] = style
        if publish { manager.annotations = Array(markers.values) }
        annotations = manager

        if let imageUrl = style.imageUrl, !markerIcons.hasImage(imageUrl) {
            requestMarkerImage(id: id, imageUrl: imageUrl)
        }
    }

    /// Returns nil when imageUrl is not an allowed image source.
    /// findGiven is false when the caller sent no isFind / IsFind at all: a plain location pin
    /// (for example a searched place), not a Find or Waypoint.
    private func markerStyle(isFind: Bool, pinColor: Any?, imageUrl rawImageUrl: Any?, pinStyle: Any? = nil, isOnline: Bool = true, isPublic: Bool = true, findGiven: Bool = true) -> MarkerStyle? {
        let photo = (pinStyle as? String) == "photo"
        let trimmedUrl = (rawImageUrl as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Classic red teardrop: public, no image, and either offline or a plain location pin.
        let classicPin = isPublic && trimmedUrl.isEmpty && (!isOnline || !findGiven)
        let defaultColor = classicPin ? MarkerIcons.offlinePinColor
            : isFind ? MarkerIcons.findPinColor : MarkerIcons.defaultPinColor
        let color = colorOption(pinColor, defaultColor: defaultColor)
        if !isPublic {
            // Private markers show the lock tile; their image is never validated or downloaded.
            return MarkerStyle(color: color, isFind: isFind, imageUrl: nil, photo: photo, isOnline: isOnline, isPublic: false)
        }
        let imageUrl = (rawImageUrl as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if imageUrl.isEmpty {
            return MarkerStyle(color: color, isFind: isFind, imageUrl: nil, photo: photo, isOnline: isOnline, classicPin: classicPin)
        }
        guard MapboxSecurity.markerImageAllowed(imageUrl, hosts: preferenceValue("MAPBOX_ALLOWED_MARKER_IMAGE_HOSTS")) else {
            return nil
        }
        return MarkerStyle(color: color, isFind: isFind, imageUrl: imageUrl, photo: photo, isOnline: isOnline)
    }

    // Markers show a plain pin until their image arrives; one download serves every marker using it.
    private func requestMarkerImage(id: String, imageUrl: String) {
        if pendingMarkerImages[imageUrl] != nil {
            pendingMarkerImages[imageUrl]?.append(id)
            return
        }
        pendingMarkerImages[imageUrl] = [id]

        let generation = sessionGeneration
        markerIcons.load(imageUrl, hosts: preferenceValue("MAPBOX_ALLOWED_MARKER_IMAGE_HOSTS")) { [weak self] image in
            self?.runForGeneration(generation) {
                self?.applyMarkerImage(imageUrl, image: image)
            }
        }
    }

    private func applyMarkerImage(_ imageUrl: String, image: UIImage?) {
        guard let ids = pendingMarkerImages.removeValue(forKey: imageUrl), let image = image else { return }

        var changed = false
        for id in ids {
            guard var marker = markers[id], let style = markerStyles[id], style.imageUrl == imageUrl else { continue }
            marker.image = markerIcons.pin(color: style.color, isFind: style.isFind, source: imageUrl, image: image)
            markers[id] = marker
            changed = true
        }
        if changed { annotations?.annotations = Array(markers.values) }
    }

    private func clearMarkersInternal() {
        markers.removeAll()
        markerStyles.removeAll()
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

    private func ensureBoundaryDrawingAnnotationManagers() -> Bool {
        guard let mapView = mapView else { return false }
        if boundaryDrawingLineAnnotationManager == nil {
            boundaryDrawingLineAnnotationManager = mapView.annotations.makePolylineAnnotationManager()
        }
        if boundaryDrawingPointAnnotationManager == nil {
            boundaryDrawingPointAnnotationManager = mapView.annotations.makeCircleAnnotationManager()
        }
        if boundaryDrawingPolygonAnnotationManager == nil {
            boundaryDrawingPolygonAnnotationManager = mapView.annotations.makePolygonAnnotationManager()
        }
        return boundaryDrawingLineAnnotationManager != nil
            && boundaryDrawingPointAnnotationManager != nil
            && boundaryDrawingPolygonAnnotationManager != nil
    }

    private func addBoundaryDrawingPoint(_ coordinate: CLLocationCoordinate2D) {
        guard isBoundaryDrawing,
              ensureBoundaryDrawingAnnotationManagers() else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBoundaryDrawingTapTs >= callbackRateLimit else { return }
        lastBoundaryDrawingTapTs = now

        boundaryDrawingPoints.append(coordinate)
        redrawBoundaryDrawing()
        notifyBoundaryAreaChanged()
    }

    private func redrawBoundaryDrawing() {
        guard ensureBoundaryDrawingAnnotationManagers() else { return }

        removeActiveBoundaryDrawingLine()
        removeActiveBoundaryDrawingPointAnnotations()
        removeActiveBoundaryDrawingPolygon()

        if boundaryDrawingPoints.count >= 2 {
            var line = PolylineAnnotation(lineCoordinates: boundaryDrawingPoints)
            line.lineColor = StyleColor(colorOption("#FF0000", defaultColor: .red))
            line.lineWidth = 2.0
            boundaryDrawingLine = line
            boundaryDrawingLineAnnotationManager?.annotations.append(line)
        }

        for coordinate in boundaryDrawingPoints {
            var point = CircleAnnotation(centerCoordinate: coordinate)
            point.circleColor = StyleColor(colorOption("#FF0000", defaultColor: .red))
            point.circleRadius = 6.0
            point.circleStrokeColor = StyleColor(colorOption("#FFFFFF", defaultColor: .white))
            point.circleStrokeWidth = 2.0
            boundaryDrawingPointAnnotations.append(point)
        }
        boundaryDrawingPointAnnotationManager?.annotations =
            boundaryDrawingPointAnnotations

        if boundaryDrawingPoints.count >= 3 {
            var ring = boundaryDrawingPoints
            if let first = ring.first {
                ring.append(first)
            }
            var polygon = PolygonAnnotation(polygon: Polygon([ring]))
            polygon.fillColor = StyleColor(colorOption("#FF0000", defaultColor: .red))
            polygon.fillOpacity = 0.30
            polygon.fillOutlineColor = StyleColor(colorOption("#FF0000", defaultColor: .red))
            boundaryDrawingPolygon = polygon
            boundaryDrawingPolygonAnnotationManager?.annotations.append(polygon)
        }
    }

    private func removeActiveBoundaryDrawingLine() {
        guard let line = boundaryDrawingLine else { return }
        boundaryDrawingLineAnnotationManager?.annotations.removeAll { $0.id == line.id }
        boundaryDrawingLine = nil
    }

    private func removeActiveBoundaryDrawingPointAnnotations() {
        let pointIds = Set(boundaryDrawingPointAnnotations.map(\.id))
        boundaryDrawingPointAnnotationManager?.annotations.removeAll {
            pointIds.contains($0.id)
        }
        boundaryDrawingPointAnnotations.removeAll()
    }

    private func removeActiveBoundaryDrawingPolygon() {
        guard let polygon = boundaryDrawingPolygon else { return }
        boundaryDrawingPolygonAnnotationManager?.annotations.removeAll {
            $0.id == polygon.id
        }
        boundaryDrawingPolygon = nil
    }

    private func clearBoundaryDrawingInternal() {
        isBoundaryDrawing = false
        boundaryDrawingPoints.removeAll()
        removeActiveBoundaryDrawingLine()
        removeActiveBoundaryDrawingPointAnnotations()
        removeActiveBoundaryDrawingPolygon()
        lastBoundaryDrawingTapTs = 0
    }

    private func calculateBoundaryAreaAcres(
        _ points: [CLLocationCoordinate2D]
    ) -> Double {
        guard points.count >= 3 else { return 0 }

        let earthRadius = 6_378_137.0
        var total = 0.0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let latitude1 = current.latitude * .pi / 180
            let latitude2 = next.latitude * .pi / 180
            let longitude1 = current.longitude * .pi / 180
            let longitude2 = next.longitude * .pi / 180

            total += (longitude2 - longitude1)
                * (2 + sin(latitude1) + sin(latitude2))
        }

        let areaSquareMeters = abs(total * earthRadius * earthRadius / 2)
        return areaSquareMeters / 4046.8564224
    }

    private func notifyBoundaryAreaChanged() {
        guard boundaryAreaCallbackId != nil else { return }
        sendKeepCallback(boundaryAreaCallbackId, payload: [
            "areaAcres": calculateBoundaryAreaAcres(boundaryDrawingPoints),
            "pointCount": boundaryDrawingPoints.count
        ])
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
            "type": markerType(for: nearestId),
            "id": nearestId,
            "isOnline": markerStyles[nearestId]?.isOnline ?? true
        ])
        return true
    }

    private func markerType(for id: String) -> String {
        let isFind = markerStyles[id]?.isFind ?? false
        return isFind ? "Find" : "Waypoint"
    }

    @objc(getCamera:)
    func getCamera(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
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
        rememberCommand(command)
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
            self.loadReadyStyle(styleURI, status: "styleChanged", command: command)
        }
    }

    @objc(inspectStyleStructure:)
    func inspectStyleStructure(command: CDVInvokedUrlCommand) {
        rememberCommand(command)
        runForSession {
            guard let mapView = self.mapView else {
                self.sendError("Map is not initialized.", command)
                return
            }

            let map = mapView.mapboxMap
            guard !map.allLayerIdentifiers.isEmpty else {
                self.sendError("Style is not loaded.", command)
                return
            }

            do {
                let rootLayers = map.allLayerIdentifiers.map {
                    ["id": $0.id, "type": $0.type.rawValue]
                }
                let imports = map.styleImports.map {
                    ["id": $0.id, "type": $0.type]
                }
                guard let styleJSON = try JSONSerialization.jsonObject(
                    with: Data(map.styleJSON.utf8)
                ) as? [String: Any] else {
                    self.sendError(
                        "Style inspection failed: Style JSON is not an object.",
                        command
                    )
                    return
                }

                self.sendSuccess([
                    "rootLayerCount": rootLayers.count,
                    "rootLayers": rootLayers,
                    "importCount": imports.count,
                    "imports": imports,
                    "styleJSON": styleJSON
                ], command)
            } catch {
                self.sendError(
                    "Style inspection failed: \(error.localizedDescription)",
                    command
                )
            }
        }
    }

    private final class StyleRequest {
        let view: MapView
        let command: CDVInvokedUrlCommand
        let status: String?
        let successPayload: [String: Any]?
        var timeout: DispatchWorkItem?
        init(
            view: MapView,
            command: CDVInvokedUrlCommand,
            status: String?,
            successPayload: [String: Any]? = nil
        ) {
            self.view = view
            self.command = command
            self.status = status
            self.successPayload = successPayload
        }
    }
    private var pendingStyle: StyleRequest?

    private func cancelPendingStyle() {
        pendingStyle?.timeout?.cancel()
        pendingStyle = nil
        // closeInternal settles the registered Cordova callback.
    }

    private func finishStyle(_ request: StyleRequest, error: String?) {
        guard pendingStyle === request, mapView === request.view else { return }
        cancelPendingStyle()
        if let error = error { sendError(error, request.command) }
        else if let successPayload = request.successPayload {
            sendSuccess(successPayload, request.command)
        }
        else if let status = request.status { sendSuccess(["status": status], request.command) }
        else { sendSuccess(request.command) }
    }

    private func loadReadyStyle(_ uri: StyleURI, status: String?, command: CDVInvokedUrlCommand) {
        guard let mapView = mapView else { sendError("Map is not initialized.", command); return }
        guard pendingStyle == nil else {
            sendError("A style load is already in progress. Await its completion first.", command)
            return
        }
        let request = StyleRequest(view: mapView, command: command, status: status)
        pendingStyle = request
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let request = request else { return }
            self?.finishStyle(request, error: "Style loading timed out after 30 seconds.")
        }
        request.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        mapView.mapboxMap.loadStyle(uri) { [weak self, weak request] error in
            DispatchQueue.main.async {
                guard let request = request else { return }
                self?.finishStyle(request, error: error == nil ? nil : "Map style failed to load.")
            }
        }
    }

    func loadReadyStyleJSON(
        _ styleJSON: String,
        successPayload: [String: Any],
        command: CDVInvokedUrlCommand
    ) {
        guard let mapView = mapView else {
            sendError("Map is not initialized.", command)
            return
        }
        guard pendingStyle == nil else {
            sendError("A style load is already in progress. Await its completion first.", command)
            return
        }

        let request = StyleRequest(
            view: mapView,
            command: command,
            status: nil,
            successPayload: successPayload
        )
        pendingStyle = request
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let request = request else { return }
            self?.finishStyle(request, error: "Style loading timed out after 30 seconds.")
        }
        request.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        mapView.mapboxMap.loadStyle(styleJSON) { [weak self, weak request] error in
            DispatchQueue.main.async {
                guard let request = request else { return }
                self?.finishStyle(request, error: error == nil ? nil : "Map style failed to load.")
            }
        }
    }

    private func cancelCurrentDownload() {
        activeStylePackDownload?.cancel()
        activeTileRegionDownload?.cancel()
        activeStylePackDownload = nil
        activeTileRegionDownload = nil
        activeOfflineDownloadStore = nil
    }

    func closeInternal() {
        sessionGeneration &+= 1
        // Reconnect Mapbox networking switched off by initializeOffline.
        OfflineSwitch.shared.isMapboxStackConnected = true
        resetRecenterAnimation()
        cancelPendingStyle()
        if let id = closeCallbackId {
            closeCallbackId = nil
            sendSuccess(["closed": true], callbackId: id)
        }
        let pending = sessionCallbacks
        sessionCallbacks.removeAll()
        streamCallbacks.removeAll()
        for (id, stream) in pending {
            if stream { releaseCallback(id) }
            else { sendError("Map closed; operation cancelled.", callbackId: id) }
        }
        cancelCurrentDownload()
        markerIcons.cancelAll()
        compassSubscription?.cancel()
        compassSubscription = nil
        cancelables.forEach { $0.cancel() }
        cancelables.removeAll()
        // Detach immediately, even while SDK cancellation callbacks are draining.
        mapView?.isUserInteractionEnabled = false
        mapView?.removeFromSuperview()
        mapView?.camera.cancelAnimations()
        mapView?.gestures.panGestureRecognizer.removeTarget(self, action: #selector(pauseCameraFollowForGesture(_:)))
        mapView?.gestures.pinchGestureRecognizer.removeTarget(self, action: #selector(pauseCameraFollowForGesture(_:)))
        if let overlay = mapTouchOverlay {
            overlay.isUserInteractionEnabled = false
            for gesture in overlay.gestureRecognizers ?? [] {
                gesture.isEnabled = false
                gesture.removeTarget(self, action: nil)
                gesture.delegate = nil
                overlay.removeGestureRecognizer(gesture)
            }
            overlay.touchableRects.removeAll()
            overlay.coordinateView = nil
        }
        if let saved = savedWebViewAppearance {
            if webView.backgroundColor == UIColor.clear { webView.backgroundColor = saved.1 }
            if let scrollView = (webView as? WKWebView)?.scrollView,
               scrollView.backgroundColor == UIColor.clear {
                scrollView.backgroundColor = saved.2
            }
            if !webView.isOpaque { webView.isOpaque = saved.0 }
            savedWebViewAppearance = nil
        }
        trackingStatusCallbackId = nil
        headingLocationManager?.stopUpdatingLocation()
        headingLocationManager?.stopUpdatingHeading()
        headingLocationManager?.delegate = nil
        headingLocationManager = nil
        stopHeadingFollowMode()
        stopUserTracking()
        annotations?.annotations.removeAll()
        clearBoundariesInternal()
        clearBoundaryDrawingInternal()
        lineAnnotationManager?.annotations.removeAll()
        if let mapView = mapView {
            let managerIds = [
                annotations?.id,
                boundaryAnnotationManager?.id,
                lineAnnotationManager?.id,
                boundaryDrawingLineAnnotationManager?.id,
                boundaryDrawingPointAnnotationManager?.id,
                boundaryDrawingPolygonAnnotationManager?.id
            ]
            for id in managerIds.compactMap({ $0 }) {
                mapView.annotations.removeAnnotationManager(withId: id)
            }
        }
        markers.removeAll()
        markerStyles.removeAll()
        pendingMarkerImages.removeAll()
        annotations = nil
        boundaryAnnotationManager = nil
        lineAnnotationManager = nil
        boundaryDrawingLineAnnotationManager = nil
        boundaryDrawingPointAnnotationManager = nil
        boundaryDrawingPolygonAnnotationManager = nil
        completedBoundaryDrawingPolygons.removeAll()
        pathAnnotations.removeAll()
        currentSegmentAnnotation = nil
        pathPoints.removeAll()
        isPathTrackingActive = false
        isPathTrackingPaused = false
        pathTrackingStartTime = 0
        pathPausedTotal = 0
        pathPauseStart = 0
        isPathVisible = true
        pathLineColor = "#FF0000"
        pathLineWidth = 3.0
        pathLineOpacity = 1.0
        pathSegments.removeAll()
        currentSegment.removeAll()
        waypointSelectedCallbackId = nil
        markerClickCallbackId = nil
        mapTapCallbackId = nil
        boundaryAreaCallbackId = nil
        offlineDownloadProgressCallbackId = nil
        compassCallbackId = nil
        lastCompassBearing = -1
        lastCompassVisible = false
        trackingStatusCallbackId = nil
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
        lastKeepCallbackMapTapTs = 0
        lastBoundaryDrawingTapTs = 0
        cancelables.removeAll()
        mapTouchOverlay?.removeFromSuperview()
        mapTouchOverlay = nil
        mapView?.removeFromSuperview()
        mapView = nil
        activeOfflineRegionStore = nil
        activeOfflineRegionId = nil
    }

    @objc private func closeFromButton() {
        closeInternal()
    }

    override func dispose() {
        if Thread.isMainThread { closeInternal() }
        else { DispatchQueue.main.sync { self.closeInternal() } }
        super.dispose()
    }

    override func onAppTerminate() {
        closeInternal()
        super.onAppTerminate()
    }

    override func onReset() {
        closeInternal()
        super.onReset()
    }

    override func pluginInitialize() {
        super.pluginInitialize()
        // The plugin loads at app start (onload), so this runs even if no map is ever opened.
        clearLegacyTokenCache()
    }

    /// Erases the token cached by earlier releases. Keychain items survive app deletion,
    /// so this must not wait for a map to be initialized.
    private func clearLegacyTokenCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.outsystems.mapbox",
            kSecAttrAccount as String: "mapbox_access_token"
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func getAccessToken() -> String {
        // The bundled public token is authoritative; never read a cached copy.
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
        let scale = Double(UIScreen.main.scale)
        let x = doubleOption(options["x"], defaultValue: 0) / scale
        let y = doubleOption(options["y"], defaultValue: 0) / scale
        let width = doubleOption(
            options["width"],
            defaultValue: Double(webView.bounds.width) * scale
        ) / scale
        let height = doubleOption(
            options["height"],
            defaultValue: Double(webView.bounds.height) * scale
        ) / scale

        // Keep the map inside Metal's 16384 px texture limit and near the WebView.
        let maxSide = 16384 / scale
        func bounded(_ value: Double, _ lower: Double, _ upper: Double) -> CGFloat {
            CGFloat(min(max(value, lower), upper))
        }
        return CGRect(
            x: bounded(x, -maxSide, maxSide),
            y: bounded(y, -maxSide, maxSide),
            width: bounded(width, 1, maxSide),
            height: bounded(height, 1, maxSide)
        )
    }

    private func touchRectFromOptions(_ options: [String: Any]) -> CGRect {
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
        // Keep WebView-local points; convert the hit-test point at touch time.
        // Pre-clipping to the map frame would leave stale exclusions after resize.
        return rect
    }

    private func installMapTouchOverlay(in superview: UIView, frame: CGRect) {
        let overlay = MapTouchOverlayView(frame: frame)
        overlay.coordinateView = self.webView
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
        pauseCameraFollowForGesture(recognizer)
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
        pauseCameraFollowForGesture(recognizer)
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
        guard recognizer.state == .ended,
              let mapView = mapView,
              let overlay = mapTouchOverlay else {
            return
        }

        let overlayPoint = recognizer.location(in: overlay)
        let tapPoint = overlay.convert(overlayPoint, to: mapView)
        let coordinate = mapView.mapboxMap.coordinate(for: tapPoint)

        if isBoundaryDrawing {
            addBoundaryDrawingPoint(coordinate)
            return
        }

        if let markerId = hitMarkerAtScreenPoint(tapPoint, mapView: mapView) {
            sendKeepCallback(markerClickCallbackId, payload: [
                "type": markerType(for: markerId),
                "id": markerId,
                "isOnline": markerStyles[markerId]?.isOnline ?? true
            ])
            return
        }

        sendMapTap(coordinate)

        guard waypointSelectionEnabled else {
            return
        }

        var id = ""

        if autoAddWaypointMarker {
            id = String(Int(Date().timeIntervalSince1970 * 1000))
            addMarkerInternal(
                id: id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeepCallbackWaypointTs >= callbackRateLimit else {
            return
        }

        lastKeepCallbackWaypointTs = now

        sendKeepCallback(waypointSelectedCallbackId, payload: [
            "type": "waypointSelected",
            "id": id,
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude
        ])
    }

    private func hitMarkerAtScreenPoint(_ tapPoint: CGPoint, mapView: MapView) -> String? {
        let markerWidth: CGFloat = 44
        let markerHeight: CGFloat = 48

        for (id, marker) in markers {
            let coordinate = marker.point.coordinates
            let markerPoint = mapView.mapboxMap.point(for: coordinate)
            let markerRect = CGRect(
                x: markerPoint.x - markerWidth / 2,
                y: markerPoint.y - markerHeight,
                width: markerWidth,
                height: markerHeight
            )

            if markerRect.contains(tapPoint) {
                return id
            }
        }

        return nil
    }

    func doubleOption(_ value: Any?, defaultValue: Double) -> Double {
        let parsed: Double?
        if let value = value as? Double {
            parsed = value
        } else if let value = value as? Float {
            parsed = Double(value)
        } else if let value = value as? Int {
            parsed = Double(value)
        } else if let value = value as? NSNumber {
            parsed = value.doubleValue
        } else if let value = value as? String {
            parsed = Double(value)
        } else {
            parsed = nil
        }

        // Strings such as "NaN" or "Infinity" parse to non-finite values that make
        // CALayer raise CALayerInvalidGeometry and terminate the app.
        guard let number = parsed, number.isFinite else {
            return defaultValue
        }
        return number
    }

    func boolOption(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            if value.caseInsensitiveCompare("true") == .orderedSame { return true }
            if value.caseInsensitiveCompare("false") == .orderedSame { return false }
        }
        return defaultValue
    }

    /// Path line width in points: numeric or numeric string, > 0, capped at 30; otherwise 3.
    private func lineWidthOption(_ value: Any?) -> Double {
        let width = doubleOption(value, defaultValue: Double.nan)
        guard width.isFinite, width > 0 else { return 3.0 }
        return min(width, 30.0)
    }

    /// Path line opacity clamped to 0...1; missing or invalid falls back to fully opaque.
    private func lineOpacityOption(_ value: Any?) -> Double {
        let opacity = doubleOption(value, defaultValue: Double.nan)
        guard opacity.isFinite else { return 1.0 }
        return max(0.0, min(1.0, opacity))
    }

    private func stringOption(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
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
        let scrollView = (webView as? WKWebView)?.scrollView
        savedWebViewAppearance = (webView.isOpaque, webView.backgroundColor, scrollView?.backgroundColor)
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        scrollView?.backgroundColor = UIColor.clear
    }

    func sendSuccess(_ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK)
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    func sendSuccess(_ payload: [String: Any], _ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    func sendSuccess(_ payload: [String: Any], callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        forgetCallback(callbackId)
        commandDelegate.send(result, callbackId: callbackId)
    }

    private func sendNoResultKeepCallback(_ command: CDVInvokedUrlCommand) {
        let result: CDVPluginResult! = CDVPluginResult(status: CDVCommandStatus_NO_RESULT)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    private func sendKeepCallback(_ callbackId: String?, payload: [String: Any]) {
        guard let callbackId = callbackId else {
            return
        }

        let result: CDVPluginResult! = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        result?.setKeepCallbackAs(true)
        commandDelegate.send(result, callbackId: callbackId)
    }

    func sendError(_ message: String, _ command: CDVInvokedUrlCommand) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        forgetCallback(command.callbackId)
        commandDelegate.send(result, callbackId: command.callbackId)
    }

    func sendError(_ message: String, callbackId: String) {
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        forgetCallback(callbackId)
        commandDelegate.send(result, callbackId: callbackId)
    }
}

private class MapTouchOverlayView: UIView {
    var touchableRects: [CGRect] = []
    weak var coordinateView: UIView?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let coordinateView = coordinateView else { return false }
        let webViewPoint = convert(point, to: coordinateView)

        for rect in touchableRects {
            if rect.contains(webViewPoint) {
                return false
            }
        }

        return true
    }
}

private struct MarkerStyle {
    static let `default` = MarkerStyle(color: MarkerIcons.defaultPinColor, isFind: false, imageUrl: nil)

    let color: UIColor
    let isFind: Bool
    let imageUrl: String?
    var photo = false
    /// False for a marker created on the device that has not been synced to the backend yet.
    var isOnline = true
    /// False for a private Find or Waypoint: drawn as a lock tile, image never loaded.
    var isPublic = true
    /// Drawn as the classic red teardrop (offline or plain location pin without an image).
    var classicPin = false
}
