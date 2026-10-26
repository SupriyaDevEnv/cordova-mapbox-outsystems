package com.outsystems.mapbox;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.util.Base64;
import android.util.Log;
import android.util.LruCache;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Draws marker pins and loads the images shown inside them. */
final class MarkerIcons {
    static final int DEFAULT_PIN_COLOR = Color.rgb(220, 38, 38);
    static final int FIND_PIN_COLOR = Color.rgb(37, 99, 235);

    static final int PHOTO_PIN_COLOR = Color.rgb(221, 0, 29);

    interface Loaded {
        void done(Bitmap image);
    }

    private static final int WIDTH = 72;
    private static final int HEIGHT = 96;
    private static final float CENTER_X = WIDTH / 2.0f;
    private static final float HEAD_Y = 32.0f;
    private static final float HEAD_RADIUS = 25.0f;
    private static final float IMAGE_RING_RADIUS = 21.0f;
    private static final float IMAGE_RADIUS = 19.0f;
    private static final int IMAGE_DECODE_SIZE = 128;
    private static final int PHOTO_WIDTH = 52;
    private static final int PHOTO_HEIGHT = 63;
    private static final float PHOTO_CENTER_X = 26.0f;
    private static final float PHOTO_CENTER_Y = 26.0f;
    private static final float PHOTO_RADIUS = 14.5f;
    private static final int PHOTO_PLACEHOLDER_COLOR = 0xFFF3F4F6;
    private static final int TIMEOUT_MS = 10000;
    private static final int MAX_REDIRECTS = 3;
    // A small, highly compressed file can declare enormous dimensions; refuse those before decoding.
    private static final int MAX_IMAGE_SIDE = 4096;
    private static final long MAX_IMAGE_PIXELS = 4_000_000L;
    private static final int IMAGE_CACHE_BYTES = 8 * 1024 * 1024;

    // Reusing one Bitmap instance per look lets Mapbox register a single style image for it.
    private final LruCache<String, Bitmap> pins = new LruCache<>(64);
    // Sized in bytes so a few large images cannot hold most of the heap.
    private final LruCache<String, Bitmap> images = new LruCache<String, Bitmap>(IMAGE_CACHE_BYTES) {
        @Override
        protected int sizeOf(String key, Bitmap value) {
            return value.getByteCount();
        }
    };
    private ExecutorService executor = Executors.newFixedThreadPool(3);
    private final java.util.Set<HttpURLConnection> connections = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private volatile long generation;

    synchronized void cancelAll() {
        generation++;
        executor.shutdownNow();
        for (HttpURLConnection connection : connections) connection.disconnect();
        connections.clear();
        executor = Executors.newFixedThreadPool(3);
        pins.evictAll();
        images.evictAll();
    }

    boolean hasImage(String source) {
        return source != null && images.get(source) != null;
    }

    /** Returns the pin for this look, using the cached image when it has loaded. */
    Bitmap pin(int color, boolean isFind, String source, float density) {
        return pin(color, isFind, source, source == null ? null : images.get(source), density);
    }

    Bitmap pin(int color, boolean isFind, String source, Bitmap image, float density) {
        density = validDensity(density);
        String key = density + "|" + color + "|" + isFind + "|" + (image == null ? "" : source);
        Bitmap cached = pins.get(key);
        if (cached == null) {
            cached = draw(color, isFind, image, density);
            pins.put(key, cached);
        }
        return cached;
    }

    /** Loads an allowed image source off the main thread; {@code done} runs on a worker thread. */
    synchronized void load(String source, String hosts, Loaded done) {
        final long requestGeneration = generation;
        executor.execute(() -> {
            Bitmap image = null;
            try {
                byte[] bytes = read(source, hosts, requestGeneration);
                image = bytes == null ? null : decode(bytes);
            } catch (Exception | OutOfMemoryError e) {
                Log.w("MapboxPlugin", "Marker image could not be loaded.");
            }
            synchronized (this) {
                if (requestGeneration != generation) return;
                if (image != null) images.put(source, image);
                done.done(image);
            }
        });
    }

    void shutdown() {
        executor.shutdownNow();
    }

    /** Larger "photo" pin (pinStyle "photo"); shows a grey disc until the image has loaded. */
    Bitmap photoPin(int color, String source, float density) {
        return photoPin(color, source, source == null ? null : images.get(source), density);
    }

    Bitmap photoPin(int color, String source, Bitmap image, float density) {
        density = validDensity(density);
        String key = "photo|" + density + "|" + color + "|" + (image == null ? "" : source);
        Bitmap cached = pins.get(key);
        if (cached == null) {
            cached = drawPhoto(color, image, density);
            pins.put(key, cached);
        }
        return cached;
    }

    private static Bitmap drawPhoto(int pinColor, Bitmap image, float density) {
        // Artwork is authored on a 52x63 grid and rendered at 2x so that iconSize=0.5
        // shows it at 52x63 dp, like the classic pin does with its 72x96 canvas.
        Bitmap bitmap = Bitmap.createBitmap(Math.max(1, Math.round(PHOTO_WIDTH * 2 * density)),
            Math.max(1, Math.round(PHOTO_HEIGHT * 2 * density)), Bitmap.Config.ARGB_8888);
        bitmap.setDensity(Bitmap.DENSITY_NONE);
        Canvas canvas = new Canvas(bitmap);
        canvas.scale(density * 2, density * 2);

        // Teardrop: circular head with a concave neck narrowing to a rounded tip.
        Path pinPath = new Path();
        pinPath.moveTo(8.75f, 44.0f);
        pinPath.arcTo(new RectF(1.0f, 1.0f, 51.0f, 51.0f), 133.8f, 272.4f);
        pinPath.cubicTo(36.95f, 50.0f, 29.0f, 53.75f, 29.0f, 60.0f);
        pinPath.cubicTo(29.0f, 62.75f, 23.0f, 62.75f, 23.0f, 60.0f);
        pinPath.cubicTo(23.0f, 53.75f, 15.05f, 50.0f, 8.75f, 44.0f);
        pinPath.close();

        Paint pinPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        pinPaint.setColor(pinColor);
        canvas.drawPath(pinPath, pinPaint);

        if (image == null) {
            Paint discPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
            discPaint.setColor(PHOTO_PLACEHOLDER_COLOR);
            canvas.drawCircle(PHOTO_CENTER_X, PHOTO_CENTER_Y, PHOTO_RADIUS, discPaint);
            return bitmap;
        }

        float scale = 2 * PHOTO_RADIUS / Math.min(image.getWidth(), image.getHeight());
        Matrix matrix = new Matrix();
        matrix.setScale(scale, scale);
        matrix.postTranslate(
            PHOTO_CENTER_X - image.getWidth() * scale / 2,
            PHOTO_CENTER_Y - image.getHeight() * scale / 2
        );
        BitmapShader shader = new BitmapShader(image, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP);
        shader.setLocalMatrix(matrix);
        Paint imagePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        imagePaint.setShader(shader);
        canvas.drawCircle(PHOTO_CENTER_X, PHOTO_CENTER_Y, PHOTO_RADIUS, imagePaint);
        return bitmap;
    }

    private byte[] read(String source, String hosts, long requestGeneration) throws Exception {
        if (requestGeneration != generation || Thread.currentThread().isInterrupted()) return null;
        if (source.startsWith("data:")) {
            byte[] bytes = Base64.decode(source.substring(source.indexOf(',') + 1), Base64.DEFAULT);
            return bytes.length <= MapboxSecurity.MAX_MARKER_IMAGE_BYTES ? bytes : null;
        }

        String location = source;
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            // Check each hop before connecting. Automatic redirects would contact an
            // unapproved host before its URL could be checked.
            if (!MapboxSecurity.markerImageAllowed(location, hosts)) return null;
            HttpURLConnection connection = (HttpURLConnection) new URL(location).openConnection();
            connections.add(connection);
            try {
                if (requestGeneration != generation || Thread.currentThread().isInterrupted()) return null;
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(TIMEOUT_MS);
                connection.setReadTimeout(TIMEOUT_MS);
                connection.setRequestProperty("Accept", "image/*");
                int status = connection.getResponseCode();
                if (status >= 300 && status < 400 && status != HttpURLConnection.HTTP_NOT_MODIFIED) {
                    String next = connection.getHeaderField("Location");
                    if (next == null) return null;
                    location = new URL(connection.getURL(), next).toString();
                    continue;
                }
                if (status != HttpURLConnection.HTTP_OK
                        || connection.getContentLength() > MapboxSecurity.MAX_MARKER_IMAGE_BYTES) {
                    return null;
                }

                try (InputStream in = connection.getInputStream()) {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        if (requestGeneration != generation || Thread.currentThread().isInterrupted()) return null;
                        if (out.size() + read > MapboxSecurity.MAX_MARKER_IMAGE_BYTES) {
                            return null;
                        }
                        out.write(buffer, 0, read);
                    }
                    return out.toByteArray();
                }
            } finally {
                connections.remove(connection);
                connection.disconnect();
            }
        }
        return null;
    }

    private static Bitmap decode(byte[] bytes) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0
                || bounds.outWidth > MAX_IMAGE_SIDE || bounds.outHeight > MAX_IMAGE_SIDE
                || (long) bounds.outWidth * bounds.outHeight > MAX_IMAGE_PIXELS) {
            return null;
        }

        int sampleSize = 1;
        while (bounds.outWidth / (sampleSize * 2) >= IMAGE_DECODE_SIZE
                && bounds.outHeight / (sampleSize * 2) >= IMAGE_DECODE_SIZE) {
            sampleSize *= 2;
        }

        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sampleSize;
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
    }

    private static float validDensity(float density) {
        return density > 0 && !Float.isNaN(density) && !Float.isInfinite(density) ? density : 1.0f;
    }

    private static Bitmap draw(int pinColor, boolean isFind, Bitmap image, float density) {
        // Annotation images default to the map's pixel ratio. Supply physical
        // pixels for our logical 72x96 artwork; iconSize=0.5 then yields 36x48 dp.
        Bitmap bitmap = Bitmap.createBitmap(Math.max(1, Math.round(WIDTH * density)),
            Math.max(1, Math.round(HEIGHT * density)), Bitmap.Config.ARGB_8888);
        bitmap.setDensity(Bitmap.DENSITY_NONE);
        Canvas canvas = new Canvas(bitmap);
        canvas.scale(density, density);

        Paint shadowPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        shadowPaint.setColor(Color.argb(65, 0, 0, 0));
        canvas.drawOval(CENTER_X - 16.0f, HEIGHT - 16.0f, CENTER_X + 16.0f, HEIGHT - 8.0f, shadowPaint);

        Path pinPath = new Path();
        pinPath.addCircle(CENTER_X, HEAD_Y, HEAD_RADIUS, Path.Direction.CW);
        pinPath.moveTo(CENTER_X - 14.0f, HEAD_Y + 19.0f);
        pinPath.quadTo(CENTER_X - 5.0f, HEAD_Y + 52.0f, CENTER_X, HEIGHT - 10.0f);
        pinPath.quadTo(CENTER_X + 5.0f, HEAD_Y + 52.0f, CENTER_X + 14.0f, HEAD_Y + 19.0f);
        pinPath.close();

        Paint pinPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        pinPaint.setColor(pinColor);
        canvas.drawPath(pinPath, pinPaint);

        Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        strokePaint.setStyle(Paint.Style.STROKE);
        strokePaint.setStrokeWidth(3.0f);
        strokePaint.setColor(Color.WHITE);
        canvas.drawPath(pinPath, strokePaint);

        Paint centerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        centerPaint.setColor(Color.WHITE);

        if (image != null) {
            canvas.drawCircle(CENTER_X, HEAD_Y, IMAGE_RING_RADIUS, centerPaint);

            // Center-crop the image into the pin head.
            float scale = 2 * IMAGE_RADIUS / Math.min(image.getWidth(), image.getHeight());
            Matrix matrix = new Matrix();
            matrix.setScale(scale, scale);
            matrix.postTranslate(
                CENTER_X - image.getWidth() * scale / 2,
                HEAD_Y - image.getHeight() * scale / 2
            );
            BitmapShader shader = new BitmapShader(image, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP);
            shader.setLocalMatrix(matrix);

            Paint imagePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
            imagePaint.setShader(shader);
            canvas.drawCircle(CENTER_X, HEAD_Y, IMAGE_RADIUS, imagePaint);
            return bitmap;
        }

        canvas.drawCircle(CENTER_X, HEAD_Y, 10.0f, centerPaint);

        Paint innerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        innerPaint.setStyle(Paint.Style.STROKE);
        innerPaint.setStrokeWidth(2.0f);
        innerPaint.setColor(Color.argb(40, 0, 0, 0));
        canvas.drawCircle(CENTER_X, HEAD_Y, 10.0f, innerPaint);

        if (isFind) {
            Paint findIconPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
            findIconPaint.setColor(pinColor);
            findIconPaint.setStyle(Paint.Style.STROKE);
            findIconPaint.setStrokeWidth(2.5f);
            findIconPaint.setStrokeCap(Paint.Cap.ROUND);
            canvas.drawCircle(CENTER_X - 1.0f, HEAD_Y - 1.0f, 4.0f, findIconPaint);
            canvas.drawLine(CENTER_X + 2.0f, HEAD_Y + 2.0f, CENTER_X + 7.0f, HEAD_Y + 7.0f, findIconPaint);
        }

        return bitmap;
    }

    /** Parses #RRGGBB or #RRGGBBAA, matching the iOS color option format. */
    static int parseColor(String value, int fallback) {
        if (value == null) {
            return fallback;
        }
        String hex = value.trim();
        if (hex.startsWith("#")) {
            hex = hex.substring(1);
        }
        if ((hex.length() != 6 && hex.length() != 8) || !hex.matches("[0-9A-Fa-f]+")) {
            return fallback;
        }
        try {
            long parsed = Long.parseLong(hex, 16);
            if (hex.length() == 6) {
                return (int) (0xFF000000L | parsed);
            }
            return (int) (((parsed & 0xFF) << 24) | (parsed >>> 8));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
