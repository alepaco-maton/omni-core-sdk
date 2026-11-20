package com.omnimdm.omni_mdm.capture

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Captura UI de la Activity anfitriona.
 *
 * En Flutter, [PixelCopy] del Window suele devolver negro porque el contenido
 * vive en [FlutterSurfaceView]/[FlutterTextureView]. Se prioriza esa Surface.
 * Fail-open: nunca lanza a la app anfitriona.
 */
internal object AppUiCapture {
    @Volatile
    private var lastPath: String = "unknown"

    fun capture(activity: Activity?, quality: Int = 70, maxEdge: Int = 1280): JSONObject {
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            return JSONObject()
                .put("ok", false)
                .put("error", "no_activity")
                .put("hint", "Abrí boa_app en primer plano y reintentá CAPTURE_APP_UI")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return JSONObject().put("ok", false).put("error", "pixel_copy_unsupported")
        }

        lastPath = "unknown"
        val bmp = try {
            captureBestBitmap(activity)
        } catch (e: Exception) {
            return JSONObject()
                .put("ok", false)
                .put("error", e.message ?: "capture_failed")
        } ?: return JSONObject()
            .put("ok", false)
            .put("error", "capture_empty")
            .put("hint", "Sin frame válido; mantené la app en foreground")

        if (isMostlyBlack(bmp)) {
            try {
                bmp.recycle()
            } catch (_: Exception) {
            }
            return JSONObject()
                .put("ok", false)
                .put("error", "capture_black_frame")
                .put("capture_path", lastPath)
                .put(
                    "hint",
                    "Frame negro (Flutter Surface no leída o app en background). " +
                        "Dejá boa_app visible en pantalla y reintentá.",
                )
        }

        var scaled: Bitmap? = null
        return try {
            scaled = scaleDown(bmp, maxEdge.coerceIn(320, 2048))
            val q = quality.coerceIn(40, 92)
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, q, out)
            val bytes = out.toByteArray()
            val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            JSONObject()
                .put("ok", true)
                .put("mime", "image/jpeg")
                .put("width_px", scaled.width)
                .put("height_px", scaled.height)
                .put("byte_len", bytes.size)
                .put("data_b64", b64)
                .put("capture_path", lastPath)
                .put("ts", System.currentTimeMillis())
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("error", e.message ?: "encode_failed")
        } finally {
            if (scaled != null && scaled !== bmp) {
                try {
                    scaled.recycle()
                } catch (_: Exception) {
                }
            }
            try {
                bmp.recycle()
            } catch (_: Exception) {
            }
        }
    }

    private class Captured(val bitmap: Bitmap, val path: String)

    private fun captureBestBitmap(activity: Activity): Bitmap? {
        val root = activity.window?.decorView ?: return null
        for (sv in findSurfaceViews(root)) {
            val c = pixelCopySurfaceView(activity, sv, "flutter_surface") ?: continue
            if (!isMostlyBlack(c.bitmap)) {
                lastPath = c.path
                return c.bitmap
            }
            c.bitmap.recycle()
        }
        for (tv in findTextureViews(root)) {
            val c = textureViewBitmap(tv, "flutter_texture") ?: continue
            if (!isMostlyBlack(c.bitmap)) {
                lastPath = c.path
                return c.bitmap
            }
            c.bitmap.recycle()
        }
        val win = pixelCopyWindow(activity, "window")
        if (win != null && !isMostlyBlack(win.bitmap)) {
            lastPath = win.path
            return win.bitmap
        }
        win?.bitmap?.recycle()
        val soft = softwareDraw(root, "software_draw")
        if (soft != null && !isMostlyBlack(soft.bitmap)) {
            lastPath = soft.path
            return soft.bitmap
        }
        soft?.bitmap?.recycle()
        val fallback = pixelCopyWindow(activity, "window")
        if (fallback != null) lastPath = fallback.path
        return fallback?.bitmap
    }

    private fun pixelCopySurfaceView(activity: Activity, sv: SurfaceView, path: String): Captured? {
        val w = sv.width
        val h = sv.height
        if (w <= 0 || h <= 0) return null
        if (!sv.holder.surface.isValid) return null
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val code = AtomicInteger(PixelCopy.ERROR_SOURCE_INVALID)
        val latch = CountDownLatch(1)
        try {
            activity.runOnUiThread {
                try {
                    PixelCopy.request(sv, bmp, { result ->
                        code.set(result)
                        latch.countDown()
                    }, Handler(Looper.getMainLooper()))
                } catch (e: Exception) {
                    code.set(-1)
                    latch.countDown()
                }
            }
            if (!latch.await(6, TimeUnit.SECONDS) || code.get() != PixelCopy.SUCCESS) {
                bmp.recycle()
                return null
            }
            return Captured(bmp, path)
        } catch (_: Exception) {
            try {
                bmp.recycle()
            } catch (_: Exception) {
            }
            return null
        }
    }

    private fun textureViewBitmap(tv: TextureView, path: String): Captured? {
        return try {
            if (!tv.isAvailable || tv.width <= 0 || tv.height <= 0) return null
            val bmp = tv.getBitmap(tv.width, tv.height) ?: return null
            Captured(bmp, path)
        } catch (_: Exception) {
            null
        }
    }

    private fun pixelCopyWindow(activity: Activity, path: String): Captured? {
        val window = activity.window ?: return null
        val view = window.decorView
        val w = view.width
        val h = view.height
        if (w <= 0 || h <= 0) return null
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val code = AtomicInteger(PixelCopy.ERROR_SOURCE_INVALID)
        val latch = CountDownLatch(1)
        val dest = Rect(0, 0, w, h)
        try {
            activity.runOnUiThread {
                try {
                    PixelCopy.request(window, dest, bmp, { result ->
                        code.set(result)
                        latch.countDown()
                    }, Handler(Looper.getMainLooper()))
                } catch (_: Exception) {
                    code.set(-1)
                    latch.countDown()
                }
            }
            if (!latch.await(6, TimeUnit.SECONDS) || code.get() != PixelCopy.SUCCESS) {
                bmp.recycle()
                return null
            }
            return Captured(bmp, path)
        } catch (_: Exception) {
            try {
                bmp.recycle()
            } catch (_: Exception) {
            }
            return null
        }
    }

    private fun softwareDraw(view: View, path: String): Captured? {
        val w = view.width
        val h = view.height
        if (w <= 0 || h <= 0) return null
        return try {
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            view.draw(canvas)
            Captured(bmp, path)
        } catch (_: Exception) {
            null
        }
    }

    private fun findSurfaceViews(root: View): List<SurfaceView> {
        val out = mutableListOf<SurfaceView>()
        fun walk(v: View) {
            if (v is SurfaceView) out.add(v)
            if (v is ViewGroup) {
                for (i in 0 until v.childCount) walk(v.getChildAt(i))
            }
        }
        walk(root)
        // Prefer Flutter* surfaces first
        return out.sortedByDescending { it.javaClass.name.contains("Flutter", ignoreCase = true) }
    }

    private fun findTextureViews(root: View): List<TextureView> {
        val out = mutableListOf<TextureView>()
        fun walk(v: View) {
            if (v is TextureView) out.add(v)
            if (v is ViewGroup) {
                for (i in 0 until v.childCount) walk(v.getChildAt(i))
            }
        }
        walk(root)
        return out.sortedByDescending { it.javaClass.name.contains("Flutter", ignoreCase = true) }
    }

    /** Muestreo: si >92% de píxeles son casi negros, se considera frame inválido. */
    private fun isMostlyBlack(bmp: Bitmap): Boolean {
        val w = bmp.width
        val h = bmp.height
        if (w <= 0 || h <= 0) return true
        val stepX = (w / 24).coerceAtLeast(1)
        val stepY = (h / 24).coerceAtLeast(1)
        var total = 0
        var dark = 0
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val c = bmp.getPixel(x, y)
                val r = Color.red(c)
                val g = Color.green(c)
                val b = Color.blue(c)
                total++
                if (r < 18 && g < 18 && b < 18) dark++
                x += stepX
            }
            y += stepY
        }
        if (total == 0) return true
        return dark.toDouble() / total.toDouble() >= 0.92
    }

    private fun scaleDown(src: Bitmap, maxEdge: Int): Bitmap {
        val max = maxOf(src.width, src.height)
        if (max <= maxEdge) return src
        val scale = maxEdge.toFloat() / max.toFloat()
        val nw = (src.width * scale).toInt().coerceAtLeast(1)
        val nh = (src.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, nw, nh, true)
    }
}
