"""Run production tap closures against late events, without Mapbox/device dependencies."""
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    ios = Path('src/ios/MapboxPlugin.swift').read_text()
    tap = ios.split('        marker.tapHandler = ', 1)[1].split('\n\n        markers[id]', 1)[0]
    swift = directory / 'main.swift'
    swift.write_text('''import Foundation
struct Marker { var id: String }
class TestPlugin {
    var sessionGeneration: UInt64 = 0
    var markers = ["record": Marker(id: "annotation")]
    var lastKeepCallbackMarkerTs: Double = 0
    let callbackRateLimit: Double = 0
    var markerClickCallbackId: String? = "callback"
    var events = 0
    func markerType(for id: String) -> String { "Waypoint" }
    func sendKeepCallback(_ id: String?, payload: [String: Any]) { events += 1 }
    func listener() -> (Int) -> Bool {
        let generation = sessionGeneration
        let id = "record"
        let annotationId = "annotation"
        return ''' + tap + '''
    }
}
let plugin = TestPlugin()
let oldTap = plugin.listener()
_ = oldTap(0)
precondition(plugin.events == 1)
plugin.markers.removeAll()
_ = oldTap(0)
precondition(plugin.events == 1, "Removed marker must ignore late tap")
plugin.markers["record"] = Marker(id: "replacement")
_ = oldTap(0)
precondition(plugin.events == 1, "Replaced marker must ignore late tap")
plugin.sessionGeneration += 1
plugin.markers["record"] = Marker(id: "annotation")
_ = oldTap(0)
precondition(plugin.events == 1, "Old session must ignore late tap after reopen")
_ = plugin.listener()(0)
precondition(plugin.events == 2)
print("iOS delayed marker taps passed")
''')
    subprocess.run(['swiftc', str(swift), '-o', str(directory / 'tap-test')], check=True)
    subprocess.run([str(directory / 'tap-test')], check=True)

    android = Path('src/android/MapboxPluginEntry.java').read_text()
    tap = android.split('        markerTapListener = ', 1)[1].split('\n        pointAnnotationManager.addClickListener', 1)[0]
    cleanup = android.split('    private void cleanupStep(', 1)[1].split('    protected void closeInternal()', 1)[0]
    java = directory / 'TeardownTest.java'
    java.write_text('''import java.util.*;
public class TeardownTest {
    long sessionGeneration = 0, lastKeepCallbackMarkerMs = 0;
    static final long CALLBACK_RATE_LIMIT_MS = 0;
    Object mapView = new Object(), markerClickCallback = new Object();
    int events = 0;
    Map<Long, String> markerRecordIds = new HashMap<>();
    Map<String, MarkerStyle> markerStylesByRecordId = new HashMap<>();
    static class MarkerStyle { boolean isFind; }
    static class Annotation { long getId() { return 1L; } }
    interface Tap { boolean click(Annotation annotation); }
    static class JSONObject { void put(String key, String value) {} }
    static class Log {
        static void e(String tag, String message, Exception error) { throw new AssertionError(error); }
        static void w(String tag, String message, Exception error) {}
    }
    void sendKeepCallback(Object callback, JSONObject payload) { events++; }
    private void cleanupStep(''' + cleanup + '''
    Tap listener() {
        final long generation = sessionGeneration;
        return ''' + tap + '''
    }
    public static void main(String[] args) {
        TeardownTest plugin = new TeardownTest();
        plugin.markerRecordIds.put(1L, "record");
        Tap old = plugin.listener();
        old.click(new Annotation());
        if (plugin.events != 1) throw new AssertionError("Live tap missing");
        plugin.sessionGeneration++;
        old.click(new Annotation());
        if (plugin.events != 1) throw new AssertionError("Stale tap reached reopened map");
        plugin.listener().click(new Annotation());
        if (plugin.events != 2) throw new AssertionError("New tap missing");
        plugin.cleanupStep(() -> { throw new IllegalStateException("SDK failure"); });
        plugin.cleanupStep(() -> plugin.mapView = null);
        if (plugin.mapView != null) throw new AssertionError("Cleanup aborted");
        plugin.listener().click(new Annotation());
        if (plugin.events != 2) throw new AssertionError("Tap after close");
        System.out.println("Android delayed taps and failure isolation passed");
    }
}
''')
    subprocess.run(['javac', '-d', temp, str(java)], check=True)
    subprocess.run(['java', '-cp', temp, 'TeardownTest'], check=True)
