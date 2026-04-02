package io.github.yusukeiwaki.camscanshare.data.preview

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import io.github.yusukeiwaki.camscanshare.data.file.PreviewFileStorage
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max
import kotlin.math.roundToInt

@Singleton
class WorkingPreviewManager @Inject constructor(
    private val imageFileStorage: ImageFileStorage,
    private val previewFileStorage: PreviewFileStorage,
    private val imageProcessor: ImageProcessor,
) {
    suspend fun getOrCompute(
        pageId: Long,
        sourceRelativePath: String,
        filterKey: String,
        rotationDegrees: Int,
    ): Bitmap? = withContext(Dispatchers.IO) {
        previewFileStorage.loadWorking(pageId, filterKey, rotationDegrees)?.let {
            return@withContext it
        }

        val sourceAbsPath = imageFileStorage.getAbsolutePath(sourceRelativePath)
        if (!File(sourceAbsPath).exists()) return@withContext null

        val decoded = decodeSampledBitmap(sourceAbsPath, MAX_DIMENSION) ?: return@withContext null
        val rotated = if (rotationDegrees != 0) {
            imageProcessor.rotateBitmap(decoded, rotationDegrees.toFloat()).also {
                if (it !== decoded) decoded.recycle()
            }
        } else {
            decoded
        }

        val scaled = scaleDownIfNeeded(rotated, MAX_DIMENSION)
        if (scaled !== rotated) rotated.recycle()

        val filtered = if (filterKey != "original") {
            imageProcessor.applyFilter(scaled, filterKey).also {
                if (it !== scaled) scaled.recycle()
            }
        } else {
            scaled
        }

        previewFileStorage.saveWorking(pageId, filterKey, rotationDegrees, filtered)
        previewFileStorage.evictWorkingCacheIfNeeded()
        filtered
    }

    fun deleteForPage(pageId: Long) {
        previewFileStorage.deleteWorkingForPage(pageId)
    }

    private fun decodeSampledBitmap(path: String, maxDimension: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options = BitmapFactory.Options().apply {
            inSampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight, maxDimension)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(path, options)
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

    companion object {
        const val MAX_DIMENSION = 1600
    }
}
