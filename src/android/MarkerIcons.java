package com.outsystems.mapbox;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
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
    private static final int TIMEOUT_MS = 10000;

    // Reusing one Bitmap instance per look lets Mapbox register a single style image for it.
    private final LruCache<String, Bitmap> pins = new LruCache<>(64);
    private final LruCache<String, Bitmap> images = new LruCache<>(64);
    private final ExecutorService executor = Executors.newFixedThreadPool(3);

    boolean hasImage(String source) {
        return source != null && images.get(source) != null;
    }

    /** Returns the pin for this look, using the cached image when it has loaded. */
    Bitmap pin(int color, boolean isFind, String source) {
        return pin(color, isFind, source, source == null ? null : images.get(source));
    }

    Bitmap pin(int color, boolean isFind, String source, Bitmap image) {
        String key = color + "|" + isFind + "|" + (image == null ? "" : source);
        Bitmap cached = pins.get(key);
        if (cached == null) {
            cached = draw(color, isFind, image);
            pins.put(key, cached);
        }
        return cached;
    }

    /** Loads an allowed image source off the main thread; {@code done} runs on a worker thread. */
    void load(String source, String hosts, Loaded done) {
        executor.execute(() -> {
            Bitmap image = null;
            try {
                byte[] bytes = read(source, hosts);
                image = bytes == null ? null : decode(bytes);
            } catch (Exception | OutOfMemoryError e) {
                Log.w("MapboxPlugin", "Marker image could not be loaded.");
            }
            if (image != null) {
                images.put(source, image);
            }
            done.done(image);
        });
    }

    void shutdown() {
        executor.shutdownNow();
    }

    private static byte[] read(String source, String hosts) throws Exception {
        if (source.startsWith("data:")) {
            byte[] bytes = Base64.decode(source.substring(source.indexOf(',') + 1), Base64.DEFAULT);
            return bytes.length <= MapboxSecurity.MAX_MARKER_IMAGE_BYTES ? bytes : null;
        }

        HttpURLConnection connection = (HttpURLConnection) new URL(source).openConnection();
        try {
            connection.setConnectTimeout(TIMEOUT_MS);
            connection.setReadTimeout(TIMEOUT_MS);
            connection.setRequestProperty("Accept", "image/*");
            // getURL() reflects redirects, so the final host must pass the same policy.
            if (connection.getResponseCode() != HttpURLConnection.HTTP_OK
                    || !MapboxSecurity.markerImageAllowed(connection.getURL().toString(), hosts)
                    || connection.getContentLength() > MapboxSecurity.MAX_MARKER_IMAGE_BYTES) {
                return null;
            }

            try (InputStream in = connection.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    if (out.size() + read > MapboxSecurity.MAX_MARKER_IMAGE_BYTES) {
                        return null;
                    }
                    out.write(buffer, 0, read);
                }
                return out.toByteArray();
            }
        } finally {
            connection.disconnect();
        }
    }

    private static Bitmap decode(byte[] bytes) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
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

    private static Bitmap draw(int pinColor, boolean isFind, Bitmap image) {
        Bitmap bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);

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
