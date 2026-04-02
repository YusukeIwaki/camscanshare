package io.github.yusukeiwaki.camscanshare.data.repository

import android.graphics.Bitmap
import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.yusukeiwaki.camscanshare.data.db.DocumentDao
import io.github.yusukeiwaki.camscanshare.data.db.DocumentEntity
import io.github.yusukeiwaki.camscanshare.data.db.DocumentSummaryTuple
import io.github.yusukeiwaki.camscanshare.data.db.PageDao
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import io.github.yusukeiwaki.camscanshare.data.file.PreviewFileStorage
import io.github.yusukeiwaki.camscanshare.data.preview.PreviewGenerationWorker
import io.github.yusukeiwaki.camscanshare.data.preview.persistAppliedPreviewPaths
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DocumentRepository @Inject constructor(
    private val documentDao: DocumentDao,
    private val pageDao: PageDao,
    private val imageFileStorage: ImageFileStorage,
    private val previewFileStorage: PreviewFileStorage,
    @ApplicationContext private val context: Context,
) {
    // --- Document ---

    fun observeAllDocuments(): Flow<List<DocumentSummaryTuple>> =
        documentDao.observeAllWithSummary()

    suspend fun getDocument(id: Long): DocumentEntity? =
        documentDao.getById(id)

    suspend fun createDocument(name: String): Long =
        documentDao.insert(DocumentEntity(name = name))

    suspend fun renameDocument(id: Long, newName: String) {
        val doc = documentDao.getById(id) ?: return
        documentDao.update(doc.copy(name = newName, updatedAt = System.currentTimeMillis()))
    }

    suspend fun deleteDocuments(ids: Set<Long>) {
        val imagePaths = pageDao.getImagePathsByDocumentIds(ids)
        val smallPaths = pageDao.getSmallPreviewPathsByDocumentIds(ids)
        val largePaths = pageDao.getLargePreviewPathsByDocumentIds(ids)
        val pageIds = pageDao.getPageIdsByDocumentIds(ids)
        imageFileStorage.deleteAll(imagePaths)
        previewFileStorage.deleteAllForPaths(smallPaths, largePaths)
        pageIds.forEach(previewFileStorage::deleteWorkingForPage)
        documentDao.deleteByIds(ids) // CASCADE deletes pages
    }

    // --- Page ---

    fun observePages(documentId: Long): Flow<List<PageEntity>> =
        pageDao.observeByDocumentId(documentId)

    suspend fun getPages(documentId: Long): List<PageEntity> =
        pageDao.getByDocumentId(documentId)

    suspend fun addPage(documentId: Long, bitmap: Bitmap): Long {
        val imagePath = imageFileStorage.saveBitmap(bitmap)
        val sortOrder = pageDao.getPageCount(documentId)
        val pageId = pageDao.insert(
            PageEntity(
                documentId = documentId,
                sortOrder = sortOrder,
                imagePath = imagePath,
            )
        )
        touchDocument(documentId)
        PreviewGenerationWorker.enqueue(context, pageId, PreviewGenerationWorker.TYPE_SMALL)
        PreviewGenerationWorker.enqueue(context, pageId, PreviewGenerationWorker.TYPE_LARGE)
        return pageId
    }

    suspend fun replacePage(pageId: Long, newBitmap: Bitmap) {
        val oldPage = pageDao.getById(pageId) ?: return
        imageFileStorage.delete(oldPage.imagePath)
        oldPage.smallPreviewPath?.let(previewFileStorage::deleteSmall)
        oldPage.largePreviewPath?.let(previewFileStorage::deleteLarge)
        previewFileStorage.deleteWorkingForPage(pageId)

        val newPath = imageFileStorage.saveBitmap(newBitmap)
        pageDao.updateImagePath(pageId, newPath)
        pageDao.updateSmallPreviewPath(pageId, null)
        pageDao.updateLargePreviewPath(pageId, null)
        PreviewGenerationWorker.enqueue(context, pageId, PreviewGenerationWorker.TYPE_SMALL)
        PreviewGenerationWorker.enqueue(context, pageId, PreviewGenerationWorker.TYPE_LARGE)
        touchDocument(oldPage.documentId)
    }

    suspend fun deletePage(pageId: Long, documentId: Long) {
        val page = pageDao.getById(pageId)
        if (page != null) {
            imageFileStorage.delete(page.imagePath)
            page.smallPreviewPath?.let(previewFileStorage::deleteSmall)
            page.largePreviewPath?.let(previewFileStorage::deleteLarge)
            previewFileStorage.deleteWorkingForPage(pageId)
        }
        pageDao.deleteById(pageId)
        // Renumber remaining pages
        val remaining = pageDao.getByDocumentId(documentId)
        remaining.forEachIndexed { index, page ->
            pageDao.updateSortOrder(page.id, index)
        }
        touchDocument(documentId)
    }

    suspend fun reorderPages(documentId: Long, pageIds: List<Long>) {
        pageIds.forEachIndexed { index, id ->
            pageDao.updateSortOrder(id, index)
        }
        touchDocument(documentId)
    }

    suspend fun updatePageFilter(pageId: Long, filterName: String) {
        pageDao.updateFilter(pageId, filterName)
        pageDao.getById(pageId)?.let { touchDocument(it.documentId) }
    }

    suspend fun updateAllPagesFilter(documentId: Long, filterName: String) {
        pageDao.updateFilterForAllPages(documentId, filterName)
        touchDocument(documentId)
    }

    suspend fun updatePageRotation(pageId: Long, degrees: Int) {
        pageDao.updateRotation(pageId, degrees)
        pageDao.getById(pageId)?.let { touchDocument(it.documentId) }
    }

    suspend fun updatePageFilterAndLargePreview(
        pageId: Long,
        filterName: String,
        rotationDegrees: Int,
        filteredBitmap: Bitmap,
    ) {
        val oldPage = pageDao.getById(pageId) ?: return
        val newPaths = persistAppliedPreviewPaths(
            oldSmallPreviewPath = oldPage.smallPreviewPath,
            oldLargePreviewPath = oldPage.largePreviewPath,
            deleteSmall = previewFileStorage::deleteSmall,
            deleteLarge = previewFileStorage::deleteLarge,
            saveSmall = { previewFileStorage.saveSmall(filteredBitmap) },
            saveLarge = { previewFileStorage.saveLarge(filteredBitmap) },
        )
        pageDao.updateFilter(pageId, filterName)
        pageDao.updateRotation(pageId, rotationDegrees)
        pageDao.updateSmallPreviewPath(pageId, newPaths.smallPreviewPath)
        pageDao.updateLargePreviewPath(pageId, newPaths.largePreviewPath)
        touchDocument(oldPage.documentId)
    }

    fun getImageAbsolutePath(relativePath: String): String =
        imageFileStorage.getAbsolutePath(relativePath)

    fun getSmallPreviewAbsolutePath(relativePath: String): String =
        previewFileStorage.getSmallAbsolutePath(relativePath)

    fun getLargePreviewAbsolutePath(relativePath: String): String =
        previewFileStorage.getLargeAbsolutePath(relativePath)

    // --- Internal ---

    private suspend fun touchDocument(documentId: Long) {
        val doc = documentDao.getById(documentId) ?: return
        documentDao.update(doc.copy(updatedAt = System.currentTimeMillis()))
    }
}
