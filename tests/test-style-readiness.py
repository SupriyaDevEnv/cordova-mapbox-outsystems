"""Run the production readiness gates with controllable SDK completions and clocks."""
from pathlib import Path
import subprocess
import tempfile

android = Path('src/android/MapboxPluginEntry.java').read_text()
ios = Path('src/ios/MapboxPlugin.swift').read_text()
assert 'MapInitOptions(cameraOptions: camera, styleURI: nil)' in ios
assert android.count('.loadStyle(') == 1
assert ios.count('.loadStyle(') == 1
assert android.count('loadReadyStyle(styleUrl,') == 3
assert ios.count('self.loadReadyStyle(styleURI,') == 3
assert 'sessionGeneration++;\n        cancelPendingStyle();' in android
assert 'sessionGeneration &+= 1\n        cancelPendingStyle()' in ios
java_helper = android.split('    // All style replacements use this gate. Never resolve readiness on a timer.', 1)[1].split('    private void cancelCurrentDownload()', 1)[0]
swift_helper = ios.split('    private final class StyleRequest', 1)[1].split('    private func cancelCurrentDownload()', 1)[0]

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    java = root / 'StyleTest.java'
    java.write_text('''
import java.util.*;
import java.util.function.Consumer;
public class StyleTest {
    static class Looper { static Looper getMainLooper() { return new Looper(); } }
    static class Handler {
        List<Runnable> timers = new ArrayList<>();
        Handler(Looper l) {}
        void post(Runnable r) { r.run(); }
        void postDelayed(Runnable r, long delay) { timers.add(r); }
        void removeCallbacks(Runnable r) { timers.remove(r); }
    }
    interface Cancelable { void cancel(); }
    static class JSONObject { void put(String k, String v) throws JSONException {} }
    static class JSONException extends Exception {}
    static class CallbackContext {
        int successes, failures; String message;
        boolean isFinished() { return successes + failures > 0; }
        void success() { successes++; }
        void success(JSONObject value) { successes++; }
        void error(String value) { failures++; message = value; }
    }
    enum ErrorType { STYLE, TILE }
    static class Event {
        ErrorType type;
        Event(ErrorType t) { type = t; }
        ErrorType getType() { return type; }
    }
    static class MapView {
        Consumer<Object> loaded; Consumer<Event> errors; int cancelled;
        MapView getMapboxMap() { return this; }
        Cancelable subscribeMapLoadingError(Consumer<Event> cb) {
            errors = cb; return () -> cancelled++;
        }
        void loadStyle(String uri, Consumer<Object> cb) { loaded = cb; }
    }
    MapView mapView = new MapView();
    void cleanupStep(Runnable work) { try { work.run(); } catch (RuntimeException ignored) {} }
''' + java_helper.replace('com.mapbox.maps.MapLoadingErrorType', 'ErrorType') + '''
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        StyleTest p = new StyleTest();
        CallbackContext first = new CallbackContext();
        p.loadReadyStyle("style", "initialized", first);
        check(first.successes == 0 && first.failures == 0);
        CallbackContext overlap = new CallbackContext();
        p.loadReadyStyle("other", "styleChanged", overlap);
        check(overlap.failures == 1 && first.failures == 0);
        p.mapView.errors.accept(new Event(ErrorType.TILE));
        check(first.failures == 0);
        Consumer<Object> old = p.mapView.loaded;
        old.accept(null); old.accept(null);
        check(first.successes == 1 && p.mapView.cancelled == 1 && p.styleHandler.timers.isEmpty());
        CallbackContext failure = new CallbackContext();
        p.loadReadyStyle("bad", "styleChanged", failure);
        Consumer<Object> failedCompletion = p.mapView.loaded;
        p.mapView.errors.accept(new Event(ErrorType.STYLE));
        failedCompletion.accept(null);
        check(failure.failures == 1 && failure.successes == 0);
        CallbackContext timeout = new CallbackContext();
        p.loadReadyStyle("slow", null, timeout);
        Consumer<Object> timedCompletion = p.mapView.loaded;
        p.styleHandler.timers.get(0).run();
        timedCompletion.accept(null);
        check(timeout.failures == 1 && timeout.successes == 0);
        CallbackContext closed = new CallbackContext();
        p.loadReadyStyle("closing", "initialized", closed);
        Consumer<Object> closedCompletion = p.mapView.loaded;
        p.cancelPendingStyle();
        closed.error("Map closed; operation cancelled.");
        p.mapView = new MapView();
        CallbackContext next = new CallbackContext();
        p.loadReadyStyle("next", "initialized", next);
        closedCompletion.accept(null); old.accept(null);
        check(closed.successes == 0 && closed.failures == 1 && next.successes == 0);
        p.mapView.loaded.accept(null);
        check(next.successes == 1 && p.styleHandler.timers.isEmpty());
        System.out.println("Android style readiness passed");
    }
}
''')
    subprocess.run(['javac', '-d', temp, str(java)], check=True)
    subprocess.run(['java', '-cp', temp, 'StyleTest'], check=True)
    swift = root / 'main.swift'
    swift.write_text('''import Foundation
typealias StyleURI = String
class CDVInvokedUrlCommand { var successes = 0; var failures = 0 }
class MapView {
    var completion: ((Error?) -> Void)?
    var mapboxMap: MapView { self }
    func loadStyle(_ uri: StyleURI, completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }
}
class TestPlugin {
    var mapView: MapView? = MapView()
    func sendError(_ message: String, _ c: CDVInvokedUrlCommand) { c.failures += 1 }
    func sendSuccess(_ c: CDVInvokedUrlCommand) { c.successes += 1 }
    func sendSuccess(_ result: [String: String], _ c: CDVInvokedUrlCommand) { c.successes += 1 }
    private final class StyleRequest''' + swift_helper + '''
    func exercise() {
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let first = CDVInvokedUrlCommand()
        loadReadyStyle("style", status: "initialized", command: first)
        precondition(first.successes == 0 && first.failures == 0)
        let overlap = CDVInvokedUrlCommand()
        loadReadyStyle("other", status: nil, command: overlap)
        precondition(overlap.failures == 1 && first.failures == 0)
        let old = mapView!.completion!
        old(nil); drain(); old(nil); drain()
        precondition(first.successes == 1 && pendingStyle == nil)
        let failure = CDVInvokedUrlCommand()
        loadReadyStyle("bad", status: "styleChanged", command: failure)
        let failedCompletion = mapView!.completion!
        failedCompletion(NSError(domain: "style", code: 1)); drain()
        failedCompletion(nil); drain()
        precondition(failure.failures == 1 && failure.successes == 0)
        let timed = CDVInvokedUrlCommand()
        loadReadyStyle("slow", status: nil, command: timed)
        let timedCompletion = mapView!.completion!
        pendingStyle!.timeout!.perform()
        timedCompletion(nil); drain()
        precondition(timed.failures == 1 && timed.successes == 0)
        let closed = CDVInvokedUrlCommand()
        loadReadyStyle("closing", status: "initialized", command: closed)
        let closedCompletion = mapView!.completion!
        cancelPendingStyle()
        sendError("Map closed; operation cancelled.", closed)
        mapView = MapView()
        let next = CDVInvokedUrlCommand()
        loadReadyStyle("next", status: "initialized", command: next)
        closedCompletion(nil); old(nil); drain()
        precondition(closed.successes == 0 && closed.failures == 1 && next.successes == 0)
        mapView!.completion!(nil); drain()
        precondition(next.successes == 1 && pendingStyle == nil)
    }
}
TestPlugin().exercise()
print("iOS style readiness passed")
''')
    subprocess.run(['swiftc', str(swift), '-o', str(root / 'style-test')], check=True)
    subprocess.run([str(root / 'style-test')], check=True)
