package io.github.yusukeiwaki.camscanshare.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

data class DocumentSummaryTuple(
    val id: Long,
    val name: String,
    val updatedAt: Long,
    val pageCount: Int,
    val firstPagePath: String?,
)

@Dao
interface DocumentDao {
    @Query(
        """
        SELECT d.id, d.name, d.updatedAt,
               COUNT(p.id) AS pageCount,
               (SELECT p2.imagePath FROM pages p2 WHERE p2.documentId = d.id ORDER BY p2.sortOrder ASC LIMIT 1) AS firstPagePath
        FROM documents d
        LEFT JOIN pages p ON p.documentId = d.id
        GROUP BY d.id
        ORDER BY d.updatedAt DESC
        """
    )
    fun observeAllWithSummary(): Flow<List<DocumentSummaryTuple>>

    @Query("SELECT * FROM documents WHERE id = :id")
    suspend fun getById(id: Long): DocumentEntity?

    @Insert
    suspend fun insert(document: DocumentEntity): Long

    @Update
    suspend fun update(document: DocumentEntity)

    @Query("DELETE FROM documents WHERE id IN (:ids)")
    suspend fun deleteByIds(ids: Set<Long>)
}
