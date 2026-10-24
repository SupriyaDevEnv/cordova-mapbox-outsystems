"""Run the production location-validity predicate with a minimal Java host."""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/android/MapboxPluginEntry.java').read_text(encoding='utf-8')
def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

predicate = '\n'.join(method(signature) for signature in (
    '    private String recenterLocationProblem(',
    '    private boolean isUsableRecenterLocation(',
    '    private void updateInitialUserLocation('))

# Integration guard checks accompany the executable predicate cases.
assert source.index('latestRecenterLocation = new Location(location);') < source.index('// Pin the puck while')
stop = method('    private void stopSharedLocationUpdates(')
assert 'latestRecenterLocation = null;' in stop
move = source[source.index('private void startMoveToCurrentLocation('):source.index('private String getAccuracyLabel(')]
assert 'generation != sessionGeneration || moveToCurrentLocationCallback != callback' in move
assert 'ensureLocationUpdates(' in move
assert 'runRecenterAnimation(' in move
assert 'final boolean applyZoom = moveToCurrentLocationZoomSet;' in move
tracking = source[source.index('private void startUserTracking('):source.index('private void stopUserTracking(')]
coarse = tracking[tracking.index('// One stream supplies'):tracking.index('// 2. Validate coordinates')]
assert 'updateInitialUserLocation(location)' in coarse and 'continue;' in coarse
assert 'updateMovementHistory' not in coarse and 'pathPoints.add' not in coarse
assert 'updateInitialUserLocation(location);' in move
print('Recenter and initial puck source integration checks passed', flush=True)

host = '''
class Location {
    float accuracy = 10;
    boolean hasAccuracy = true;
    double latitude = 10, longitude = 20;
    long nanos = 100_000_000_000L;
    boolean hasAccuracy() { return hasAccuracy; }
    float getAccuracy() { return accuracy; }
    double getLatitude() { return latitude; }
    double getLongitude() { return longitude; }
    long getElapsedRealtimeNanos() { return nanos; }
}
class Provider {
    int updates = 0;
    void updateLocation(Location l) { updates++; }
}
class Main {
    boolean isUserLocationEnabled = true;
    Object smoothedTrackingPoint = null;
    Provider smoothedLocationProvider = new Provider();
    float currentLocationAccuracy;
    String currentLocationAccuracyLabel;
    String getAccuracyLabel(float a) { return a > 25 ? "Low" : "Accurate"; }
    static final long MAX_LOCATION_AGE_MS = 30_000L;
    static final float MAX_ACCEPTABLE_ACCURACY_METERS = 25f;
    boolean isValidLatitude(double v) { return v >= -90 && v <= 90; }
    boolean isValidLongitude(double v) { return v >= -180 && v <= 180; }
    /*PREDICATE*/
    static void check(boolean v) { if (!v) throw new AssertionError(); }
    public static void main(String[] args) {
        Main p = new Main(); Location l = new Location();
        check(!p.isUsableRecenterLocation(null));
        check(p.isUsableRecenterLocation(l));
        l.nanos = 70_000_000_000L; check(p.isUsableRecenterLocation(l));
        l.nanos--; check(!p.isUsableRecenterLocation(l));
        l.nanos = 100_000_000_001L; check(!p.isUsableRecenterLocation(l));
        l.nanos = 0; check(!p.isUsableRecenterLocation(l));
        l.nanos = 100_000_000_000L;
        l.accuracy = 25; check(p.isUsableRecenterLocation(l));
        l.accuracy = 26; check(p.isUsableRecenterLocation(l));
        l.accuracy = 1500; check(p.isUsableRecenterLocation(l));
        p.updateInitialUserLocation(l);
        check(p.smoothedLocationProvider.updates == 1);
        check(p.currentLocationAccuracy == 1500);
        p.smoothedTrackingPoint = new Object();
        p.updateInitialUserLocation(l);
        check(p.smoothedLocationProvider.updates == 1);
        p.smoothedTrackingPoint = null;
        p.isUserLocationEnabled = false;
        p.updateInitialUserLocation(l);
        check(p.smoothedLocationProvider.updates == 1);
        p.isUserLocationEnabled = true;
        l.nanos = 1;
        p.updateInitialUserLocation(l);
        check(p.smoothedLocationProvider.updates == 1);
        check(p.recenterLocationProblem(l).contains("older than"));
        check(p.recenterLocationProblem(null).contains("No location fix"));
        l.nanos = 100_000_000_001L;
        check(p.recenterLocationProblem(l).contains("future"));
        l.nanos = 100_000_000_000L;
        l.accuracy = -1; check(!p.isUsableRecenterLocation(l));
        l.accuracy = Float.NaN; check(!p.isUsableRecenterLocation(l));
        l.accuracy = Float.POSITIVE_INFINITY; check(!p.isUsableRecenterLocation(l));
        l.accuracy = 10; l.hasAccuracy = false; check(!p.isUsableRecenterLocation(l));
        l.hasAccuracy = true; l.latitude = Double.NaN; check(!p.isUsableRecenterLocation(l));
        l.latitude = 91; check(!p.isUsableRecenterLocation(l));
        l.latitude = 10; l.longitude = 181; check(!p.isUsableRecenterLocation(l));
        l.longitude = 20; check(p.isUsableRecenterLocation(l));
        System.out.println("Recenter location validity checks passed");
    }
}
'''.replace('/*PREDICATE*/', predicate)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'android/os').mkdir(parents=True)
    clock = root / 'android/os/SystemClock.java'
    clock.write_text('package android.os; public class SystemClock { public static long elapsedRealtimeNanos() { return 100_000_000_000L; } }')
    main = root / 'Main.java'
    main.write_text(host)
    subprocess.run(['javac', '-d', str(root), str(clock), str(main)], check=True)
    subprocess.run(['java', '-cp', str(root), 'Main'], check=True)



