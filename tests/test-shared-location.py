"""Exercise production recenter wait/cancellation methods using a deterministic Java host."""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/android/MapboxPluginEntry.java').read_text(encoding='utf-8')
def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

ensure = method('    private void ensureLocationUpdates(')
assert '.getCurrentLocation(' not in source
assert ensure.count('.requestLocationUpdates(') == 1
assert '.addOnSuccessListener(' in ensure and '.addOnFailureListener(' in ensure
assert ensure.index('.addOnSuccessListener(') < ensure.index('locationSubscriptionReady = true;')
assert 'fusedLocationCallback != subscription' in ensure
assert '.removeLocationUpdates(subscription)' in ensure
assert 'stopSharedLocationUpdates("Map closed; operation cancelled.")' in source
assert 'removeLocationUpdates' not in method('    private void stopUserTracking(')
assert ensure.index('completeMoveToCurrentLocation(new Location(location))') < ensure.index('if (!isUserTrackingEnabled')
print('Shared subscription integration checks passed', flush=True)

host = '''
import java.util.*;
class Location { Location() {} Location(Location value) {} }
class CallbackContext {
    int successes, errors; String message;
    void success() { successes++; }
    void error(String value) { errors++; message = value; }
}
class Handler {
    List<Runnable> work = new ArrayList<>();
    void postDelayed(Runnable r, long delay) { work.add(r); }
    void removeCallbacks(Runnable r) { work.remove(r); }
    void fire() { for (Runnable r : new ArrayList<>(work)) { work.remove(r); r.run(); } }
}
class Main {
    long sessionGeneration;
    static final long LOCATION_WAIT_MS = 15000;
    Handler locationWaitHandler = new Handler();
    Runnable recenterTimeout;
    CallbackContext moveToCurrentLocationCallback;
    Location latestRecenterLocation;
    boolean moveToCurrentLocationZoomSet;
    double moveToCurrentLocationZoom;
    String serviceProblem;
    LocationStartCallback subscriber;
    interface LocationStartCallback { void ready(); void failed(String message); }
    String locationServiceProblem() { return serviceProblem; }
    boolean isUsableRecenterLocation(Location l) { return l != null; }
    void ensureLocationUpdates(LocationStartCallback c) { subscriber = c; }
    void completeMoveToCurrentLocation(Location l) {
        CallbackContext pending = moveToCurrentLocationCallback;
        cancelMoveToCurrentLocation(); pending.success();
    }
    void fix() {
        latestRecenterLocation = new Location();
        if (moveToCurrentLocationCallback != null) completeMoveToCurrentLocation(latestRecenterLocation);
    }
    /*METHODS*/
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        Main p = new Main(); CallbackContext a = new CallbackContext();
        p.startMoveToCurrentLocation(a); p.subscriber.ready();
        check(a.successes == 0 && a.errors == 0);
        p.fix(); p.locationWaitHandler.fire();
        check(a.successes == 1 && a.errors == 0);

        CallbackContext cached = new CallbackContext();
        p.startMoveToCurrentLocation(cached); p.subscriber.ready();
        check(cached.successes == 1 && p.locationWaitHandler.work.isEmpty());

        p.latestRecenterLocation = null;
        CallbackContext timeout = new CallbackContext();
        p.startMoveToCurrentLocation(timeout); p.subscriber.ready(); p.locationWaitHandler.fire();
        check(timeout.errors == 1 && timeout.message.contains("15 seconds"));
        p.fix(); check(timeout.successes == 0);

        p.latestRecenterLocation = null;
        CallbackContext failed = new CallbackContext();
        p.startMoveToCurrentLocation(failed); p.subscriber.failed("Location subscription failed: unavailable");
        p.locationWaitHandler.fire();
        check(failed.errors == 1 && failed.message.contains("subscription failed"));

        CallbackContext old = new CallbackContext(), next = new CallbackContext();
        p.startMoveToCurrentLocation(old); LocationStartCallback stale = p.subscriber;
        p.startMoveToCurrentLocation(next); stale.failed("old failure");
        check(old.errors == 1 && old.message.contains("superseded"));
        check(next.errors == 0); p.subscriber.ready(); p.fix();
        check(next.successes == 1 && old.successes == 0);

        p.latestRecenterLocation = null;
        CallbackContext closed = new CallbackContext();
        p.startMoveToCurrentLocation(closed); stale = p.subscriber;
        p.sessionGeneration++; closed.error("Map closed; operation cancelled.");
        p.cancelMoveToCurrentLocation(); stale.ready(); stale.failed("late"); p.locationWaitHandler.fire();
        check(closed.errors == 1 && closed.successes == 0);

        CallbackContext permission = new CallbackContext();
        p.serviceProblem = "Location permission is not granted.";
        p.startMoveToCurrentLocation(permission);
        check(permission.errors == 1 && p.locationWaitHandler.work.isEmpty());
        System.out.println("Shared recenter wait and cancellation checks passed");
    }
}
'''.replace('/*METHODS*/', '\n'.join(method(s) for s in (
    '    private void startMoveToCurrentLocation(',
    '    private void unregisterMoveToCurrentLocation(',
    '    private void cancelMoveToCurrentLocation(')))
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    file = root / 'Main.java'
    file.write_text(host)
    subprocess.run(['javac', '-d', temp, str(file)], check=True)
    subprocess.run(['java', '-cp', temp, 'Main'], check=True)
