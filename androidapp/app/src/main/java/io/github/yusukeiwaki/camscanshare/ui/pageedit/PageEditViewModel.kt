package io.github.yusukeiwaki.camscanshare.ui.pageedit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.image.FilterRenderPlanner
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class PageEditState(
    val pageId: Long = 0,
    val imagePath: String = "",
    val filterKey: String = "magic",
    val rotationDegrees: Int = 0,
)

data class PageEditUiState(
    val pages: List<PageEditState> = emptyList(),
    val currentPageIndex: Int = 0,
    val showFilterPanel: Boolean = false,
    val showDiscardDialog: Boolean = false,
    val showApplyAllDialog: Boolean = false,
    val applyAllFilterKey: String = "",
    val isDirty: Boolean = false,
    val applied: Boolean = false,
)

@HiltViewModel
class PageEditViewModel @Inject constructor(
    private val repository: DocumentRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(PageEditUiState())
    val uiState: StateFlow<PageEditUiState> = _uiState

    private var documentId: Long = 0L
    private var initialPageIndex: Int = 0
    private var savedPages: List<PageEditState> = emptyList()

    fun initialize(documentId: Long, initialPageIndex: Int) {
        if (this.documentId != 0L) return
        this.documentId = documentId
        this.initialPageIndex = initialPageIndex

        // Observe pages from DB so retake updates are reflected automatically
        viewModelScope.launch {
            repository.observePages(documentId).collect { dbPages ->
                val newPages = dbPages.map { it.toEditState() }
                val current = _uiState.value

                if (!current.isDirty) {
                    // No local edits — accept DB state as-is
                    savedPages = newPages
                    _uiState.update {
                        it.copy(
                            pages = newPages,
                            currentPageIndex = if (it.pages.isEmpty()) {
                                initialPageIndex.coerceIn(0, (newPages.size - 1).coerceAtLeast(0))
                            } else {
                                it.currentPageIndex.coerceIn(0, (newPages.size - 1).coerceAtLeast(0))
                            },
                        )
                    }
                } else {
                    // User has local edits — only update imagePaths from DB (retake),
                    // keep local filter/rotation edits intact
                    val mergedPages = current.pages.map { editPage ->
                        val dbPage = newPages.find { it.pageId == editPage.pageId }
                        if (dbPage != null) {
                            editPage.copy(imagePath = dbPage.imagePath)
                        } else {
                            editPage
                        }
                    }
                    savedPages = newPages
                    _uiState.update { it.copy(pages = mergedPages) }
                }
            }
        }
    }

    fun onPageChanged(index: Int) {
        _uiState.update { it.copy(currentPageIndex = index) }
    }

    fun onRotateClick() {
        val current = _uiState.value
        val idx = current.currentPageIndex
        if (idx >= current.pages.size) return

        val page = current.pages[idx]
        val newRotation = (page.rotationDegrees - 90 + 360) % 360
        val updatedPages = current.pages.toMutableList().also {
            it[idx] = page.copy(rotationDegrees = newRotation)
        }
        _uiState.update {
            it.copy(pages = updatedPages, isDirty = isDirty(updatedPages))
        }
    }

    fun onFilterSelected(filterKey: String) {
        val current = _uiState.value
        val idx = current.currentPageIndex
        if (idx >= current.pages.size) return

        val updatedPages = current.pages.toMutableList().also {
            it[idx] = it[idx].copy(filterKey = filterKey)
        }
        _uiState.update {
            it.copy(pages = updatedPages, isDirty = isDirty(updatedPages))
        }
    }

    fun onFilterLongPressed(filterKey: String) {
        _uiState.update {
            it.copy(showApplyAllDialog = true, applyAllFilterKey = filterKey)
        }
    }

    fun onApplyAllConfirmed() {
        val filterKey = _uiState.value.applyAllFilterKey
        val updatedPages = _uiState.value.pages.map { it.copy(filterKey = filterKey) }
        _uiState.update {
            it.copy(
                pages = updatedPages,
                showApplyAllDialog = false,
                isDirty = isDirty(updatedPages),
            )
        }
    }

    fun onApplyAllDismissed() {
        _uiState.update { it.copy(showApplyAllDialog = false) }
    }

    fun onToggleFilterPanel() {
        _uiState.update { it.copy(showFilterPanel = !it.showFilterPanel) }
    }

    fun onApplyClick() {
        viewModelScope.launch {
            val pages = _uiState.value.pages
            pages.forEach { page ->
                repository.updatePageFilter(
                    page.pageId,
                    FilterRenderPlanner.planPersistedFilter(page.filterKey),
                )
                repository.updatePageRotation(page.pageId, page.rotationDegrees)
            }
            savedPages = pages
            _uiState.update { it.copy(isDirty = false, applied = true) }
        }
    }

    fun onAppliedShown() {
        _uiState.update { it.copy(applied = false) }
    }

    fun onBackClick(): Boolean {
        return if (_uiState.value.isDirty) {
            _uiState.update { it.copy(showDiscardDialog = true) }
            false
        } else {
            true
        }
    }

    fun onDiscardConfirmed() {
        _uiState.update {
            it.copy(
                pages = savedPages,
                showDiscardDialog = false,
                isDirty = false,
            )
        }
    }

    fun onDiscardDismissed() {
        _uiState.update { it.copy(showDiscardDialog = false) }
    }

    fun getImageAbsolutePath(relativePath: String): String =
        repository.getImageAbsolutePath(relativePath)

    private fun isDirty(pages: List<PageEditState>): Boolean {
        if (pages.size != savedPages.size) return true
        return pages.zip(savedPages).any { (a, b) ->
            a.filterKey != b.filterKey || a.rotationDegrees != b.rotationDegrees
        }
    }

    private fun PageEntity.toEditState() = PageEditState(
        pageId = id,
        imagePath = imagePath,
        filterKey = filterName,
        rotationDegrees = rotationDegrees,
    )
}
