package io.github.yusukeiwaki.camscanshare.data.file

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max
import kotlin.math.roundToInt

@Singleton
class PreviewFileStorage @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val smallDir: File
        get() = File(context.filesDir, "previews/small").also { it.mkdirs() }

    private val largeDir: File
        get() = File(context.filesDir, "previews/large").also { it.mkdirs() }

    private val workingDir: File
        get() = File(context.filesDir, "previews/working").also { it.mkdirs() }

    fun generateAndSaveSmall(sourceAbsolutePath: String): String {
        val decoded = decodeSampledBitmap(sourceAbsolutePath, 400)
        val scaled = prepareSmallBitmap(decoded)
        if (scaled !== decoded) decoded.recycle()

        return try {
            saveBitmap(smallDir, "${UUID.randomUUID()}_small.jpg", scaled, SMALL_QUALITY)
        } finally {
            scaled.recycle()
        }
    }

    fun saveSmall(bitmap: Bitmap): String {
        val prepared = prepareSmallBitmap(bitmap)
        return try {
            saveBitmap(smallDir, "${UUID.randomUUID()}_small.jpg", prepared, SMALL_QUALITY)
        } finally {
            if (prepared !== bitmap) prepared.recycle()
        }
    }

    fun getSmallAbsolutePath(relativePath: String): String = File(smallDir, relativePath).absolutePath

    fun deleteSmall(relativePath: String) {
        File(smallDir, relativePath).delete()
    }

    fun generateAndSaveLarge(sourceAbsolutePath: String): String {
        val decoded = decodeSampledBitmap(sourceAbsolutePath, LARGE_MAX_DIMENSION)
        val scaled = scaleDownIfNeeded(decoded, LARGE_MAX_DIMENSION)
        if (scaled !== decoded) decoded.recycle()

        return try {
            saveLarge(scaled)
        } finally {
            scaled.recycle()
        }
    }

    fun saveLarge(bitmap: Bitmap): String =
        saveBitmap(largeDir, "${UUID.randomUUID()}_large.jpg", bitmap, LARGE_QUALITY)

    fun getLargeAbsolutePath(relativePath: String): String = File(largeDir, relativePath).absolutePath

    fun deleteLarge(relativePath: String) {
        File(largeDir, relativePath).delete()
    }

    fun workingExists(pageId: Long, filterKey: String, rotation: Int): Boolean =
        workingFile(pageId, filterKey, rotation).exists()

    fun saveWorking(pageId: Long, filterKey: String, rotation: Int, bitmap: Bitmap) {
        saveBitmap(workingDir, workingFile(pageId, filterKey, rotation).name, bitmap, WORKING_QUALITY)
    }

    fun loadWorking(pageId: Long, filterKey: String, rotation: Int): Bitmap? {
        val file = workingFile(pageId, filterKey, rotation)
        if (!file.exists()) return null
        val bitmap = BitmapFactory.decodeFile(file.absolutePath) ?: return null
        file.setLastModified(System.currentTimeMillis())
        return bitmap
    }

    fun deleteWorkingForPage(pageId: Long) {
        workingDir.listFiles()
            ?.filter { it.name.startsWith("${pageId}_") }
            ?.forEach { it.delete() }
    }

    fun evictWorkingCacheIfNeeded() {
        val files = workingDir.listFiles() ?: return
        var totalSize = files.sumOf { it.length() }
        if (totalSize <= WORKING_CACHE_MAX_BYTES) return

        val sortedFiles = files.sortedBy { it.lastModified() }
        for (file in sortedFiles) {
            if (totalSize <= (WORKING_CACHE_MAX_BYTES * 0.8).toLong()) break
            totalSize -= file.length()
            file.delete()
        }
    }

    fun deleteAllForPaths(smallPaths: List<String?>, largePaths: List<String?>) {
        smallPaths.filterNotNull().forEach(::deleteSmall)
        largePaths.filterNotNull().forEach(::deleteLarge)
    }

    private fun workingFile(pageId: Long, filterKey: String, rotation: Int): File =
        File(workingDir, "${pageId}_${filterKey}_${rotation}.jpg")

    private fun saveBitmap(directory: File, fileName: String, bitmap: Bitmap, quality: Int): String {
        val file = File(directory, fileName)
        file.outputStream().use { output ->
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                throw IOException("Failed to compress preview bitmap: ${file.absolutePath}")
            }
        }
        return file.name
    }

    private fun decodeSampledBitmap(path: String, maxDimension: Int): Bitmap {
        val file = File(path)
        if (!file.exists()) {
            throw FileNotFoundException("Preview source does not exist: $path")
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IOException("Failed to decode preview bounds: $path")
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight, maxDimension)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(path, options)
            ?: throw IOException("Failed to decode preview bitmap: $path")
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

    private fun cropCenterSquare(bitmap: Bitmap): Bitmap {
        if (bitmap.width == bitmap.height) return bitmap

        val size = minOf(bitmap.width, bitmap.height)
        val left = ((bitmap.width - size) / 2).coerceAtLeast(0)
        val top = ((bitmap.height - size) / 2).coerceAtLeast(0)
        return Bitmap.createBitmap(bitmap, left, top, size, size)
    }

    private fun prepareSmallBitmap(bitmap: Bitmap): Bitmap {
        val squared = cropCenterSquare(bitmap)
        return if (squared.width == SMALL_SIZE && squared.height == SMALL_SIZE) {
            squared
        } else {
            Bitmap.createScaledBitmap(squared, SMALL_SIZE, SMALL_SIZE, true).also {
                if (it !== squared) squared.recycle()
            }
        }
    }

    companion object {
        private const val SMALL_SIZE = 200
        private const val SMALL_QUALITY = 85
        private const val LARGE_MAX_DIMENSION = 1600
        private const val LARGE_QUALITY = 90
        private const val WORKING_QUALITY = 90
        private const val WORKING_CACHE_MAX_BYTES = 100L * 1024L * 1024L
    }
}
