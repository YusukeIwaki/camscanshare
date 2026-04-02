package io.github.yusukeiwaki.camscanshare.ui.pageedit

import android.graphics.Bitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.preview.WorkingPreviewManager
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class PageEditState(
    val pageId: Long = 0,
    val imagePath: String = "",
    val sourceImageAbsPath: String = "",
    val filterKey: String = "original",
    val rotationDegrees: Int = 0,
    val largePreviewAbsPath: String? = null,
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
    private val workingPreviewManager: WorkingPreviewManager,
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

        viewModelScope.launch {
            repository.observePages(documentId).collect { dbPages ->
                val newPages = dbPages.map { it.toEditState() }
                val current = _uiState.value

                if (!current.isDirty) {
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
                    val mergedPages = current.pages.map { editPage ->
                        val dbPage = newPages.find { it.pageId == editPage.pageId }
                        if (dbPage != null) {
                            editPage.copy(
                                imagePath = dbPage.imagePath,
                                sourceImageAbsPath = dbPage.sourceImageAbsPath,
                                largePreviewAbsPath = dbPage.largePreviewAbsPath,
                            )
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
        _uiState.update { it.copy(pages = updatedPages, isDirty = isDirty(updatedPages)) }
    }

    fun onFilterSelected(filterKey: String) {
        val current = _uiState.value
        val idx = current.currentPageIndex
        if (idx >= current.pages.size) return

        val updatedPages = current.pages.toMutableList().also {
            it[idx] = it[idx].copy(filterKey = filterKey)
        }
        _uiState.update { it.copy(pages = updatedPages, isDirty = isDirty(updatedPages)) }
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
                val workingBitmap = getWorkingPreview(page)
                if (workingBitmap != null) {
                    try {
                        repository.updatePageFilterAndLargePreview(
                            pageId = page.pageId,
                            filterName = page.filterKey,
                            rotationDegrees = page.rotationDegrees,
                            filteredBitmap = workingBitmap,
                        )
                    } finally {
                        workingBitmap.recycle()
                    }
                } else {
                    repository.updatePageFilter(page.pageId, page.filterKey)
                    repository.updatePageRotation(page.pageId, page.rotationDegrees)
                }
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

    fun hasUnsavedPreviewEdits(page: PageEditState): Boolean {
        val saved = savedPages.find { it.pageId == page.pageId } ?: return false
        return page.filterKey != saved.filterKey || page.rotationDegrees != saved.rotationDegrees
    }

    suspend fun getWorkingPreview(page: PageEditState): Bitmap? =
        workingPreviewManager.getOrCompute(
            pageId = page.pageId,
            sourceRelativePath = page.imagePath,
            filterKey = page.filterKey,
            rotationDegrees = page.rotationDegrees,
        )

    private fun isDirty(pages: List<PageEditState>): Boolean {
        if (pages.size != savedPages.size) return true
        return pages.zip(savedPages).any { (a, b) ->
            a.filterKey != b.filterKey || a.rotationDegrees != b.rotationDegrees
        }
    }

    private fun PageEntity.toEditState() = PageEditState(
        pageId = id,
        imagePath = imagePath,
        sourceImageAbsPath = repository.getImageAbsolutePath(imagePath),
        filterKey = filterName,
        rotationDegrees = rotationDegrees,
        largePreviewAbsPath = largePreviewPath?.let { repository.getLargePreviewAbsolutePath(it) },
    )
}
