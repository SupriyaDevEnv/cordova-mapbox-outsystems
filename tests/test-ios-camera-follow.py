"""Execute the actual base/parity location callbacks with a minimal camera host."""
from pathlib import Path
import subprocess
import tempfile

base = Path('src/ios/MapboxPlugin.swift').read_text()
parity = Path('src/ios/MapboxPluginParity.swift').read_text()

def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

callback = 'func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])'
helpers = '\n'.join(method(base, signature) for signature in [
    'func resumeCameraFollowing()',
    'func isTrackingLocationManager(',
    'func pauseCameraFollowForGesture('
])
# Verify both foreground and behind-WebView gesture paths use the tested handler.
for name in ['panGestureRecognizer', 'pinchGestureRecognizer']:
    assert name + '.addTarget(self, action: #selector(self.pauseCameraFollowForGesture(_:)))' in base
for name in ['handleMapOverlayPan', 'handleMapOverlayPinch']:
    assert 'pauseCameraFollowForGesture(recognizer)' in method(base, 'func ' + name)
assert 'resumeCameraFollowing()' in method(base, 'private func startUserTracking(')
assert 'isCameraFollowingUser = false' in method(base, 'private func stopUserTracking(')
assert 'self.resumeCameraFollowing()' in method(parity, 'override func moveToCurrentLocation(')
assert 'if self.isCameraFollowingUser' in method(parity, 'private func handleMoveToCurrentLocation(')

host = '''
import Foundation
import CoreLocation
struct CameraOptions {
    var center: CLLocationCoordinate2D
    var zoom: Double? = nil
}
class Camera {
    var moves = 0
    var cancellations = 0
    func setCamera(to: CameraOptions) { moves += 1 }
    func ease(to: CameraOptions, duration: Double) { moves += 1 }
    func cancelAnimations() { cancellations += 1 }
}
class MapView {
    let camera = Camera()
    var mapboxMap: Camera { camera }
}
class UIGestureRecognizer {
    enum State { case possible, began, changed, ended, cancelled }
    var state: State = .possible
}
enum MapboxSecurity { static let maxPoints = 20000 }
class Base {
    var isCameraFollowingUser = false
    var isUserTrackingEnabled = true
    var headingLocationManager: CLLocationManager? = CLLocationManager()
    var mapView: MapView? = MapView()
    var moveToCurrentLocationCallbackId: String?
    var moveToCurrentLocationZoom: Double?
    var lastUserTrackingUpdate: Double = 0
    var isPathTrackingActive = true
    var isPathTrackingPaused = false
    var pathPoints: [CLLocationCoordinate2D] = []
    var currentSegment: [CLLocationCoordinate2D] = []
    var queue: [() -> Void] = []
    var results = 0
    func runForSession(_ work: @escaping () -> Void) { queue.append(work) }
    func drain() { let work = queue; queue.removeAll(); work.forEach { $0() } }
    func updatePathAnnotation() {}
    func stopUserTracking() { isUserTrackingEnabled = false; isCameraFollowingUser = false }
    func sendSuccess(_ payload: [String: Any], callbackId: String) { results += 1 }
'''
subclass = '''
}
class Parity: Base {
    var moveLocationManager: CLLocationManager?
    var accuracyLocationManager: CLLocationManager?
    var lastTrackingLocationUpdate: Double = 0
    let trackingCameraInterval = 0.4
    let locationSmoothingFactor = 0.35
    let trackingCameraAnimationDuration = 0.25
    var smoothedTrackingCoordinate: CLLocationCoordinate2D?
    var parityPathTrackingActive = true
    var accuracyUpdates = 0
    func activeMapView() -> MapView? { mapView }
    func handleMoveToCurrentLocation(_ location: CLLocation, manager: CLLocationManager) {}
    func sendLocationAccuracyUpdate(_ location: CLLocation) { accuracyUpdates += 1 }
'''
checks = '''
}
let plugin = Parity()
let manager = plugin.headingLocationManager!
let gesture = UIGestureRecognizer()
func update() {
    plugin.lastTrackingLocationUpdate = 0
    plugin.lastUserTrackingUpdate = 0
    plugin.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 10, longitude: 20)])
}
plugin.resumeCameraFollowing()
update(); plugin.drain()
precondition(plugin.mapView!.camera.moves > 0)
precondition(plugin.pathPoints.count == 1)

// A gesture can start after a fix has queued both base and parity camera work.
update()
gesture.state = .began
plugin.pauseCameraFollowForGesture(gesture)
let beforePause = plugin.mapView!.camera.moves
plugin.drain()
precondition(plugin.mapView!.camera.moves == beforePause, "Queued updates must respect manual pan")
precondition(plugin.pathPoints.count == 2, "Queued path point is still recorded")
precondition(plugin.mapView!.camera.cancellations == 1)
precondition(plugin.isUserTrackingEnabled)

update(); plugin.drain()
precondition(plugin.mapView!.camera.moves == beforePause)
precondition(plugin.pathPoints.count == 3, "Recording continues during free exploration")
precondition(plugin.accuracyUpdates == 3, "Accuracy updates continue during free exploration")
gesture.state = .ended
plugin.pauseCameraFollowForGesture(gesture)
precondition(!plugin.isCameraFollowingUser, "Lifting the finger does not resume following")

plugin.resumeCameraFollowing()
update(); plugin.drain()
precondition(plugin.mapView!.camera.moves > beforePause, "Explicit follow resumes")

update(); plugin.stopUserTracking()
let beforeStop = plugin.mapView!.camera.moves
let pointCount = plugin.pathPoints.count
plugin.drain()
precondition(plugin.mapView!.camera.moves == beforeStop)
precondition(plugin.pathPoints.count == pointCount, "Stopped tracking ignores queued points")

// The base one-shot location completion must also honor a gesture before its fix.
let oneShot = Base()
oneShot.resumeCameraFollowing()
oneShot.moveToCurrentLocationCallbackId = "request"
oneShot.locationManager(oneShot.headingLocationManager!, didUpdateLocations: [CLLocation(latitude: 10, longitude: 20)])
gesture.state = .began
oneShot.pauseCameraFollowForGesture(gesture)
oneShot.drain()
precondition(oneShot.mapView!.camera.moves == 0)
precondition(oneShot.results == 1, "Location result still resolves while camera is paused")
print("iOS camera pause/resume, queued updates, recording and accuracy checks passed")
'''
with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    swift = directory / 'main.swift'
    swift.write_text(host + helpers + '\n' + method(base, callback) + subclass +
                     'override ' + method(parity, callback) + checks)
    binary = directory / 'follow-tests'
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
