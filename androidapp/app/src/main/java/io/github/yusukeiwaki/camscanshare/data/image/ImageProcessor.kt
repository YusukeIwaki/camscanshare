package io.github.yusukeiwaki.camscanshare.data.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import androidx.camera.core.ImageProxy
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Handles image processing operations: EXIF rotation correction, filter application.
 * Designed to be testable — filter matrix logic is pure and can be unit tested.
 */
@Singleton
class ImageProcessor @Inject constructor() {

    /**
     * Convert an ImageProxy to a correctly-oriented Bitmap.
     * CameraX's ImageProxy.toBitmap() does NOT apply rotation,
     * so we manually rotate based on imageInfo.rotationDegrees.
     */
    fun toBitmapWithCorrectRotation(imageProxy: ImageProxy): Bitmap {
        val bitmap = imageProxy.toBitmap()
        val rotationDegrees = imageProxy.imageInfo.rotationDegrees
        return if (rotationDegrees != 0) {
            rotateBitmap(bitmap, rotationDegrees.toFloat())
        } else {
            bitmap
        }
    }

    fun rotateBitmap(source: Bitmap, degrees: Float): Bitmap {
        if (degrees == 0f) return source
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    }

    /**
     * Apply a color filter to a bitmap, returning a new bitmap.
     */
    fun applyFilter(source: Bitmap, filterKey: String): Bitmap {
        val colorMatrix = getColorMatrix(filterKey) ?: return source
        val result = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        val paint = Paint().apply {
            colorFilter = ColorMatrixColorFilter(colorMatrix)
        }
        canvas.drawBitmap(source, 0f, 0f, paint)
        return result
    }

    /**
     * Get the ColorMatrix for a given filter key. Returns null for "original".
     * Pure function — can be unit tested directly.
     */
    fun getColorMatrix(filterKey: String): ColorMatrix? = when (filterKey) {
        "original" -> null
        "sharpen" -> contrastMatrix(1.4f).apply { postConcat(brightnessMatrix(1.05f)) }
        "bw" -> grayscaleMatrix().apply { postConcat(contrastMatrix(1.3f)) }
        "magic" -> brightnessMatrix(1.4f).apply {
            postConcat(contrastMatrix(2.0f))
            postConcat(saturationMatrix(0.3f))
        }
        "whiteboard" -> brightnessMatrix(1.3f).apply {
            postConcat(contrastMatrix(1.6f))
            postConcat(saturationMatrix(0f))
        }
        "vivid" -> saturationMatrix(2f).apply { postConcat(contrastMatrix(1.2f)) }
        else -> null
    }

    companion object {
        fun brightnessMatrix(value: Float): ColorMatrix {
            val offset = 255f * (value - 1f)
            return ColorMatrix(floatArrayOf(
                1f, 0f, 0f, 0f, offset,
                0f, 1f, 0f, 0f, offset,
                0f, 0f, 1f, 0f, offset,
                0f, 0f, 0f, 1f, 0f,
            ))
        }

        fun contrastMatrix(value: Float): ColorMatrix {
            val offset = 128f * (1f - value)
            return ColorMatrix(floatArrayOf(
                value, 0f, 0f, 0f, offset,
                0f, value, 0f, 0f, offset,
                0f, 0f, value, 0f, offset,
                0f, 0f, 0f, 1f, 0f,
            ))
        }

        fun grayscaleMatrix(): ColorMatrix =
            ColorMatrix().apply { setSaturation(0f) }

        fun saturationMatrix(value: Float): ColorMatrix =
            ColorMatrix().apply { setSaturation(value) }
    }
}
