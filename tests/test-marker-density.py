"""Run actual pin cache and bitmap/canvas sizing code in an isolated Java host.

The host checks logical dimensions across densities, not GPU rendering.
"""
from pathlib import Path
import subprocess
import tempfile

source = Path('src/android/MarkerIcons.java').read_text()
constants = source[source.index('    private static final int WIDTH'):source.index('    // Reusing')]
pins = source[source.index('    Bitmap pin('):source.index('    /** Loads an allowed')]
drawing = source[source.index('    private static float validDensity('):source.index('        Paint shadowPaint')]
host = '''import java.util.*;
public class MarkerDensityTest {
    static class Bitmap {
        static final int DENSITY_NONE = 0;
        enum Config { ARGB_8888 }
        int width, height, density;
        float scaleX, scaleY;
        static Bitmap createBitmap(int width, int height, Config config) {
            Bitmap result = new Bitmap(); result.width = width; result.height = height; return result;
        }
        void setDensity(int value) { density = value; }
    }
    static class Canvas {
        final Bitmap bitmap;
        Canvas(Bitmap value) { bitmap = value; }
        void scale(float x, float y) { bitmap.scaleX = x; bitmap.scaleY = y; }
    }
    final Map<String, Bitmap> pins = new HashMap<>();
    final Map<String, Bitmap> images = new HashMap<>();
''' + constants + pins + drawing + '''
        return bitmap;
    }
    static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        MarkerDensityTest icons = new MarkerDensityTest();
        for (float ratio : new float[] {0.75f, 1f, 1.5f, 2f, 2.625f, 2.75f, 3f, 3.5f, 4f}) {
            for (boolean find : new boolean[] {false, true}) {
                Bitmap plain = icons.pin(123, find, null, ratio);
                Bitmap image = new Bitmap();
                Bitmap loaded = icons.pin(123, find, "photo", image, ratio);
                for (Bitmap pin : new Bitmap[] {plain, loaded}) {
                    // Mapbox image scale defaults to map pixel ratio, iconSize remains 0.5.
                    check(Math.abs(pin.width * 0.5 / ratio - 36) <= 0.5 / ratio, "Width varies by density");
                    check(Math.abs(pin.height * 0.5 / ratio - 48) <= 0.5 / ratio, "Height varies by density");
                    check(pin.scaleX == ratio && pin.scaleY == ratio, "Artwork not scaled with bitmap");
                    check(pin.density == Bitmap.DENSITY_NONE, "Implicit Android bitmap scaling enabled");
                }
                check(plain == icons.pin(123, find, null, ratio), "Plain pin cache miss");
                icons.images.put("photo", image);
                check(loaded == icons.pin(123, find, "photo", ratio), "Loaded image path differs");
            }
        }
        check(icons.pin(123, false, null, 1f) != icons.pin(123, false, null, 3f), "Density missing from cache key");
        for (float invalid : new float[] {0f, -1f, Float.NaN, Float.POSITIVE_INFINITY}) {
            check(icons.pin(123, false, null, invalid) == icons.pin(123, false, null, 1f), "Invalid density fallback");
        }
        System.out.println("Android marker density/cache regression passed");
    }
}
'''
with tempfile.TemporaryDirectory() as temp:
    java = Path(temp) / 'MarkerDensityTest.java'
    java.write_text(host)
    subprocess.run(['javac', '-d', temp, str(java)], check=True)
    subprocess.run(['java', '-cp', temp, 'MarkerDensityTest'], check=True)
