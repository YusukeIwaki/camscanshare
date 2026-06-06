package io.github.yusukeiwaki.camscanshare.ui.pagelist

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessingDebugSink
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import io.github.yusukeiwaki.camscanshare.ui.components.computePdfPageSize
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import javax.inject.Inject

data class PageListUiState(
    val documentName: String = "",
    val pages: List<PageEntity> = emptyList(),
    val showRenameDialog: Boolean = false,
    val isDragActive: Boolean = false,
    val shareProgress: SharePdfProgress? = null,
) {
    val isSharing: Boolean
        get() = shareProgress != null
}

data class SharePdfProgress(
    val message: String,
    val currentPageIndex: Int,
    val totalPages: Int,
    val currentPageId: Long? = null,
) {
    val progressFraction: Float
        get() = if (totalPages <= 0) {
            0f
        } else {
            currentPageIndex.coerceIn(0, totalPages).toFloat() / totalPages.toFloat()
        }
}

@HiltViewModel
class PageListViewModel @Inject constructor(
    private val repository: DocumentRepository,
    private val imageProcessor: ImageProcessor,
    private val debugSink: ImageProcessingDebugSink,
) : ViewModel() {

    private val _uiState = MutableStateFlow(PageListUiState())
    val uiState: StateFlow<PageListUiState> = _uiState

    private var documentId: Long = 0L

    fun initialize(documentId: Long) {
        if (this.documentId != 0L) return
        this.documentId = documentId

        viewModelScope.launch {
            val doc = repository.getDocument(documentId)
            _uiState.update { it.copy(documentName = doc?.name ?: "") }
        }
        viewModelScope.launch {
            repository.observePages(documentId).collect { pages ->
                _uiState.update { it.copy(pages = pages) }
            }
        }
    }

    fun onRenameClick() {
        _uiState.update { it.copy(showRenameDialog = true) }
    }

    fun onRenameConfirmed(newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return
        _uiState.update { it.copy(documentName = trimmed, showRenameDialog = false) }
        viewModelScope.launch {
            repository.renameDocument(documentId, trimmed)
        }
    }

    fun onRenameDismissed() {
        _uiState.update { it.copy(showRenameDialog = false) }
    }

    fun onPageReordered(pageIds: List<Long>) {
        viewModelScope.launch {
            repository.reorderPages(documentId, pageIds)
        }
    }

    fun onPageDeleted(pageId: Long) {
        viewModelScope.launch {
            repository.deletePage(pageId, documentId)
        }
    }

    fun onDragActiveChanged(active: Boolean) {
        _uiState.update { it.copy(isDragActive = active) }
    }

    fun getLargePreviewAbsolutePath(relativePath: String): String =
        repository.getLargePreviewAbsolutePath(relativePath)

    fun getImageAbsolutePath(relativePath: String): String =
        repository.getImageAbsolutePath(relativePath)

    fun sharePdf(context: Context) {
        if (_uiState.value.isSharing) return

        viewModelScope.launch {
            val pages = repository.getPages(documentId)
            if (pages.isEmpty()) return@launch

            _uiState.update {
                it.copy(
                    shareProgress = SharePdfProgress(
                        message = "PDFを準備しています",
                        currentPageIndex = 0,
                        totalPages = pages.size,
                        currentPageId = pages.firstOrNull()?.id,
                    ),
                )
            }

            try {
                val pdfSession = debugSink.startSession(
                    category = "pdf-export",
                    label = "document_$documentId",
                    metadata = mapOf(
                        "documentId" to documentId.toString(),
                        "documentName" to _uiState.value.documentName,
                        "pageCount" to pages.size.toString(),
                    ),
                )
                val pdfFile = withContext(Dispatchers.IO) {
                    val totalStarted = SystemClock.elapsedRealtimeNanos()
                    val pdfPages = mutableListOf<JpegPdfPage>()

                    pages.forEachIndexed { index, page ->
                        val pageStarted = SystemClock.elapsedRealtimeNanos()
                        _uiState.update {
                            it.copy(
                                shareProgress = SharePdfProgress(
                                    message = "PDFを作成しています",
                                    currentPageIndex = index + 1,
                                    totalPages = pages.size,
                                    currentPageId = page.id,
                                ),
                            )
                        }

                        val absPath = repository.getImageAbsolutePath(page.imagePath)
                        val bitmap = BitmapFactory.decodeFile(absPath) ?: return@forEachIndexed
                        debugSink.writeBitmap(pdfSession, "page_${index + 1}_input", bitmap)

                        val rotated = imageProcessor.rotateBitmap(bitmap, page.rotationDegrees.toFloat())
                        val filtered = imageProcessor.applyFilter(rotated, page.filterName)
                        debugSink.writeBitmap(pdfSession, "page_${index + 1}_filtered", filtered)
                        val pdfPageSize = computePdfPageSize(filtered.width, filtered.height)
                        val imageWidth = filtered.width
                        val imageHeight = filtered.height
                        val jpegBytes = filtered.toJpegBytes(JpegPdfWriter.JPEG_QUALITY)
                        pdfPages += JpegPdfPage(
                            jpegBytes = jpegBytes,
                            imageWidth = imageWidth,
                            imageHeight = imageHeight,
                            pageWidth = pdfPageSize.width,
                            pageHeight = pdfPageSize.height,
                        )

                        if (filtered !== rotated) filtered.recycle()
                        if (rotated !== bitmap) rotated.recycle()
                        bitmap.recycle()
                        debugSink.recordTimingSince(
                            pdfSession,
                            "pdf.page",
                            pageStarted,
                            mapOf(
                                "pageId" to page.id.toString(),
                                "pageIndex" to (index + 1).toString(),
                                "filter" to page.filterName,
                                "rotationDegrees" to page.rotationDegrees.toString(),
                                "pdfWidth" to pdfPageSize.width.toString(),
                                "pdfHeight" to pdfPageSize.height.toString(),
                                "imageWidth" to imageWidth.toString(),
                                "imageHeight" to imageHeight.toString(),
                                "jpegQuality" to JpegPdfWriter.JPEG_QUALITY.toString(),
                                "jpegSizeBytes" to jpegBytes.size.toString(),
                            ),
                        )
                    }

                    _uiState.update {
                        it.copy(
                            shareProgress = SharePdfProgress(
                                message = "PDFを書き出しています",
                                currentPageIndex = pages.size,
                                totalPages = pages.size,
                                currentPageId = pages.lastOrNull()?.id,
                            ),
                        )
                    }

                    val safeName = _uiState.value.documentName
                        .replace(Regex("[/\\\\:*?\"<>|]"), "_")
                        .ifBlank { "document" }
                    File(context.cacheDir, "$safeName.pdf").also { file ->
                        val writeStarted = SystemClock.elapsedRealtimeNanos()
                        file.outputStream().use { JpegPdfWriter.write(pdfPages, it) }
                        debugSink.recordTimingSince(
                            pdfSession,
                            "pdf.write",
                            writeStarted,
                            mapOf("fileSizeBytes" to file.length().toString()),
                        )
                        debugSink.recordTimingSince(
                            pdfSession,
                            "pdf.total",
                            totalStarted,
                            mapOf("fileSizeBytes" to file.length().toString()),
                        )
                    }
                }

                _uiState.update {
                    it.copy(
                        shareProgress = SharePdfProgress(
                            message = "共有シートを開いています",
                            currentPageIndex = pages.size,
                            totalPages = pages.size,
                            currentPageId = pages.lastOrNull()?.id,
                        ),
                    )
                }

                val uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    pdfFile,
                )

                val shareIntent = Intent(Intent.ACTION_SEND).apply {
                    type = "application/pdf"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(Intent.createChooser(shareIntent, "PDFとして共有"))
            } finally {
                _uiState.update { it.copy(shareProgress = null) }
            }
        }
    }

    private fun Bitmap.toJpegBytes(quality: Int): ByteArray =
        ByteArrayOutputStream().use { output ->
            if (!compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                throw IOException("Failed to compress bitmap for PDF")
            }
            output.toByteArray()
        }
}
