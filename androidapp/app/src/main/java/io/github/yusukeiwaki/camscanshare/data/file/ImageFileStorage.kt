package io.github.yusukeiwaki.camscanshare.data.file

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ImageFileStorage @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val imageDir: File
        get() = File(context.filesDir, "scans").also { it.mkdirs() }

    fun saveBitmap(bitmap: Bitmap): String {
        val fileName = "${UUID.randomUUID()}.jpg"
        val file = File(imageDir, fileName)
        file.outputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
        }
        return fileName
    }

    fun loadBitmap(relativePath: String): Bitmap? {
        val file = File(imageDir, relativePath)
        if (!file.exists()) return null
        return BitmapFactory.decodeFile(file.absolutePath)
    }

    fun getAbsolutePath(relativePath: String): String {
        return File(imageDir, relativePath).absolutePath
    }

    fun delete(relativePath: String) {
        File(imageDir, relativePath).delete()
    }

    fun deleteAll(relativePaths: List<String>) {
        relativePaths.forEach { delete(it) }
    }
}
