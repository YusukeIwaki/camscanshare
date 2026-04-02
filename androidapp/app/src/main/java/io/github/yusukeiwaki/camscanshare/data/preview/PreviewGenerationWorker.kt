package io.github.yusukeiwaki.camscanshare.data.preview

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import io.github.yusukeiwaki.camscanshare.data.db.PageDao
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import io.github.yusukeiwaki.camscanshare.data.file.PreviewFileStorage
import java.io.FileNotFoundException
import java.io.IOException

@HiltWorker
class PreviewGenerationWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted params: WorkerParameters,
    private val pageDao: PageDao,
    private val imageFileStorage: ImageFileStorage,
    private val previewFileStorage: PreviewFileStorage,
    private val workingPreviewManager: WorkingPreviewManager,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val pageId = inputData.getLong(KEY_PAGE_ID, -1L)
        val type = inputData.getString(KEY_TYPE) ?: return Result.failure()
        if (pageId == -1L) return Result.failure()

        val page = pageDao.getById(pageId) ?: return Result.failure()

        return try {
            when (type) {
                TYPE_SMALL -> {
                    if (page.smallPreviewPath != null) return Result.success()
                    val path = previewFileStorage.generateAndSaveSmall(
                        imageFileStorage.getAbsolutePath(page.imagePath)
                    )
                    pageDao.updateSmallPreviewPath(pageId, path)
                    Result.success()
                }

                TYPE_LARGE -> {
                    if (page.largePreviewPath != null) return Result.success()
                    val bitmap = workingPreviewManager.getOrCompute(
                        pageId = page.id,
                        sourceRelativePath = page.imagePath,
                        filterKey = page.filterName,
                        rotationDegrees = page.rotationDegrees,
                    ) ?: return Result.retry()
                    val path = try {
                        previewFileStorage.saveLarge(bitmap)
                    } finally {
                        bitmap.recycle()
                    }
                    pageDao.updateLargePreviewPath(pageId, path)
                    Result.success()
                }

                else -> Result.failure()
            }
        } catch (_: FileNotFoundException) {
            Result.failure()
        } catch (_: IOException) {
            Result.retry()
        }
    }

    companion object {
        private const val KEY_PAGE_ID = "pageId"
        private const val KEY_TYPE = "type"

        const val TYPE_SMALL = "small"
        const val TYPE_LARGE = "large"

        fun enqueue(context: Context, pageId: Long, type: String) {
            val request = OneTimeWorkRequestBuilder<PreviewGenerationWorker>()
                .setInputData(
                    workDataOf(
                        KEY_PAGE_ID to pageId,
                        KEY_TYPE to type,
                    )
                )
                .build()
            WorkManager.getInstance(context).enqueue(request)
        }
    }
}
