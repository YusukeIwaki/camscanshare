package io.github.yusukeiwaki.camscanshare.data.repository

import android.graphics.Bitmap
import io.github.yusukeiwaki.camscanshare.data.db.DocumentDao
import io.github.yusukeiwaki.camscanshare.data.db.DocumentEntity
import io.github.yusukeiwaki.camscanshare.data.db.DocumentSummaryTuple
import io.github.yusukeiwaki.camscanshare.data.db.PageDao
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DocumentRepository @Inject constructor(
    private val documentDao: DocumentDao,
    private val pageDao: PageDao,
    private val imageFileStorage: ImageFileStorage,
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
        imageFileStorage.deleteAll(imagePaths)
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
        return pageId
    }

    suspend fun replacePage(pageId: Long, newBitmap: Bitmap) {
        // Delete old image file
        val oldPath = pageDao.getImagePath(pageId)
        if (oldPath != null) imageFileStorage.delete(oldPath)
        // Save new image
        val newPath = imageFileStorage.saveBitmap(newBitmap)
        pageDao.updateImagePath(pageId, newPath)
    }

    suspend fun deletePage(pageId: Long, documentId: Long) {
        val imagePath = pageDao.getImagePath(pageId)
        if (imagePath != null) imageFileStorage.delete(imagePath)
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
    }

    suspend fun updateAllPagesFilter(documentId: Long, filterName: String) {
        pageDao.updateFilterForAllPages(documentId, filterName)
        touchDocument(documentId)
    }

    suspend fun updatePageRotation(pageId: Long, degrees: Int) {
        pageDao.updateRotation(pageId, degrees)
    }

    fun getImageAbsolutePath(relativePath: String): String =
        imageFileStorage.getAbsolutePath(relativePath)

    fun loadBitmap(relativePath: String): Bitmap? =
        imageFileStorage.loadBitmap(relativePath)

    // --- Internal ---

    private suspend fun touchDocument(documentId: Long) {
        val doc = documentDao.getById(documentId) ?: return
        documentDao.update(doc.copy(updatedAt = System.currentTimeMillis()))
    }
}
