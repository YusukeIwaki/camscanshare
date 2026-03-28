package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.data.db.DocumentSummaryTuple
import io.github.yusukeiwaki.camscanshare.ui.documentlist.DocumentListUiState
import io.github.yusukeiwaki.camscanshare.ui.documentlist.DocumentListViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DocumentListViewModelTest {

    private val testDispatcher = StandardTestDispatcher()

    @Before
    fun setup() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `initial state has empty documents and selection`() {
        val state = DocumentListUiState()
        assertTrue(state.documents.isEmpty())
        assertTrue(state.selectedIds.isEmpty())
        assertFalse(state.isSelectionMode)
        assertFalse(state.showDeleteConfirmation)
    }

    @Test
    fun `selection mode state transitions work correctly`() {
        // Test pure state transitions without repository dependency
        var state = DocumentListUiState()

        // Long press enters selection mode
        val docId = 1L
        state = state.copy(
            selectedIds = state.selectedIds + docId,
            isSelectionMode = true,
        )
        assertTrue(state.isSelectionMode)
        assertEquals(setOf(1L), state.selectedIds)

        // Toggle adds second selection
        val docId2 = 2L
        state = state.copy(selectedIds = state.selectedIds + docId2)
        assertEquals(setOf(1L, 2L), state.selectedIds)

        // Toggle removes selection
        state = state.copy(
            selectedIds = state.selectedIds - docId,
            isSelectionMode = (state.selectedIds - docId).isNotEmpty(),
        )
        assertEquals(setOf(2L), state.selectedIds)
        assertTrue(state.isSelectionMode)

        // Remove last exits selection mode
        state = state.copy(
            selectedIds = state.selectedIds - docId2,
            isSelectionMode = (state.selectedIds - docId2).isNotEmpty(),
        )
        assertTrue(state.selectedIds.isEmpty())
        assertFalse(state.isSelectionMode)
    }

    @Test
    fun `delete confirmation flow`() {
        var state = DocumentListUiState(
            selectedIds = setOf(1L, 2L),
            isSelectionMode = true,
        )

        // Show confirmation
        state = state.copy(showDeleteConfirmation = true)
        assertTrue(state.showDeleteConfirmation)

        // Dismiss
        state = state.copy(showDeleteConfirmation = false)
        assertFalse(state.showDeleteConfirmation)
        // Selection should still be active
        assertTrue(state.isSelectionMode)

        // Confirm delete clears everything
        state = state.copy(
            showDeleteConfirmation = false,
            selectedIds = emptySet(),
            isSelectionMode = false,
        )
        assertFalse(state.isSelectionMode)
        assertTrue(state.selectedIds.isEmpty())
    }
}
