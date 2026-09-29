"""Execute the real recenter guard against a camera host that cancels in-flight animations."""
from pathlib import Path
import re
import subprocess
import tempfile

source = Path('src/android/MapboxPluginEntry.java').read_text()


def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


follow = method(source, 'private void startCameraFollow()')
recenter = method(source, 'private void runRecenterAnimation(')
stop = method(source, 'private void stopCameraFollow()')
move = method(source, 'private void startMoveToCurrentLocation(')

# Static: the ticker has to defer to the recenter guard.
assert '&& !isRecenterAnimating' in follow, 'Ticker must skip while a recenter flight runs'

# Static: the recenter must fly through the guard instead of easing on its own.
assert 'runRecenterAnimation(' in move, 'Recenter must go through the guarded helper'
assert 'easeTo' not in move, 'Recenter must not issue a bare easeTo'
assert 'duration(700L)' not in move, 'Recenter must not keep the old 700 ms ease'

# Static: a superseded flight must not release the guard owned by the newer one.
assert 'generation == recenterAnimationGeneration' in recenter, 'Missing generation check'
assert stop.count('isRecenterAnimating = false;') == 1, 'Teardown must release the guard'

interval = int(re.search(r'CAMERA_FOLLOW_INTERVAL_MS = (\d+)L', source).group(1))
follow_duration = int(re.search(r'CAMERA_FOLLOW_DURATION_MS = (\d+)L', source).group(1))
recenter_duration = int(re.search(r'RECENTER_ANIMATION_DURATION_MS = (\d+)L', source).group(1))
assert recenter_duration == 1500, 'Recenter flight should match the 1500 ms client style'

STUBS = '''package android.animation;

/** Mirrors the real listener surface so the extracted plugin code compiles unchanged. */
public interface Animator {
    interface AnimatorListener {
        void onAnimationStart(Animator animation);
        void onAnimationEnd(Animator animation);
        void onAnimationCancel(Animator animation);
    }
}
'''

HOST = '''
import android.animation.Animator;

class Point {
    private final double lat;
    private final double lng;

    Point(double lat, double lng) {
        this.lat = lat;
        this.lng = lng;
    }

    double latitude() { return lat; }
    double longitude() { return lng; }

    static Point fromLngLat(double longitude, double latitude) {
        return new Point(latitude, longitude);
    }
}

class MapAnimationOptions {
    long duration;

    static class Builder {
        long duration;

        Builder duration(long value) {
            duration = value;
            return this;
        }

        MapAnimationOptions build() {
            MapAnimationOptions options = new MapAnimationOptions();
            options.duration = duration;
            return options;
        }
    }
}
class CameraOptions {
    private Point center;

    Point center() { return center; }

    static class Builder {
        private final CameraOptions options = new CameraOptions();

        Builder center(Point value) {
            options.center = value;
            return this;
        }

        Builder zoom(double value) { return this; }

        CameraOptions build() { return options; }
    }
}

class Plugin {
    static final String MAPBOX_CAMERA_PLUGIN_ID = "com.mapbox.android.camera";
}

class MapboxMap {
    int setCameraCalls = 0;

    void setCamera(CameraOptions options) { setCameraCalls++; }
}

/**
 * Reproduces Mapbox behaviour where a new high-level animation cancels the one
 * already running, and the superseded animation reports it on its own listener.
 */
class CameraAnimationsPlugin {
    private Animator.AnimatorListener listener;
    private boolean running = false;

    int easeCalls = 0;
    int flyCalls = 0;
    int cancellations = 0;

    private void begin(Animator.AnimatorListener next) {
        if (running) {
            running = false;
            cancellations++;
            if (listener != null) {
                listener.onAnimationCancel(null);
            }
        }
        listener = next;
        running = true;
    }

    void easeTo(
        CameraOptions options,
        MapAnimationOptions animation,
        Animator.AnimatorListener callback
    ) {
        easeCalls++;
        begin(callback);
    }

    void flyTo(
        CameraOptions options,
        MapAnimationOptions animation,
        Animator.AnimatorListener callback
    ) {
        flyCalls++;
        begin(callback);
    }

    void endActive() {
        if (running) {
            running = false;
            if (listener != null) {
                listener.onAnimationEnd(null);
            }
        }
    }
}

class MapView {
    final CameraAnimationsPlugin camera = new CameraAnimationsPlugin();
    final MapboxMap mapboxMap = new MapboxMap();
    boolean cameraPluginAvailable = true;

    CameraAnimationsPlugin getPlugin(String id) {
        return cameraPluginAvailable ? camera : null;
    }

    MapboxMap getMapboxMap() { return mapboxMap; }
}

class Handler {
    Runnable pending;

    void removeCallbacks(Runnable runnable) { pending = null; }
    void removeCallbacksAndMessages(Object token) { pending = null; }
    void postDelayed(Runnable runnable, long delay) { pending = runnable; }
}

class Main {
    static final long CAMERA_FOLLOW_INTERVAL_MS = /*INTERVAL*/;
    static final long CAMERA_FOLLOW_DURATION_MS = /*FOLLOW_DURATION*/;
    static final long RECENTER_ANIMATION_DURATION_MS = /*RECENTER_DURATION*/;

    final MapView mapView = new MapView();
    final Handler cameraFollowHandler = new Handler();

    Runnable cameraFollowRunnable;
    boolean isUserTrackingEnabled = true;
    boolean isCameraFollowingUser = true;
    boolean isRecenterAnimating = false;
    int recenterAnimationGeneration = 0;
    Point smoothedTrackingPoint = null;
    Point lastCameraFollowTarget = null;

    /** Moves the blue dot far enough that the ticker's change check would pass. */
    void walk(double lat, double lng) {
        smoothedTrackingPoint = Point.fromLngLat(lng, lat);
    }

    /** Fires one camera-follow tick, the way the 250 ms handler would. */
    void tick() {
        Runnable runnable = cameraFollowHandler.pending;
        cameraFollowHandler.pending = null;
        if (runnable != null) {
            runnable.run();
        }
    }

    static CameraOptions optionsAt(double lat, double lng) {
        return new CameraOptions.Builder()
            .center(Point.fromLngLat(lng, lat))
            .build();
    }

    static MapAnimationOptions recenterAnimation() {
        return new MapAnimationOptions.Builder()
            .duration(/*RECENTER_DURATION*/)
            .build();
    }

/*FOLLOW*/

/*RECENTER*/

/*STOP*/

    static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    public static void main(String[] args) {
/*CHECKS*/
    }
}
'''

CHECKS = '''
        Main plugin = new Main();
        plugin.walk(10.0, 20.0);
        plugin.startCameraFollow();
        plugin.tick();
        require(plugin.mapView.camera.easeCalls == 1, "Ticker should ease once when idle");

        // A recenter flight must survive the ticker for its whole duration.
        plugin.runRecenterAnimation(Main.optionsAt(11.0, 21.0), Main.recenterAnimation());
        require(plugin.isRecenterAnimating, "Recenter must hold the guard");

        int easedBeforeFlight = plugin.mapView.camera.easeCalls;
        // The flight itself supersedes the ticker's last easeTo, so measure from
        // here: only the ticker may not cancel anything while the flight runs.
        int cancellationsBeforeTicks = plugin.mapView.camera.cancellations;
        for (int i = 0; i < 8; i++) {
            plugin.walk(12.0 + i, 22.0);
            plugin.tick();
        }
        require(
            plugin.mapView.camera.easeCalls == easedBeforeFlight,
            "Ticker must not touch the camera while a flight is running"
        );
        require(
            plugin.mapView.camera.cancellations == cancellationsBeforeTicks,
            "Ticker must never cancel the recenter flight"
        );

        // Landing the flight releases the guard and follow picks straight back up.
        plugin.mapView.camera.endActive();
        require(!plugin.isRecenterAnimating, "Flight end must release the guard");
        plugin.walk(30.0, 40.0);
        plugin.tick();
        require(
            plugin.mapView.camera.easeCalls == easedBeforeFlight + 1,
            "Follow must resume once the flight lands"
        );

        // A second tap supersedes the first flight. The stale onAnimationCancel
        // fires on the first listener and must not free the newer guard.
        plugin.runRecenterAnimation(Main.optionsAt(31.0, 41.0), Main.recenterAnimation());
        int cancellationsBeforeSecondTap = plugin.mapView.camera.cancellations;
        plugin.runRecenterAnimation(Main.optionsAt(41.0, 51.0), Main.recenterAnimation());
        require(
            plugin.mapView.camera.cancellations == cancellationsBeforeSecondTap + 1,
            "A second tap must supersede the first flight"
        );
        require(
            plugin.isRecenterAnimating,
            "A superseded flight must not release the newer guard"
        );

        int easedDuringSecondFlight = plugin.mapView.camera.easeCalls;
        plugin.walk(52.0, 62.0);
        plugin.tick();
        require(
            plugin.mapView.camera.easeCalls == easedDuringSecondFlight,
            "Ticker must stay suppressed during the second flight"
        );

        // Tearing follow down must not leave the guard stuck on.
        plugin.stopCameraFollow();
        require(!plugin.isRecenterAnimating, "stopCameraFollow must release the guard");

        // Without the camera plugin the helper must jump and clear its own guard.
        Main fallback = new Main();
        fallback.mapView.cameraPluginAvailable = false;
        fallback.runRecenterAnimation(Main.optionsAt(11.0, 21.0), Main.recenterAnimation());
        require(
            fallback.mapView.mapboxMap.setCameraCalls == 1,
            "Missing camera plugin must fall back to setCamera"
        );
        require(
            !fallback.isRecenterAnimating,
            "The fallback path must not leave the guard stuck"
        );

        System.out.println("Android recenter guard checks passed");
'''

host = (HOST
        .replace('/*INTERVAL*/', str(interval))
        .replace('/*FOLLOW_DURATION*/', str(follow_duration))
        .replace('/*RECENTER_DURATION*/', str(recenter_duration))
        .replace('/*FOLLOW*/', follow)
        .replace('/*RECENTER*/', recenter)
        .replace('/*STOP*/', stop)
        .replace('/*CHECKS*/', CHECKS))

for placeholder in ('INTERVAL', 'FOLLOW_DURATION', 'RECENTER_DURATION', 'FOLLOW', 'RECENTER', 'STOP', 'CHECKS'):
    assert '/*%s*/' % placeholder not in host, 'Unsubstituted placeholder: %s' % placeholder

with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    (directory / 'android' / 'animation').mkdir(parents=True)
    (directory / 'android' / 'animation' / 'Animator.java').write_text(STUBS)
    (directory / 'RecenterChecks.java').write_text(host)
    subprocess.run(
        ['javac', '-d', str(directory / 'out'),
         str(directory / 'android' / 'animation' / 'Animator.java'),
         str(directory / 'RecenterChecks.java')],
        check=True,
    )
    subprocess.run(
        ['java', '-cp', str(directory / 'out'), 'Main'],
        check=True,
    )
