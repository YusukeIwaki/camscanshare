package io.github.yusukeiwaki.camscanshare.ui.pagelist

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddAPhoto
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.yusukeiwaki.camscanshare.data.db.PageEntity
import io.github.yusukeiwaki.camscanshare.ui.components.PageListPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.computePageAspectRatio
import io.github.yusukeiwaki.camscanshare.ui.components.pageListPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.rememberBitmapFromAbsolutePath
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun PageListScreen(
    documentId: Long,
    onBack: () -> Unit,
    onPageClick: (Int) -> Unit,
    onAddPageClick: () -> Unit,
    viewModel: PageListViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val shareProgress = uiState.shareProgress

    LaunchedEffect(documentId) {
        viewModel.initialize(documentId)
    }

    // Drag state
    var draggedIndex by remember { mutableIntStateOf(-1) }
    var dragOffsetX by remember { mutableStateOf(0f) }
    var dragOffsetY by remember { mutableStateOf(0f) }
    var overDeleteZone by remember { mutableStateOf(false) }
    // Track card center Y in root coords + pointer's offset from card center (always ≥ 0)
    var cardCenterRootY by remember { mutableStateOf(0f) }
    var pointerBelowCenter by remember { mutableStateOf(0f) } // max(0, pointerLocalY - cardHeight/2)
    val density = androidx.compose.ui.platform.LocalDensity.current
    val deleteZoneHeightPx = with(density) { 80.dp.toPx() }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        enabled = !uiState.isSharing,
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                },
                title = {
                    Row(
                        modifier = Modifier.clickable(
                            enabled = !uiState.isSharing,
                            onClick = { viewModel.onRenameClick() },
                        ),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            uiState.documentName,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { viewModel.sharePdf(context) },
                        enabled = !uiState.isSharing,
                    ) {
                        Icon(
                            Icons.Default.Share,
                            contentDescription = "共有",
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
            )
        },
        floatingActionButton = {
            if (!uiState.isDragActive && !uiState.isSharing) {
                FloatingActionButton(
                    onClick = onAddPageClick,
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    shape = RoundedCornerShape(16.dp),
                ) {
                    Icon(Icons.Default.AddAPhoto, contentDescription = "ページ追加")
                }
            }
        },
    ) { innerPadding ->
        var containerBottomInRoot by remember { mutableStateOf(0f) }
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)
            .onGloballyPositioned {
                containerBottomInRoot = it.positionInRoot().y + it.size.height.toFloat()
            }
        ) {
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                contentPadding = PaddingValues(16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                userScrollEnabled = !uiState.isSharing,
                modifier = Modifier.fillMaxSize()
                    .then(if (uiState.isDragActive) Modifier.zIndex(99f) else Modifier),
            ) {
                itemsIndexed(uiState.pages, key = { _, page -> page.id }) { index, page ->
                    val isDragging = draggedIndex == index

                    PageCard(
                        page = page,
                        pageNumber = index + 1,
                        largePreviewAbsPath = page.largePreviewPath?.let(viewModel::getLargePreviewAbsolutePath),
                        isDragging = isDragging,
                        dragOffsetX = if (isDragging) dragOffsetX else 0f,
                        dragOffsetY = if (isDragging) dragOffsetY else 0f,
                        interactionEnabled = !uiState.isSharing,
                        onClick = { onPageClick(index) },
                        onDragStart = { cardRootY, cardHeight, pointerLocalY ->
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            draggedIndex = index
                            dragOffsetX = 0f
                            dragOffsetY = 0f
                            cardCenterRootY = cardRootY + cardHeight / 2f
                            // How far below card center the pointer is (0 if above center)
                            pointerBelowCenter = maxOf(0f, pointerLocalY - cardHeight / 2f)
                            viewModel.onDragActiveChanged(true)
                        },
                        onDrag = { dx, dy ->
                            dragOffsetX += dx
                            dragOffsetY += dy
                            cardCenterRootY += dy
                            // effectiveY = card center + extra offset if pointer was below center
                            val effectiveY = cardCenterRootY + pointerBelowCenter
                            overDeleteZone = containerBottomInRoot > 0f &&
                                effectiveY > containerBottomInRoot - deleteZoneHeightPx
                        },
                        onDragEnd = {
                            if (overDeleteZone && draggedIndex >= 0) {
                                val pageToDelete = uiState.pages[draggedIndex]
                                viewModel.onPageDeleted(pageToDelete.id)
                            } else if (draggedIndex >= 0) {
                                // Calculate target index based on offset
                                val pages = uiState.pages
                                val targetIndex = (draggedIndex + (dragOffsetY / 200f).roundToInt().coerceIn(
                                    -draggedIndex,
                                    pages.size - 1 - draggedIndex,
                                )).coerceIn(0, pages.lastIndex)

                                if (targetIndex != draggedIndex) {
                                    val mutableIds = pages.map { it.id }.toMutableList()
                                    val movedId = mutableIds.removeAt(draggedIndex)
                                    mutableIds.add(targetIndex, movedId)
                                    viewModel.onPageReordered(mutableIds)
                                }
                            }
                            draggedIndex = -1
                            dragOffsetX = 0f
                            dragOffsetY = 0f
                            overDeleteZone = false
                            viewModel.onDragActiveChanged(false)
                        },
                    )
                }
            }

            // Delete zone (zIndex below dragged card so thumbnail is always on top)
            AnimatedVisibility(
                visible = uiState.isDragActive,
                enter = slideInVertically(initialOffsetY = { it }, animationSpec = tween(300)),
                exit = slideOutVertically(targetOffsetY = { it }, animationSpec = tween(300)),
                modifier = Modifier.align(Alignment.BottomCenter).zIndex(50f),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(80.dp)
                        .background(
                            if (overDeleteZone) MaterialTheme.colorScheme.error
                            else MaterialTheme.colorScheme.errorContainer
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = null,
                            tint = if (overDeleteZone) MaterialTheme.colorScheme.onError
                            else MaterialTheme.colorScheme.error,
                        )
                        Text(
                            "ここにドロップして削除",
                            color = if (overDeleteZone) MaterialTheme.colorScheme.onError
                            else MaterialTheme.colorScheme.error,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }

            if (shareProgress != null) {
                val currentPage = shareProgress.currentPageId?.let { currentPageId ->
                    uiState.pages.firstOrNull { it.id == currentPageId }
                }
                ShareProgressOverlay(
                    progress = shareProgress,
                    currentPage = currentPage,
                    getPreviewAbsolutePath = { page ->
                        page.largePreviewPath?.let(viewModel::getLargePreviewAbsolutePath)
                            ?: viewModel.getImageAbsolutePath(page.imagePath)
                    },
                    modifier = Modifier
                        .fillMaxSize()
                        .zIndex(200f),
                )
            }
        }
    }

    // Rename dialog
    if (uiState.showRenameDialog) {
        RenameDialog(
            currentName = uiState.documentName,
            onConfirm = { viewModel.onRenameConfirmed(it) },
            onDismiss = { viewModel.onRenameDismissed() },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PageCard(
    page: PageEntity,
    pageNumber: Int,
    largePreviewAbsPath: String?,
    isDragging: Boolean,
    dragOffsetX: Float,
    dragOffsetY: Float,
    interactionEnabled: Boolean,
    onClick: () -> Unit,
    onDragStart: (Float, Float, Float) -> Unit, // (cardRootY, cardHeight, pointerLocalY)
    onDrag: (Float, Float) -> Unit,
    onDragEnd: () -> Unit,
) {
    var cardRootY by remember { mutableStateOf(0f) }
    var cardHeight by remember { mutableStateOf(0f) }

    // Keep callbacks fresh so pointerInput always calls latest lambdas
    val currentOnDragStart by rememberUpdatedState(onDragStart)
    val currentOnDrag by rememberUpdatedState(onDrag)
    val currentOnDragEnd by rememberUpdatedState(onDragEnd)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .onGloballyPositioned {
                if (!isDragging) {
                    cardRootY = it.positionInRoot().y
                    cardHeight = it.size.height.toFloat()
                }
            }
            // pointerInput BEFORE visual transforms so drag amounts are in root coordinates
            .then(
                if (interactionEnabled) {
                    Modifier.pointerInput(Unit) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = { offset ->
                                currentOnDragStart(cardRootY, cardHeight, offset.y)
                            },
                            onDrag = { change, dragAmount ->
                                change.consume()
                                currentOnDrag(dragAmount.x, dragAmount.y)
                            },
                            onDragEnd = { currentOnDragEnd() },
                            onDragCancel = { currentOnDragEnd() },
                        )
                    }
                } else {
                    Modifier
                }
            )
            .then(
                if (isDragging) Modifier
                    .zIndex(100f)
                    .offset { IntOffset(dragOffsetX.roundToInt(), dragOffsetY.roundToInt()) }
                    .graphicsLayer { scaleX = 1.08f; scaleY = 1.08f }
                else Modifier
            ),
    ) {
        val previewState = rememberBitmapFromAbsolutePath(largePreviewAbsPath)
        val previewBitmap = previewState.bitmap
        val contentMode = pageListPreviewContentMode(
            hasBitmap = previewBitmap != null,
            hasPreviewPath = largePreviewAbsPath != null,
            isLoading = previewState.isLoading,
        )
        val cardAspectRatio = remember(previewBitmap) {
            if (previewBitmap != null) computePageAspectRatio(previewBitmap.width, previewBitmap.height)
            else 1f
        }

        Card(
            modifier = Modifier
                .aspectRatio(cardAspectRatio)
                .fillMaxWidth()
                .then(
                    if (isDragging) Modifier.shadow(16.dp, RoundedCornerShape(12.dp))
                    else Modifier
                )
                .clickable(
                    enabled = interactionEnabled,
                    onClick = onClick,
                ),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
            elevation = CardDefaults.cardElevation(defaultElevation = if (isDragging) 8.dp else 1.dp),
        ) {
            when (contentMode) {
                PageListPreviewContentMode.IMAGE -> {
                    val bitmap = requireNotNull(previewBitmap)
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = "ページ $pageNumber",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop,
                    )
                }
                PageListPreviewContentMode.LOADING_PLACEHOLDER -> {
                    Box(
                        modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            strokeWidth = 2.5.dp,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                }
                PageListPreviewContentMode.NUMBER_PLACEHOLDER -> {
                    Box(
                        modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("$pageNumber", style = MaterialTheme.typography.titleLarge)
                    }
                }
            }
        }
        Text(
            text = "$pageNumber",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun ShareProgressOverlay(
    progress: SharePdfProgress,
    currentPage: PageEntity?,
    getPreviewAbsolutePath: (PageEntity) -> String?,
    modifier: Modifier = Modifier,
) {
    val previewAbsolutePath = currentPage?.let(getPreviewAbsolutePath)
    val previewState = rememberBitmapFromAbsolutePath(previewAbsolutePath)

    Box(
        modifier = modifier
            .background(Color.Black.copy(alpha = 0.24f))
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Card(
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        ) {
            Column(
                modifier = Modifier
                    .width(320.dp)
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    ),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(180.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Crossfade(
                            targetState = previewState.bitmap,
                            animationSpec = tween(durationMillis = 180),
                            label = "share-progress-preview",
                        ) { bitmap ->
                            if (bitmap != null) {
                                Image(
                                    bitmap = bitmap.asImageBitmap(),
                                    contentDescription = "処理中のページ",
                                    modifier = Modifier.fillMaxSize(),
                                    contentScale = ContentScale.Crop,
                                )
                            } else {
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    CircularProgressIndicator(
                                        strokeWidth = 2.5.dp,
                                        modifier = Modifier.size(28.dp),
                                    )
                                    Text(
                                        text = if (progress.currentPageIndex > 0) {
                                            "ページ ${progress.currentPageIndex}"
                                        } else {
                                            "準備中"
                                        },
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                    }
                }

                CircularProgressIndicator()

                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = progress.message,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (progress.totalPages > 0) {
                        Text(
                            text = "${progress.currentPageIndex} / ${progress.totalPages} ページ",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (currentPage != null && progress.currentPageIndex > 0) {
                        Text(
                            text = "ページ ${progress.currentPageIndex} を処理中",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                LinearProgressIndicator(
                    progress = { progress.progressFraction },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun RenameDialog(
    currentName: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(currentName) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("ドキュメント名を変更") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text) },
                enabled = text.trim().isNotEmpty(),
            ) {
                Text("変更")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("キャンセル")
            }
        },
    )
}
