package io.github.yusukeiwaki.camscanshare.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface PageDao {
    @Query("SELECT * FROM pages WHERE documentId = :documentId ORDER BY sortOrder ASC")
    fun observeByDocumentId(documentId: Long): Flow<List<PageEntity>>

    @Query("SELECT * FROM pages WHERE documentId = :documentId ORDER BY sortOrder ASC")
    suspend fun getByDocumentId(documentId: Long): List<PageEntity>

    @Query("SELECT COUNT(*) FROM pages WHERE documentId = :documentId")
    suspend fun getPageCount(documentId: Long): Int

    @Insert
    suspend fun insert(page: PageEntity): Long

    @Update
    suspend fun update(page: PageEntity)

    @Query("UPDATE pages SET sortOrder = :sortOrder WHERE id = :pageId")
    suspend fun updateSortOrder(pageId: Long, sortOrder: Int)

    @Query("UPDATE pages SET imagePath = :imagePath WHERE id = :pageId")
    suspend fun updateImagePath(pageId: Long, imagePath: String)

    @Query("UPDATE pages SET filterName = :filterName WHERE id = :pageId")
    suspend fun updateFilter(pageId: Long, filterName: String)

    @Query("UPDATE pages SET filterName = :filterName WHERE documentId = :documentId")
    suspend fun updateFilterForAllPages(documentId: Long, filterName: String)

    @Query("UPDATE pages SET rotationDegrees = :degrees WHERE id = :pageId")
    suspend fun updateRotation(pageId: Long, degrees: Int)

    @Query("SELECT imagePath FROM pages WHERE id = :pageId")
    suspend fun getImagePath(pageId: Long): String?

    @Query("SELECT imagePath FROM pages WHERE documentId IN (:documentIds)")
    suspend fun getImagePathsByDocumentIds(documentIds: Set<Long>): List<String>

    @Query("DELETE FROM pages WHERE id = :pageId")
    suspend fun deleteById(pageId: Long)
}
