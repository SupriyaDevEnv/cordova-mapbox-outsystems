"""Execute the production native bound parsers without requiring Mapbox binaries."""
from pathlib import Path
import subprocess
import tempfile

android = Path('src/android/MapboxPluginEntry.java').read_text()
java_helper = android.split('    private static Double optionalCameraZoom', 1)[1].split(
    '    private void initialize', 1)[0]
ios = Path('src/ios/MapboxPlugin.swift').read_text()
swift_helper = ios.split('    private func optionalCameraZoom', 1)[1].split(
    '    @objc(initialize:)', 1)[0]

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    java = root / 'ZoomTest.java'
    java.write_text('''
import java.util.*;
public class ZoomTest {
    static class JSONObject {
        final Map<String, Object> values = new HashMap<>();
        boolean isNull(String key) { return values.get(key) == null; }
        Object opt(String key) { return values.get(key); }
    }
    private static Double optionalCameraZoom''' + java_helper + '''
    public static void main(String[] args) {
        for (String key : new String[] {"minZoom", "maxZoom"}) {
            JSONObject options = new JSONObject();
            if (optionalCameraZoom(options, key) != null) throw new AssertionError("missing");
            options.values.put(key, null);
            if (optionalCameraZoom(options, key) != null) throw new AssertionError("null");
            for (Number value : new Number[] {0, 1, 18.25, 25.5}) {
                options.values.put(key, value);
                if (optionalCameraZoom(options, key) != value.doubleValue()) throw new AssertionError(value);
            }
            for (Object value : new Object[] {true, false, "18", "", new ArrayList<>(),
                    new HashMap<>(), Double.NaN, Double.POSITIVE_INFINITY,
                    Double.NEGATIVE_INFINITY, -0.01, 25.5001}) {
                options.values.put(key, value);
                try {
                    optionalCameraZoom(options, key);
                    throw new AssertionError("accepted " + value);
                } catch (IllegalArgumentException error) {
                    if (!error.getMessage().equals(key + " must be a finite number between 0 and 25.5."))
                        throw new AssertionError(error);
                }
            }
        }
        System.out.println("Android camera zoom validation passed");
    }
}
''')
    subprocess.run(['javac', '-d', directory, str(java)], check=True)
    subprocess.run(['java', '-cp', directory, 'ZoomTest'], check=True)

    swift = root / 'main.swift'
    swift.write_text('''import Foundation
import CoreFoundation
func optionalCameraZoom''' + swift_helper + '''
for key in ["minZoom", "maxZoom"] {
    let absent = try optionalCameraZoom([:], key)
    let null = try optionalCameraZoom([key: NSNull()], key)
    assert(absent == nil && null == nil)
    for value in [0.0, 1.0, 18.25, 25.5] {
        let result = try optionalCameraZoom([key: NSNumber(value: value)], key)
        assert(result == CGFloat(value))
    }
    let invalid: [Any] = [true, false, "18", "", [Any](), [String: Any](),
        Double.nan, Double.infinity, -Double.infinity, -0.01, 25.5001]
    for value in invalid {
        do {
            _ = try optionalCameraZoom([key: value], key)
            fatalError("accepted \\(value)")
        } catch {
            assert(error.localizedDescription == "\\(key) must be a finite number between 0 and 25.5.")
        }
    }
    // Exercise actual JSON bridging, particularly boolean versus numeric 0/1.
    let json = "{\\"zero\\":0,\\"one\\":1,\\"boolean\\":true}"
    let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    for name in ["zero", "one"] {
        _ = try optionalCameraZoom([key: values[name]!], key)
    }
    do {
        _ = try optionalCameraZoom([key: values["boolean"]!], key)
        fatalError("accepted JSON boolean")
    } catch {}
}
print("iOS camera zoom validation passed")
''')
    binary = root / 'zoom-test'
    subprocess.run(['swiftc', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
