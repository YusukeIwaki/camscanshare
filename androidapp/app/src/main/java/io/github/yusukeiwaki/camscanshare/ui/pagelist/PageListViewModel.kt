package io.github.yusukeiwaki.camscanshare.ui.pagelist

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import io.github.yusukeiwaki.camscanshare.data.repository.DocumentRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

data class PageListUiState(
    val documentName: String = "",
    val pages: List<PageEntity> = emptyList(),
    val showRenameDialog: Boolean = false,
    val isDragActive: Boolean = false,
)

@HiltViewModel
class PageListViewModel @Inject constructor(
    private val repository: DocumentRepository,
    private val imageProcessor: ImageProcessor,
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

    fun sharePdf(context: Context) {
        viewModelScope.launch {
            val pages = repository.getPages(documentId)
            if (pages.isEmpty()) return@launch

            val pdfFile = withContext(Dispatchers.IO) {
                val pdfDocument = PdfDocument()
                val a4Width = 595
                val a4Height = 842

                pages.forEachIndexed { index, page ->
                    val absPath = repository.getImageAbsolutePath(page.imagePath)
                    val bitmap = BitmapFactory.decodeFile(absPath) ?: return@forEachIndexed

                    val rotated = imageProcessor.rotateBitmap(bitmap, page.rotationDegrees.toFloat())
                    val filtered = imageProcessor.applyFilter(rotated, page.filterName)

                    val pageInfo = PdfDocument.PageInfo.Builder(a4Width, a4Height, index + 1).create()
                    val pdfPage = pdfDocument.startPage(pageInfo)

                    val scale = minOf(
                        a4Width.toFloat() / filtered.width,
                        a4Height.toFloat() / filtered.height,
                    )
                    val dx = (a4Width - filtered.width * scale) / 2
                    val dy = (a4Height - filtered.height * scale) / 2

                    val canvas = pdfPage.canvas
                    canvas.translate(dx, dy)
                    canvas.scale(scale, scale)
                    canvas.drawBitmap(filtered, 0f, 0f, null)

                    pdfDocument.finishPage(pdfPage)
                    if (filtered !== rotated) filtered.recycle()
                    if (rotated !== bitmap) rotated.recycle()
                    bitmap.recycle()
                }

                val safeName = _uiState.value.documentName.replace(Regex("[/\\\\:*?\"<>|]"), "_")
                File(context.cacheDir, "$safeName.pdf").also { file ->
                    file.outputStream().use { pdfDocument.writeTo(it) }
                    pdfDocument.close()
                }
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
        }
    }
}
