"""Run actual iOS rectangle conversion and hit-test code with a minimal view host.

The coordinate-conversion double models translation; device testing still needs
to verify real UIKit/WKWebView offsets and gesture delivery.
"""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/ios/MapboxPlugin.swift').read_text()
method = source[source.index('    private func touchRectFromOptions('):
                source.index('    private func installMapTouchOverlay(')]
method = method.replace('private func', 'func', 1)
# Extract only the overlay class, not unrelated declarations appended after it.
start = source.index('private class MapTouchOverlayView:')
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
overlay = source[start:end]
overlay = overlay.replace('private class', 'class', 1)
host = '''
import Foundation
import CoreGraphics
class UIEvent {}
class UIView {
    var frame: CGRect
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    init(frame: CGRect) { self.frame = frame }
    func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
    func convert(_ point: CGPoint, to view: UIView) -> CGPoint {
        CGPoint(x: point.x + frame.minX - view.frame.minX,
                y: point.y + frame.minY - view.frame.minY)
    }
}
class UIScreen {
    static let main = UIScreen()
    var scale: CGFloat = 3
}
class TestPlugin {
    func doubleOption(_ value: Any?, defaultValue: Double) -> Double {
        (value as? NSNumber)?.doubleValue ?? defaultValue
    }
'''
checks = '''
let plugin = TestPlugin()
let webView = UIView(frame: CGRect(x: 10, y: 40, width: 400, height: 800))
let overlay = MapTouchOverlayView(frame: CGRect(x: 30, y: 100, width: 200, height: 300))
overlay.coordinateView = webView
for scale in [1.0, 2.0, 3.0] {
    UIScreen.main.scale = CGFloat(scale)
    let rect = plugin.touchRectFromOptions([
        "x": 40 * scale, "y": 80 * scale,
        "width": 60 * scale, "height": 30 * scale
    ])
    precondition(rect == CGRect(x: 40, y: 80, width: 60, height: 30))
    overlay.touchableRects = [rect]
    precondition(!overlay.point(inside: CGPoint(x: 25, y: 25), with: nil), "Control stays in WebView")
    precondition(overlay.point(inside: CGPoint(x: 150, y: 150), with: nil), "Map gesture accepted")
    for point in [CGPoint(x: -1, y: 10), CGPoint(x: 201, y: 10),
                  CGPoint(x: 10, y: -1), CGPoint(x: 10, y: 301)] {
        precondition(!overlay.point(inside: point, with: nil), "Outside map stays in WebView")
    }
}
UIScreen.main.scale = 3
overlay.touchableRects = [plugin.touchRectFromOptions([
    "x": 750, "y": 300, "width": 90, "height": 90
])]
overlay.frame = CGRect(x: 230, y: 100, width: 200, height: 300)
precondition(!overlay.point(inside: CGPoint(x: 40, y: 50), with: nil), "Resize/move uses original unclipped regions")
overlay.touchableRects = []
precondition(overlay.point(inside: CGPoint(x: 40, y: 50), with: nil), "Dismissed overlay releases map")
precondition(plugin.touchRectFromOptions(["width": 0, "height": 10]).isNull)
overlay.coordinateView = nil
precondition(!overlay.point(inside: CGPoint(x: 40, y: 50), with: nil))
print("iOS touch rectangle and hit-test checks passed")
'''
with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    swift = directory / 'main.swift'
    swift.write_text(host + method + '\n}\n' + overlay + checks)
    binary = directory / 'touch-tests'
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
