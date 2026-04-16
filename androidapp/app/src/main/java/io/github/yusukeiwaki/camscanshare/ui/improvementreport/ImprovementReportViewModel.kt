package io.github.yusukeiwaki.camscanshare.ui.improvementreport

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import android.net.Uri
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportAttachment
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportMetadata
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportService
import io.github.yusukeiwaki.camscanshare.ui.pageedit.ImageFilter
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

data class ImprovementReportPreviewState(
    val filter: ImageFilter,
    val absolutePath: String? = null,
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
)

data class ImprovementReportAttachmentState(
    val attachment: ImprovementReportAttachment,
)

data class ImprovementReportUiState(
    val appVersion: String = "",
    val buildNumber: String = "",
    val timestampJst: String = "",
    val comment: String = "",
    val previews: List<ImprovementReportPreviewState> = ImageFilter.entries.map {
        ImprovementReportPreviewState(filter = it)
    },
    val attachments: List<ImprovementReportAttachmentState> = emptyList(),
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

    fun initialize(
        pageId: Long,
        sourceImagePath: String,
        rotationDegrees: Int,
        currentFilterKey: String,
    ) {
        if (initialized) return
        initialized = true
        this.pageId = pageId
        this.sourceImagePath = sourceImagePath
        this.rotationDegrees = rotationDegrees
        this.currentFilterKey = currentFilterKey

        val (versionName, buildNumber) = reportService.getAppVersionLabel()
        _uiState.update {
            it.copy(
                appVersion = versionName,
                buildNumber = buildNumber,
                timestampJst = reportService.buildTimestampJst(),
            )
        }

        generatePreviews()
    }

    fun onCommentChanged(value: String) {
        _uiState.update { it.copy(comment = value.take(300)) }
    }

    fun onPhotoPicked(uri: Uri) {
        val attachment = reportService.resolveAttachment(uri) ?: return
        _uiState.update { state ->
            if (state.attachments.any { it.attachment.uriString == attachment.uriString }) {
                state
            } else {
                state.copy(
                    attachments = state.attachments + ImprovementReportAttachmentState(attachment),
                )
            }
        }
    }

    fun canSend(): Boolean {
        val state = _uiState.value
        return state.comment.isNotBlank() &&
            state.previews.all { !it.isLoading && it.absolutePath != null && it.errorMessage == null } &&
            !state.isSending
    }

    fun onBackRequested(): Boolean {
        val state = _uiState.value
        val shouldConfirmDiscard = state.previews.all { !it.isLoading && it.absolutePath != null } && !state.isSending
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
                val previewPaths = _uiState.value.previews.associate { it.filter.filterKey to requireNotNull(it.absolutePath) }
                archiveFile = reportService.createArchive(
                    pageId = pageId,
                    sourceRelativePath = sourceImagePath,
                    previewPaths = previewPaths,
                    attachments = _uiState.value.attachments.map { it.attachment },
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

    private fun generatePreviews() {
        viewModelScope.launch {
            ImageFilter.entries.map { filter ->
                async {
                    try {
                        val absolutePath = reportService.ensurePreview(
                            pageId = pageId,
                            sourceRelativePath = sourceImagePath,
                            filterKey = filter.filterKey,
                            rotationDegrees = rotationDegrees,
                        )
                        _uiState.update { state ->
                            state.copy(
                                previews = state.previews.map { preview ->
                                    if (preview.filter == filter) {
                                        preview.copy(
                                            absolutePath = absolutePath,
                                            isLoading = false,
                                            errorMessage = if (absolutePath == null) "プレビューの生成に失敗しました。" else null,
                                        )
                                    } else {
                                        preview
                                    }
                                }
                            )
                        }
                    } catch (error: Exception) {
                        _uiState.update { state ->
                            state.copy(
                                previews = state.previews.map { preview ->
                                    if (preview.filter == filter) {
                                        preview.copy(
                                            isLoading = false,
                                            errorMessage = error.message ?: "プレビューの生成に失敗しました。",
                                        )
                                    } else {
                                        preview
                                    }
                                }
                            )
                        }
                    }
                }
            }.awaitAll()
        }
    }
}
