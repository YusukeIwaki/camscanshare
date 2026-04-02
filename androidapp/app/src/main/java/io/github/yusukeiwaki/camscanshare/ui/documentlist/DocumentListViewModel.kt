package io.github.yusukeiwaki.camscanshare.ui.documentlist

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.db.DocumentSummaryTuple
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class DocumentListUiState(
    val documents: List<DocumentSummaryTuple> = emptyList(),
    val selectedIds: Set<Long> = emptySet(),
    val isSelectionMode: Boolean = false,
    val showDeleteConfirmation: Boolean = false,
)

@HiltViewModel
class DocumentListViewModel @Inject constructor(
    private val repository: DocumentRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(DocumentListUiState())
    val uiState: StateFlow<DocumentListUiState> = _uiState

    init {
        viewModelScope.launch {
            repository.observeAllDocuments().collect { docs ->
                _uiState.update { it.copy(documents = docs) }
            }
        }
    }

    fun onDocumentLongPress(documentId: Long) {
        _uiState.update { current ->
            val newSelected = current.selectedIds + documentId
            current.copy(selectedIds = newSelected, isSelectionMode = true)
        }
    }

    fun onDocumentSelectToggle(documentId: Long) {
        _uiState.update { current ->
            val newSelected = if (current.selectedIds.contains(documentId)) {
                current.selectedIds - documentId
            } else {
                current.selectedIds + documentId
            }
            current.copy(
                selectedIds = newSelected,
                isSelectionMode = newSelected.isNotEmpty(),
            )
        }
    }

    fun onExitSelectionMode() {
        _uiState.update { it.copy(selectedIds = emptySet(), isSelectionMode = false) }
    }

    fun onDeleteSelectedClick() {
        _uiState.update { it.copy(showDeleteConfirmation = true) }
    }

    fun onDeleteConfirmed() {
        val ids = _uiState.value.selectedIds
        _uiState.update {
            it.copy(showDeleteConfirmation = false, selectedIds = emptySet(), isSelectionMode = false)
        }
        viewModelScope.launch {
            repository.deleteDocuments(ids)
        }
    }

    fun onDeleteDismissed() {
        _uiState.update { it.copy(showDeleteConfirmation = false) }
    }

    fun getSmallPreviewAbsolutePath(relativePath: String): String =
        repository.getSmallPreviewAbsolutePath(relativePath)
}
