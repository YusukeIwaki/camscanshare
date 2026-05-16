package io.github.yusukeiwaki.camscanshare.ui.improvementreport

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportAttachment
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportMetadata
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportService
import io.github.yusukeiwaki.camscanshare.ui.pageedit.ImageFilter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

data class ImprovementReportUiState(
    val appVersion: String = "",
    val buildNumber: String = "",
    val timestampJst: String = "",
    val comment: String = "",
    val attachments: List<ImprovementReportAttachment> = emptyList(),
    val isSending: Boolean = false,
    val showSuccessFeedback: Boolean = false,
    val showDiscardDialog: Boolean = false,
    val errorMessage: String? = null,
    val shouldClose: Boolean = false,
)

@HiltViewModel
class ImprovementReportViewModel @Inject constructor(
    private val reportService: ImprovementReportService,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ImprovementReportUiState())
    val uiState: StateFlow<ImprovementReportUiState> = _uiState

    private var initialized = false
    private var pageId: Long = 0L
    private var sourceImagePath: String = ""
    private var rotationDegrees: Int = 0
    private var currentFilterKey: String = ImageFilter.DEFAULT.filterKey
    private var debugCaptureId: String? = null

    fun initialize(
        pageId: Long,
        sourceImagePath: String,
        rotationDegrees: Int,
        currentFilterKey: String,
        debugCaptureId: String?,
    ) {
        if (initialized) return
        initialized = true
        this.pageId = pageId
        this.sourceImagePath = sourceImagePath
        this.rotationDegrees = rotationDegrees
        this.currentFilterKey = currentFilterKey
        this.debugCaptureId = debugCaptureId

        val (versionName, buildNumber) = reportService.getAppVersionLabel()
        _uiState.update {
            it.copy(
                appVersion = versionName,
                buildNumber = buildNumber,
                timestampJst = reportService.buildTimestampJst(),
            )
        }
    }

    fun onCommentChanged(value: String) {
        _uiState.update { it.copy(comment = value.take(300)) }
    }

    fun onPhotosPicked(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    uris.map(reportService::resolveAttachment)
                }
            }.onSuccess { attachments ->
                _uiState.update { state ->
                    state.copy(attachments = state.attachments + attachments)
                }
            }.onFailure { error ->
                _uiState.update {
                    it.copy(errorMessage = error.message ?: "追加写真を読み込めませんでした。")
                }
            }
        }
    }

    fun onRemoveAttachment(attachment: ImprovementReportAttachment) {
        _uiState.update { state ->
            state.copy(attachments = state.attachments.filterNot { it.uriString == attachment.uriString })
        }
    }

    fun canSend(): Boolean {
        val state = _uiState.value
        return state.comment.isNotBlank() && !state.isSending
    }

    fun onBackRequested(): Boolean {
        val state = _uiState.value
        val shouldConfirmDiscard = (state.comment.isNotBlank() || state.attachments.isNotEmpty()) && !state.isSending
        return if (shouldConfirmDiscard) {
            _uiState.update { it.copy(showDiscardDialog = true) }
            false
        } else {
            true
        }
    }

    fun onDiscardDismissed() {
        _uiState.update { it.copy(showDiscardDialog = false) }
    }

    fun onDiscardConfirmed() {
        _uiState.update { it.copy(showDiscardDialog = false, shouldClose = true) }
    }

    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    fun onScannerFailed(message: String) {
        _uiState.update { it.copy(errorMessage = message, isSending = false) }
    }

    fun submitScannedConfig(rawValue: String) {
        if (!canSend()) return

        viewModelScope.launch {
            _uiState.update { it.copy(isSending = true, errorMessage = null) }
            var archiveFile: File? = null
            try {
                val config = reportService.parseScannerPayload(rawValue)
                archiveFile = reportService.createArchive(
                    pageId = pageId,
                    sourceRelativePath = sourceImagePath,
                    attachments = _uiState.value.attachments,
                    debugCaptureId = debugCaptureId,
                )
                reportService.uploadReport(
                    config = config,
                    metadata = ImprovementReportMetadata(
                        appVersion = _uiState.value.appVersion,
                        buildNumber = _uiState.value.buildNumber,
                        timestampJst = _uiState.value.timestampJst,
                        pageId = pageId,
                        currentFilter = currentFilterKey,
                        comment = _uiState.value.comment.trim(),
                    ),
                    archiveFile = archiveFile,
                )
                _uiState.update {
                    it.copy(
                        isSending = false,
                        showSuccessFeedback = true,
                    )
                }
                delay(900)
                _uiState.update {
                    it.copy(
                        showSuccessFeedback = false,
                        shouldClose = true,
                    )
                }
            } catch (error: Exception) {
                _uiState.update {
                    it.copy(
                        isSending = false,
                        errorMessage = error.message ?: "改善レポート送信に失敗しました。",
                    )
                }
            } finally {
                archiveFile?.delete()
            }
        }
    }
}
