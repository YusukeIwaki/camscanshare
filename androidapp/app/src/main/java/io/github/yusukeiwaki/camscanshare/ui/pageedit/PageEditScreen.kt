package io.github.yusukeiwaki.camscanshare.ui.pageedit

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.RotateLeft
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.yusukeiwaki.camscanshare.ui.components.ConfirmDialog
import io.github.yusukeiwaki.camscanshare.ui.components.PageEditPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.computePageAspectRatio
import io.github.yusukeiwaki.camscanshare.ui.components.pageEditPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.rememberAspectRatioFromAbsolutePath
import io.github.yusukeiwaki.camscanshare.ui.components.rememberBitmapFromAbsolutePath
import io.github.yusukeiwaki.camscanshare.ui.components.resolvePagePlaceholderAspectRatio

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun PageEditScreen(
    documentId: Long,
    initialPageIndex: Int,
    onBack: () -> Unit,
    onRetake: (pageId: Long) -> Unit,
    viewModel: PageEditViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val haptic = LocalHapticFeedback.current

    LaunchedEffect(documentId) {
        viewModel.initialize(documentId, initialPageIndex)
    }

    LaunchedEffect(uiState.applied) {
        if (uiState.applied) {
            kotlinx.coroutines.delay(1500)
            viewModel.onAppliedShown()
        }
    }

    val pagerState = rememberPagerState(
        initialPage = initialPageIndex,
        pageCount = { uiState.pages.size },
    )

    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.currentPage }.collect { page ->
            viewModel.onPageChanged(page)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = {
                        if (viewModel.onBackClick()) onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                },
                title = { Text("ページ編集") },
                actions = {
                    TextButton(onClick = { viewModel.onApplyClick() }) {
                        Text(
                            if (uiState.applied) "✓ 適用済み" else "適用",
                            color = if (uiState.applied) Color(0xFF137333) else MaterialTheme.colorScheme.primary,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
            ) {
                if (uiState.pages.isNotEmpty()) {
                    HorizontalPager(
                        state = pagerState,
                        modifier = Modifier.fillMaxSize(),
                    ) { pageIndex ->
                        val pageState = uiState.pages.getOrNull(pageIndex) ?: return@HorizontalPager
                        PagePreview(
                            pageState = pageState,
                            useWorkingPreview = viewModel.hasUnsavedPreviewEdits(pageState),
                            loadWorkingPreview = viewModel::getWorkingPreview,
                        )
                    }

                    if (uiState.pages.size > 1) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .padding(bottom = 8.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.Black.copy(alpha = 0.6f))
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                        ) {
                            Text(
                                "${uiState.currentPageIndex + 1} / ${uiState.pages.size}",
                                color = Color.White,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                            )
                        }
                    }
                }
            }

            ActionToolbar(
                onRotate = { viewModel.onRotateClick() },
                onRetake = {
                    val page = uiState.pages.getOrNull(uiState.currentPageIndex)
                    if (page != null) onRetake(page.pageId)
                },
                onFilter = { viewModel.onToggleFilterPanel() },
            )

            AnimatedVisibility(
                visible = uiState.showFilterPanel,
                enter = expandVertically(tween(300)),
                exit = shrinkVertically(tween(300)),
            ) {
                FilterPanel(
                    currentFilterKey = uiState.pages.getOrNull(uiState.currentPageIndex)?.filterKey ?: "original",
                    onFilterSelected = { viewModel.onFilterSelected(it.filterKey) },
                    onFilterLongPressed = {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        viewModel.onFilterLongPressed(it.filterKey)
                    },
                )
            }
        }
    }

    if (uiState.showDiscardDialog) {
        ConfirmDialog(
            title = "編集内容を破棄しますか？",
            message = "変更した回転やフィルタの設定は保存されません。",
            confirmText = "破棄",
            confirmColor = MaterialTheme.colorScheme.error,
            onConfirm = {
                viewModel.onDiscardConfirmed()
                onBack()
            },
            onDismiss = { viewModel.onDiscardDismissed() },
        )
    }

    if (uiState.showApplyAllDialog) {
        val filterName = ImageFilter.fromKey(uiState.applyAllFilterKey).displayName
        ConfirmDialog(
            title = "全ページに適用",
            message = "「${filterName}」フィルタを全ページに適用しますか？",
            confirmText = "適用",
            onConfirm = { viewModel.onApplyAllConfirmed() },
            onDismiss = { viewModel.onApplyAllDismissed() },
        )
    }
}

@Composable
private fun PagePreview(
    pageState: PageEditState,
    useWorkingPreview: Boolean,
    loadWorkingPreview: suspend (PageEditState) -> Bitmap?,
) {
    val largePreviewState = rememberBitmapFromAbsolutePath(pageState.largePreviewAbsPath)
    var workingBitmap by remember(
        pageState.pageId,
        pageState.imagePath,
        pageState.filterKey,
        pageState.rotationDegrees,
        useWorkingPreview,
    ) { mutableStateOf<Bitmap?>(null) }
    var isComputing by remember(
        pageState.pageId,
        pageState.imagePath,
        pageState.filterKey,
        pageState.rotationDegrees,
        useWorkingPreview,
    ) { mutableStateOf(useWorkingPreview) }

    LaunchedEffect(
        pageState.pageId,
        pageState.imagePath,
        pageState.filterKey,
        pageState.rotationDegrees,
        useWorkingPreview,
    ) {
        if (!useWorkingPreview) {
            workingBitmap = null
            isComputing = false
            return@LaunchedEffect
        }

        isComputing = true
        workingBitmap = loadWorkingPreview(pageState)
        isComputing = false
    }

    val displayBitmap = if (useWorkingPreview) workingBitmap else largePreviewState.bitmap
    val placeholderPath = pageState.largePreviewAbsPath ?: pageState.sourceImageAbsPath
    val placeholderAspectState = rememberAspectRatioFromAbsolutePath(placeholderPath)
    val previewAspectRatio = remember(displayBitmap) {
        if (displayBitmap != null) {
            computePageAspectRatio(displayBitmap.width, displayBitmap.height)
        } else {
            210f / 297f
        }
    }
    val placeholderAspectRatio = resolvePagePlaceholderAspectRatio(placeholderAspectState.aspectRatio)
    val contentMode = pageEditPreviewContentMode(
        useWorkingPreview = useWorkingPreview,
        hasWorkingBitmap = workingBitmap != null,
        isComputing = isComputing,
        hasLargeBitmap = largePreviewState.bitmap != null,
        hasLargePreviewPath = pageState.largePreviewAbsPath != null,
        isLargePreviewLoading = largePreviewState.isLoading,
    )

    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        when (contentMode) {
            PageEditPreviewContentMode.IMAGE -> {
                val bitmap = requireNotNull(displayBitmap)
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "ページプレビュー",
                    modifier = Modifier
                        .padding(24.dp)
                        .fillMaxWidth(if (previewAspectRatio >= 1f) 0.95f else 0.8f)
                        .aspectRatio(previewAspectRatio)
                        .shadow(8.dp, RoundedCornerShape(4.dp))
                        .clip(RoundedCornerShape(4.dp))
                        .background(Color.White),
                    contentScale = ContentScale.Fit,
                )
            }
            PageEditPreviewContentMode.PREVIEW_LOADING,
            PageEditPreviewContentMode.FILTER_LOADING,
            PageEditPreviewContentMode.EMPTY_PLACEHOLDER -> {
                Box(
                    modifier = Modifier
                        .padding(24.dp)
                        .fillMaxWidth(0.8f)
                        .aspectRatio(placeholderAspectRatio)
                        .shadow(8.dp, RoundedCornerShape(4.dp))
                        .clip(RoundedCornerShape(4.dp))
                        .background(Color.White)
                        .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(4.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    if (contentMode != PageEditPreviewContentMode.EMPTY_PLACEHOLDER) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            CircularProgressIndicator(
                                strokeWidth = 3.dp,
                                modifier = Modifier.size(32.dp),
                            )
                            Text(
                                if (contentMode == PageEditPreviewContentMode.FILTER_LOADING) "フィルタを適用中…" else "プレビューを準備中…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionToolbar(
    onRotate: () -> Unit,
    onRetake: () -> Unit,
    onFilter: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .padding(12.dp),
        horizontalArrangement = Arrangement.SpaceAround,
    ) {
        ToolbarAction(icon = Icons.AutoMirrored.Filled.RotateLeft, label = "回転", onClick = onRotate)
        ToolbarAction(icon = Icons.Default.CameraAlt, label = "撮り直し", onClick = onRetake)
        ToolbarAction(icon = Icons.Default.Tune, label = "フィルタ", onClick = onFilter)
    }
}

@Composable
private fun ToolbarAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            icon,
            contentDescription = label,
            modifier = Modifier.size(24.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FilterPanel(
    currentFilterKey: String,
    onFilterSelected: (ImageFilter) -> Unit,
    onFilterLongPressed: (ImageFilter) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "フィルタを選択",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "長押しで全ページに適用",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
        }

        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(bottom = 12.dp),
        ) {
            items(ImageFilter.entries.toList()) { filter ->
                FilterItem(
                    filter = filter,
                    isActive = filter.filterKey == currentFilterKey,
                    onClick = { onFilterSelected(filter) },
                    onLongClick = { onFilterLongPressed(filter) },
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FilterItem(
    filter: ImageFilter,
    isActive: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.combinedClickable(
            onClick = onClick,
            onLongClick = onLongClick,
        ),
    ) {
        Box(
            modifier = Modifier
                .size(width = 64.dp, height = 80.dp)
                .clip(RoundedCornerShape(8.dp))
                .then(
                    if (isActive) {
                        Modifier.border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(8.dp))
                    } else {
                        Modifier.border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(8.dp))
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                painter = painterResource(filter.thumbnailResId),
                contentDescription = "${filter.displayName} フィルタサムネイル",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            filter.displayName,
            fontSize = 11.sp,
            fontWeight = if (isActive) FontWeight.Bold else FontWeight.Medium,
            color = if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
