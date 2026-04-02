package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.data.preview.persistAppliedPreviewPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppliedPreviewPersistenceTest {

    @Test
    fun `applied preview persistence refreshes both small and large paths`() {
        val deletedSmall = mutableListOf<String>()
        val deletedLarge = mutableListOf<String>()

        val result = persistAppliedPreviewPaths(
            oldSmallPreviewPath = "old-small.jpg",
            oldLargePreviewPath = "old-large.jpg",
            deleteSmall = { deletedSmall += it },
            deleteLarge = { deletedLarge += it },
            saveSmall = { "new-small.jpg" },
            saveLarge = { "new-large.jpg" },
        )

        assertEquals(listOf("old-small.jpg"), deletedSmall)
        assertEquals(listOf("old-large.jpg"), deletedLarge)
        assertEquals("new-small.jpg", result.smallPreviewPath)
        assertEquals("new-large.jpg", result.largePreviewPath)
    }

    @Test
    fun `applied preview persistence still writes both previews when old paths are absent`() {
        val result = persistAppliedPreviewPaths(
            oldSmallPreviewPath = null,
            oldLargePreviewPath = null,
            deleteSmall = { error("should not delete small preview") },
            deleteLarge = { error("should not delete large preview") },
            saveSmall = { "small.jpg" },
            saveLarge = { "large.jpg" },
        )

        assertTrue(result.smallPreviewPath.isNotBlank())
        assertTrue(result.largePreviewPath.isNotBlank())
    }
}
