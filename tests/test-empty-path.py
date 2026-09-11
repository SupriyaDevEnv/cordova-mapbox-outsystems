"""Compile and execute the actual stopPathTracking body with a minimal host."""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/ios/MapboxPlugin.swift').read_text()
start = source.index('    func stopPathTracking(')
end = source.index('    @objc(loadPath:)', start)
method = source[start:end]
host = '''
import Foundation
import CoreLocation
class CDVInvokedUrlCommand {}
class TestPlugin {
    var isPathTrackingActive = true
    var pathTrackingStartTime = Date().timeIntervalSince1970
    var pathPoints: [CLLocationCoordinate2D] = []
    var result: [String: Any] = [:]
    func runForSession(_ work: () -> Void) { work() }
    func sendError(_ error: String, _ command: CDVInvokedUrlCommand) { fatalError(error) }
    func sendSuccess(_ payload: [String: Any], _ command: CDVInvokedUrlCommand) { result = payload }
'''
checks = '''
}
for count in 0...2 {
    let plugin = TestPlugin()
    plugin.pathPoints = (0..<count).map { CLLocationCoordinate2D(latitude: Double($0) * 0.01, longitude: 0) }
    plugin.stopPathTracking(command: CDVInvokedUrlCommand())
    precondition(!plugin.isPathTrackingActive)
    precondition((plugin.result["points"] as! [[String: Double]]).count == count)
    let distance = plugin.result["distance"] as! Double
    precondition(count < 2 ? distance == 0 : distance > 0)
}
print("Actual iOS stopPathTracking: zero, one, two points passed")
'''
with tempfile.TemporaryDirectory() as directory:
    swift = Path(directory) / 'main.swift'
    binary = Path(directory) / 'path-test'
    swift.write_text(host + method + checks)
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
