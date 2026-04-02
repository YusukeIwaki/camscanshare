package io.github.yusukeiwaki.camscanshare.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class FileBitmapState(
    val bitmap: Bitmap?,
    val isLoading: Boolean,
)

data class FileAspectRatioState(
    val aspectRatio: Float?,
    val isLoading: Boolean,
)

@Composable
fun rememberBitmapFromAbsolutePath(absolutePath: String?): FileBitmapState {
    var bitmap by remember(absolutePath) { mutableStateOf<Bitmap?>(null) }
    var isLoading by remember(absolutePath) { mutableStateOf(absolutePath != null) }

    LaunchedEffect(absolutePath) {
        if (absolutePath == null) {
            bitmap = null
            isLoading = false
            return@LaunchedEffect
        }

        isLoading = true
        bitmap = withContext(Dispatchers.IO) {
            BitmapFactory.decodeFile(absolutePath)
        }
        isLoading = false
    }

    return FileBitmapState(bitmap = bitmap, isLoading = isLoading)
}

@Composable
fun rememberAspectRatioFromAbsolutePath(absolutePath: String?): FileAspectRatioState {
    var aspectRatio by remember(absolutePath) { mutableStateOf<Float?>(null) }
    var isLoading by remember(absolutePath) { mutableStateOf(absolutePath != null) }

    LaunchedEffect(absolutePath) {
        if (absolutePath == null) {
            aspectRatio = null
            isLoading = false
            return@LaunchedEffect
        }

        isLoading = true
        aspectRatio = withContext(Dispatchers.IO) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(absolutePath, bounds)
            if (bounds.outWidth > 0 && bounds.outHeight > 0) {
                computePageAspectRatio(bounds.outWidth, bounds.outHeight)
            } else {
                null
            }
        }
        isLoading = false
    }

    return FileAspectRatioState(aspectRatio = aspectRatio, isLoading = isLoading)
}
