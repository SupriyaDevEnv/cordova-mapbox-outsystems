"""Execute the actual appearance statements with an isolated WebView contract host.

This reproduces drawable transparency vs. the separate browser background; it
does not emulate Chromium, Mapbox rendering, or a device compositor.
"""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/android/MapboxPluginEntry.java').read_text()
begin = source.index('        originalWebViewBackground = webViewView.getBackground();')
end = source.index('        View anchor =', begin)
apply = source[begin:end].replace('android.graphics.drawable.', '')
begin = source.index('        if (view != null && view.getBackground() == mapWebViewBackground)')
end = source.index('        if (router != null', begin)
restore = source[begin:end]

host = '''
public class AppearanceTest {
    static class Color { static final int TRANSPARENT = 0, WHITE = -1; }
    static class Drawable {}
    static class ColorDrawable extends Drawable {
        int color;
        ColorDrawable(int value) { color = value; }
        int getColor() { return color; }
    }
    static class Preferences {
        int color = Color.WHITE;
        int getInteger(String key, int fallback) { return color; }
    }
    // WebView.setBackgroundColor delegates to the browser. setBackground only
    // changes View's drawable, so a transparent drawable cannot satisfy this test.
    static class View {
        Drawable background;
        int browserColor;
        View(Drawable bg, int color) { background = bg; browserColor = color; }
        Drawable getBackground() { return background; }
        void setBackground(Drawable bg) { background = bg; }
        void setBackgroundColor(int color) { browserColor = color; }
    }
    Preferences preferences = new Preferences();
    Drawable originalWebViewBackground, mapWebViewBackground;
    int originalWebViewBackgroundColor;
    void apply(View webViewView) {
''' + apply + '''
    }
    void restore(View view) {
''' + restore + '''
    }
    static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        for (Drawable original : new Drawable[] {null, new ColorDrawable(0xff123456), new Drawable()}) {
            AppearanceTest plugin = new AppearanceTest();
            plugin.preferences.color = 0xffabcdef;
            int originalColor = original instanceof ColorDrawable
                ? ((ColorDrawable) original).getColor() : plugin.preferences.color;
            View view = new View(original, originalColor);
            for (int cycle = 0; cycle < 3; cycle++) {
                plugin.apply(view);
                check(view.browserColor == Color.TRANSPARENT, "Browser still covers native map");
                if (original instanceof ColorDrawable)
                    check(((ColorDrawable) original).getColor() == originalColor, "Saved drawable mutated");
                plugin.restore(view);
                check(view.background == original, "Original drawable not restored");
                check(view.browserColor == originalColor, "Browser color not restored");
            }
            plugin.apply(view);
            Drawable external = new ColorDrawable(0xff556677);
            view.setBackground(external);
            view.setBackgroundColor(0xff556677);
            plugin.restore(view);
            check(view.background == external && view.browserColor == 0xff556677,
                "Close overwrote an external appearance change");
        }
        System.out.println("Android WebView appearance contract passed");
    }
}
'''
with tempfile.TemporaryDirectory() as temp:
    java = Path(temp) / 'AppearanceTest.java'
    java.write_text(host)
    subprocess.run(['javac', '-d', temp, str(java)], check=True)
    subprocess.run(['java', '-cp', temp, 'AppearanceTest'], check=True)

# Cordova exposes webView as UIView, even when the instance is WKWebView.
# Keep that base type in this host so unguarded .scrollView access fails to compile.
ios = Path('src/ios/MapboxPlugin.swift').read_text()
apply = ios.split('    private func makeWebViewTransparent() {', 1)[1].split('\n    private func sendSuccess', 1)[0]
restore = ios.split('        if let saved = savedWebViewAppearance {', 1)[1].split('        trackingStatusCallbackId = nil', 1)[0]
swift_host = '''
enum UIColor { static let clear = "clear" }
class UIView {
    var backgroundColor: String? = "view"
    var isOpaque = true
}
class WKWebView: UIView { let scrollView = UIView() }
class AppearanceTest {
    var webView: UIView
    var savedWebViewAppearance: (Bool, String?, String?)?
    init(_ view: UIView) { webView = view }
    func apply() {
''' + apply + '''
    func restore() {
        if let saved = savedWebViewAppearance {
''' + restore + '''
    }
}
for view in [UIView(), WKWebView()] {
    let plugin = AppearanceTest(view)
    let scroll = (view as? WKWebView)?.scrollView
    scroll?.backgroundColor = "scroll"
    for _ in 0..<3 {
        plugin.apply()
        precondition(view.backgroundColor == UIColor.clear && !view.isOpaque)
        if let scroll = scroll { precondition(scroll.backgroundColor == UIColor.clear) }
        plugin.restore()
        precondition(view.backgroundColor == "view" && view.isOpaque)
        if let scroll = scroll { precondition(scroll.backgroundColor == "scroll") }
        precondition(plugin.savedWebViewAppearance == nil)
    }
    plugin.apply()
    view.backgroundColor = "external"
    scroll?.backgroundColor = "external-scroll"
    plugin.restore()
    precondition(view.backgroundColor == "external")
    if let scroll = scroll { precondition(scroll.backgroundColor == "external-scroll") }
}
print("iOS UIView/WKWebView appearance contract passed")
'''
with tempfile.TemporaryDirectory() as temp:
    swift = Path(temp) / 'main.swift'
    binary = Path(temp) / 'appearance-test'
    swift.write_text(swift_host)
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
