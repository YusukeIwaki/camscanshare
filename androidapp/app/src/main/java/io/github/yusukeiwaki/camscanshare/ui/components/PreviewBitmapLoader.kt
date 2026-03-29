package io.github.yusukeiwaki.camscanshare.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import io.github.yusukeiwaki.camscanshare.data.image.FilterRenderPlan
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

@Composable
fun rememberPreviewBitmap(
    imagePath: String,
    rotationDegrees: Float,
    renderPlan: FilterRenderPlan,
    maxDimension: Int,
): Bitmap? {
    val cacheBitmapFilterKey = remember(renderPlan.bitmapFilterKey) {
        renderPlan.bitmapFilterKey ?: "base"
    }
    val cacheKey = remember(imagePath, rotationDegrees, cacheBitmapFilterKey, maxDimension) {
        val lastModified = File(imagePath).lastModified()
        "$imagePath|$lastModified|$rotationDegrees|$cacheBitmapFilterKey|$maxDimension"
    }
    val initial = remember(cacheKey) { PreviewBitmapCache.get(cacheKey) }
    var bitmap by remember(cacheKey) { mutableStateOf(initial) }

    LaunchedEffect(cacheKey) {
        bitmap = initial
        if (bitmap != null) return@LaunchedEffect
        bitmap = PreviewBitmapLoader.load(
            cacheKey = cacheKey,
            imagePath = imagePath,
            rotationDegrees = rotationDegrees,
            bitmapFilterKey = renderPlan.bitmapFilterKey,
            maxDimension = maxDimension,
        )
    }
    return bitmap
}

fun previewColorMatrix(filterKey: String?) = filterKey?.let { PreviewBitmapLoader.imageProcessor.getColorMatrix(it) }

private object PreviewBitmapLoader {
    val imageProcessor by lazy { ImageProcessor() }

    suspend fun load(
        cacheKey: String,
        imagePath: String,
        rotationDegrees: Float,
        bitmapFilterKey: String?,
        maxDimension: Int,
    ): Bitmap? = withContext(Dispatchers.IO) {
        PreviewBitmapCache.get(cacheKey)?.let { return@withContext it }

        val decoded = decodeSampledBitmap(imagePath, maxDimension) ?: return@withContext null
        val rotated = imageProcessor.rotateBitmap(decoded, rotationDegrees)
        if (rotated !== decoded) decoded.recycle()

        val prepared = scaleDownIfNeeded(rotated, maxDimension)
        if (prepared !== rotated) rotated.recycle()

        val result = if (bitmapFilterKey != null) {
            imageProcessor.applyFilter(prepared, bitmapFilterKey).also { filtered ->
                if (filtered !== prepared) prepared.recycle()
            }
        } else {
            prepared
        }

        PreviewBitmapCache.put(cacheKey, result)
        result
    }

    private fun decodeSampledBitmap(imagePath: String, maxDimension: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(imagePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val sampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight, maxDimension)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(imagePath, options)
    }

    private fun calculateInSampleSize(width: Int, height: Int, maxDimension: Int): Int {
        var sampleSize = 1
        while (max(width, height) / sampleSize > maxDimension * 2) {
            sampleSize *= 2
        }
        return sampleSize
    }

    private fun scaleDownIfNeeded(bitmap: Bitmap, maxDimension: Int): Bitmap {
        val largestSide = max(bitmap.width, bitmap.height)
        if (largestSide <= maxDimension) return bitmap

        val scale = maxDimension.toFloat() / largestSide.toFloat()
        val scaledWidth = (bitmap.width * scale).roundToInt().coerceAtLeast(1)
        val scaledHeight = (bitmap.height * scale).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)
    }
}

private object PreviewBitmapCache {
    private val cache = object : LruCache<String, Bitmap>(cacheSizeKb()) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount / 1024
    }

    fun get(key: String): Bitmap? = synchronized(cache) { cache.get(key) }

    fun put(key: String, bitmap: Bitmap) {
        synchronized(cache) {
            if (cache.get(key) == null) {
                cache.put(key, bitmap)
            }
        }
    }

    private fun cacheSizeKb(): Int {
        val maxMemoryKb = (Runtime.getRuntime().maxMemory() / 1024L).toInt()
        return (maxMemoryKb / 8).coerceAtLeast(16 * 1024)
    }
}
