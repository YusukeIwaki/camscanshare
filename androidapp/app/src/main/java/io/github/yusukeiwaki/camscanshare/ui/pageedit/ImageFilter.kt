package io.github.yusukeiwaki.camscanshare.ui.pageedit

import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter

enum class ImageFilter(
    val displayName: String,
    val filterKey: String,
) {
    ORIGINAL("オリジナル", "original"),
    SHARPEN("くっきり", "sharpen"),
    BW("白黒", "bw"),
    MAGIC("マジック", "magic"),
    WHITEBOARD("ホワイトボード", "whiteboard"),
    VIVID("鮮やか", "vivid");

    companion object {
        val DEFAULT = MAGIC

        fun fromKey(key: String): ImageFilter =
            entries.find { it.filterKey == key } ?: DEFAULT
    }
}

/**
 * Create a ColorMatrixColorFilter matching the CSS filter effects from the design spec.
 */
fun ImageFilter.toColorMatrixFilter(): ColorMatrixColorFilter? {
    val matrix = when (this) {
        ImageFilter.ORIGINAL -> return null

        ImageFilter.SHARPEN -> {
            // contrast(1.4) brightness(1.05)
            contrastMatrix(1.4f).apply { postConcat(brightnessMatrix(1.05f)) }
        }

        ImageFilter.BW -> {
            // grayscale(1) contrast(1.3)
            grayscaleMatrix().apply { postConcat(contrastMatrix(1.3f)) }
        }

        ImageFilter.MAGIC -> {
            // brightness(1.4) contrast(2) saturate(0.3)
            brightnessMatrix(1.4f).apply {
                postConcat(contrastMatrix(2.0f))
                postConcat(saturationMatrix(0.3f))
            }
        }

        ImageFilter.WHITEBOARD -> {
            // brightness(1.3) contrast(1.6) saturate(0)
            brightnessMatrix(1.3f).apply {
                postConcat(contrastMatrix(1.6f))
                postConcat(saturationMatrix(0f))
            }
        }

        ImageFilter.VIVID -> {
            // saturate(2) contrast(1.2)
            saturationMatrix(2f).apply { postConcat(contrastMatrix(1.2f)) }
        }
    }
    return ColorMatrixColorFilter(matrix)
}

private fun brightnessMatrix(value: Float): ColorMatrix {
    val offset = 255f * (value - 1f)
    return ColorMatrix(
        floatArrayOf(
            1f, 0f, 0f, 0f, offset,
            0f, 1f, 0f, 0f, offset,
            0f, 0f, 1f, 0f, offset,
            0f, 0f, 0f, 1f, 0f,
        )
    )
}

private fun contrastMatrix(value: Float): ColorMatrix {
    val offset = 128f * (1f - value)
    return ColorMatrix(
        floatArrayOf(
            value, 0f, 0f, 0f, offset,
            0f, value, 0f, 0f, offset,
            0f, 0f, value, 0f, offset,
            0f, 0f, 0f, 1f, 0f,
        )
    )
}

private fun grayscaleMatrix(): ColorMatrix {
    val cm = ColorMatrix()
    cm.setSaturation(0f)
    return cm
}

private fun saturationMatrix(value: Float): ColorMatrix {
    val cm = ColorMatrix()
    cm.setSaturation(value)
    return cm
}
