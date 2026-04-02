package io.github.yusukeiwaki.camscanshare.ui.documentlist

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.yusukeiwaki.camscanshare.data.db.DocumentSummaryTuple
import io.github.yusukeiwaki.camscanshare.ui.components.ConfirmDialog
import io.github.yusukeiwaki.camscanshare.ui.components.SmallPreviewImage
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun DocumentListScreen(
    onDocumentClick: (Long) -> Unit,
    onNewScanClick: () -> Unit,
    viewModel: DocumentListViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val bottomInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val selectionBarHeight = 56.dp
    val listTopPadding by animateDpAsState(
        targetValue = if (uiState.isSelectionMode) selectionBarHeight else 0.dp,
        animationSpec = tween(250),
        label = "documentListTopPadding",
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surface),
    ) {
        if (uiState.documents.isEmpty()) {
            EmptyState(
                modifier = Modifier
                    .fillMaxSize()
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .statusBarsPadding(),
            )
        } else {
            DocumentList(
                documents = uiState.documents,
                selectedIds = uiState.selectedIds,
                isSelectionMode = uiState.isSelectionMode,
                topContentPadding = listTopPadding,
                bottomContentPadding = bottomInset,
                onDocumentClick = { doc ->
                    if (uiState.isSelectionMode) {
                        viewModel.onDocumentSelectToggle(doc.id)
                    } else {
                        onDocumentClick(doc.id)
                    }
                },
                onDocumentLongPress = { doc ->
                    viewModel.onDocumentLongPress(doc.id)
                },
                resolveSmallPreviewPath = viewModel::getSmallPreviewAbsolutePath,
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
            )
        }

        AnimatedVisibility(
            visible = uiState.isSelectionMode,
            enter = slideInVertically(
                initialOffsetY = { -it },
                animationSpec = tween(250),
            ),
            exit = slideOutVertically(
                targetOffsetY = { -it },
                animationSpec = tween(250),
            ),
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding(),
        ) {
            SelectionModeBar(
                selectedCount = uiState.selectedIds.size,
                onClose = { viewModel.onExitSelectionMode() },
                onDelete = { viewModel.onDeleteSelectedClick() },
            )
        }

        if (!uiState.isSelectionMode) {
            FloatingActionButton(
                onClick = onNewScanClick,
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .navigationBarsPadding()
                    .padding(end = 24.dp, bottom = 24.dp),
            ) {
                Icon(Icons.Default.CameraAlt, contentDescription = "新規スキャン")
            }
        }
    }

    if (uiState.showDeleteConfirmation) {
        ConfirmDialog(
            title = "削除の確認",
            message = "${uiState.selectedIds.size}件の文書を削除しますか？この操作は取り消せません。",
            confirmText = "削除",
            confirmColor = MaterialTheme.colorScheme.error,
            onConfirm = { viewModel.onDeleteConfirmed() },
            onDismiss = { viewModel.onDeleteDismissed() },
        )
    }
}

@Composable
private fun EmptyState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Default.Description,
            contentDescription = null,
            modifier = Modifier.size(64.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            "文書がありません",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "右下のボタンからスキャンを開始",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DocumentList(
    documents: List<DocumentSummaryTuple>,
    selectedIds: Set<Long>,
    isSelectionMode: Boolean,
    topContentPadding: androidx.compose.ui.unit.Dp,
    bottomContentPadding: androidx.compose.ui.unit.Dp,
    onDocumentClick: (DocumentSummaryTuple) -> Unit,
    onDocumentLongPress: (DocumentSummaryTuple) -> Unit,
    resolveSmallPreviewPath: (String) -> String,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            top = topContentPadding + 8.dp,
            bottom = bottomContentPadding + 8.dp,
        ),
    ) {
        items(documents, key = { it.id }) { doc ->
            val isSelected = selectedIds.contains(doc.id)

            DocumentItem(
                document = doc,
                isSelected = isSelected,
                isSelectionMode = isSelectionMode,
                resolveSmallPreviewPath = resolveSmallPreviewPath,
                modifier = Modifier
                    .fillMaxWidth()
                    .animateItem()
                    .combinedClickable(
                        onClick = { onDocumentClick(doc) },
                        onLongClick = {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            onDocumentLongPress(doc)
                        },
                    ),
            )
        }
    }
}

@Composable
private fun SelectionModeBar(
    selectedCount: Int,
    onClose: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(56.dp)
            .background(MaterialTheme.colorScheme.primary)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onClose) {
            Icon(
                Icons.Default.Close,
                contentDescription = "選択解除",
                tint = MaterialTheme.colorScheme.onPrimary,
            )
        }
        Text(
            text = "${selectedCount}件選択中",
            color = MaterialTheme.colorScheme.onPrimary,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Default.Delete,
                contentDescription = "削除",
                tint = MaterialTheme.colorScheme.onPrimary,
            )
        }
    }
}

@Composable
private fun DocumentItem(
    document: DocumentSummaryTuple,
    isSelected: Boolean,
    isSelectionMode: Boolean,
    resolveSmallPreviewPath: (String) -> String,
    modifier: Modifier = Modifier,
) {
    val scale by animateFloatAsState(
        targetValue = if (isSelected) 0.97f else 1f,
        animationSpec = tween(150),
        label = "itemScale",
    )
    val bgColor = if (isSelected) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        Color.Transparent
    }
    val absPath = remember(document.firstPageSmallPreviewPath) {
        document.firstPageSmallPreviewPath?.let(resolveSmallPreviewPath)
    }

    Row(
        modifier = modifier
            .scale(scale)
            .background(bgColor)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Thumbnail
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (isSelected) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.primary),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(24.dp),
                    )
                }
            } else {
                SmallPreviewImage(
                    absolutePath = absPath,
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(RoundedCornerShape(8.dp)),
                )
            }
        }

        Spacer(Modifier.width(16.dp))

        // Text info
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = document.name,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = buildString {
                    append("${document.pageCount}ページ")
                    append(" · ")
                    append(formatDate(document.updatedAt))
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
            )
        }
    }
}

private val dateFormat = SimpleDateFormat("yyyy/MM/dd", Locale.JAPAN)

private fun formatDate(millis: Long): String = dateFormat.format(Date(millis))
