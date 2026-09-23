"""Exercise the actual dispatch helpers against callbacks from an old session."""
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    source = Path('src/ios/MapboxPlugin.swift').read_text()
    start = source.index('    func runForSession(')
    end = source.index('    private var mapView:', start)
    swift = directory / 'main.swift'
    swift.write_text('''import Foundation
class TestPlugin {
    var sessionGeneration: UInt64 = 0
''' + source[start:end] + '''
}
let plugin = TestPlugin()
var callbacks = 0
plugin.runForSession { callbacks += 100 }
plugin.sessionGeneration += 1
plugin.runForSession { callbacks += 1 }
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(callbacks == 1, "Old session callback must be discarded")
print("iOS session callback isolation passed")
''')
    subprocess.run(['swiftc', str(swift), '-o', str(directory / 'session-test')], check=True)
    subprocess.run([str(directory / 'session-test')], check=True)

    source = Path('src/android/MapboxPluginEntry.java').read_text()
    start = source.index('    private void runForSession(')
    end = source.index('    private FrameLayout rootView;', start)
    java = directory / 'SessionTest.java'
    java.write_text('''import java.util.*;
public class SessionTest {
    long sessionGeneration = 0;
    static class Cordova {
        List<Runnable> queue = new ArrayList<>();
        Cordova getActivity() { return this; }
        void runOnUiThread(Runnable work) { queue.add(work); }
    }
    Cordova cordova = new Cordova();
''' + source[start:end] + '''
    public static void main(String[] args) {
        SessionTest plugin = new SessionTest();
        int[] callbacks = {0};
        plugin.runForSession(() -> callbacks[0] += 100);
        plugin.sessionGeneration++;
        plugin.runForSession(() -> callbacks[0]++);
        plugin.cordova.queue.forEach(Runnable::run);
        if (callbacks[0] != 1) throw new AssertionError("Old session callback must be discarded");
        System.out.println("Android session callback isolation passed");
    }
}
''')
    subprocess.run(['javac', '-d', temp, str(java)], check=True)
    subprocess.run(['java', '-cp', temp, 'SessionTest'], check=True)
