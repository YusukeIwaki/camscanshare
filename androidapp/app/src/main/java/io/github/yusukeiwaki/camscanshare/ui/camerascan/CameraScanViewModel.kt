package io.github.yusukeiwaki.camscanshare.ui.camerascan

import android.graphics.Bitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class CameraScanUiState(
    val documentId: Long = 0L,
    val retakePageId: Long = 0L,
    val capturedPageCount: Int = 0,
    val lastThumbnail: Bitmap? = null,
    val isCapturing: Boolean = false,
    val showFlash: Boolean = false,
    val retakeDone: Boolean = false,
    /** Non-null while the flying page animation should play. Cleared after animation ends. */
    val flyingThumbnail: Bitmap? = null,
)

@HiltViewModel
class CameraScanViewModel @Inject constructor(
    private val repository: DocumentRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(CameraScanUiState())
    val uiState: StateFlow<CameraScanUiState> = _uiState

    val isRetakeMode: Boolean get() = _uiState.value.retakePageId != 0L

    fun initialize(documentId: Long, retakePageId: Long = 0L) {
        if (_uiState.value.documentId != 0L) return
        _uiState.update { it.copy(retakePageId = retakePageId) }
        if (documentId != 0L) {
            _uiState.update { it.copy(documentId = documentId) }
            viewModelScope.launch {
                val pages = repository.getPages(documentId)
                _uiState.update { it.copy(capturedPageCount = pages.size) }
            }
        }
    }

    fun onCaptureImage(bitmap: Bitmap) {
        if (_uiState.value.isCapturing) return
        _uiState.update { it.copy(isCapturing = true, showFlash = true) }

        viewModelScope.launch {
            val retakePageId = _uiState.value.retakePageId
            if (retakePageId != 0L) {
                // Retake mode: replace the existing page's image
                repository.replacePage(retakePageId, bitmap)
                _uiState.update {
                    it.copy(isCapturing = false, showFlash = false, retakeDone = true)
                }
            } else {
                // Normal capture mode
                var docId = _uiState.value.documentId
                if (docId == 0L) {
                    docId = repository.createDocument(generateDocumentName())
                    _uiState.update { it.copy(documentId = docId) }
                }

                repository.addPage(docId, bitmap)

                val thumbSize = 200
                val scale = thumbSize.toFloat() / maxOf(bitmap.width, bitmap.height)
                val thumb = Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt(),
                    (bitmap.height * scale).toInt(),
                    true,
                )

                val count = _uiState.value.capturedPageCount + 1
                _uiState.update {
                    it.copy(
                        capturedPageCount = count,
                        lastThumbnail = thumb,
                        flyingThumbnail = thumb,
                        isCapturing = false,
                        showFlash = false,
                    )
                }
            }
        }
    }

    fun onFlashDone() {
        _uiState.update { it.copy(showFlash = false) }
    }

    fun onFlyingAnimationDone() {
        _uiState.update { it.copy(flyingThumbnail = null) }
    }

    companion object {
        fun generateDocumentName(): String {
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.JAPAN)
            return "スキャン ${sdf.format(java.util.Date())}"
        }
    }
}
