package io.github.yusukeiwaki.camscanshare.ui.improvementreport

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material3.Card
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.github.yusukeiwaki.camscanshare.ui.components.ConfirmDialog
import io.github.yusukeiwaki.camscanshare.ui.components.computePageAspectRatio
import io.github.yusukeiwaki.camscanshare.ui.components.rememberBitmapFromAbsolutePath
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImprovementReportScreen(
    pageId: Long,
    sourceImagePath: String,
    rotationDegrees: Int,
    currentFilterKey: String,
    onClose: () -> Unit,
    viewModel: ImprovementReportViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            tryTakePersistablePermission(context, uri)
            viewModel.onPhotoPicked(uri)
        }
    }

    LaunchedEffect(pageId, sourceImagePath, rotationDegrees, currentFilterKey) {
        viewModel.initialize(
            pageId = pageId,
            sourceImagePath = sourceImagePath,
            rotationDegrees = rotationDegrees,
            currentFilterKey = currentFilterKey,
        )
    }

    LaunchedEffect(uiState.shouldClose) {
        if (uiState.shouldClose) {
            onClose()
        }
    }

    BackHandler {
        if (viewModel.onBackRequested()) {
            onClose()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = {
                        if (viewModel.onBackRequested()) {
                            onClose()
                        }
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                },
                title = {
                    Column {
                        Text("改善レポート送信")
                        Text(
                            "元画像と全フィルタ結果を送信",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
            )
        },
        bottomBar = {
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                tonalElevation = 3.dp,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        when {
                            uiState.isSending -> "改善レポートを送信中..."
                            uiState.previews.any { it.isLoading } -> "変換プレビューが出そろうまで送信できません。途中で戻ると、この画面はそのまま閉じます。"
                            uiState.comment.isBlank() -> "コメントを入力すると送信ボタンが有効になります。"
                            uiState.attachments.isNotEmpty() -> "追加写真 ${uiState.attachments.size} 枚も含めて送信されます。未送信のまま戻ると、この改善レポートは破棄されます。"
                            else -> "未送信のまま戻ると、この改善レポートは破棄されます。"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        TextButton(
                            onClick = {
                                if (viewModel.onBackRequested()) {
                                    onClose()
                                }
                            },
                            modifier = Modifier.weight(0.32f),
                            enabled = !uiState.isSending,
                        ) {
                            Text("キャンセル")
                        }
                        Button(
                            onClick = {
                                launchQrScanner(
                                    context = context,
                                    onSuccess = { rawValue ->
                                        if (rawValue.isNullOrBlank()) {
                                            viewModel.onScannerFailed("QRコードの内容を読み取れませんでした。")
                                        } else {
                                            viewModel.submitScannedConfig(rawValue)
                                        }
                                    },
                                    onFailure = { message ->
                                        viewModel.onScannerFailed(message)
                                    },
                                )
                            },
                            enabled = viewModel.canSend(),
                            modifier = Modifier.weight(0.68f),
                            contentPadding = PaddingValues(vertical = 12.dp),
                        ) {
                            if (uiState.isSending) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    color = MaterialTheme.colorScheme.onPrimary,
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                Text("改善レポートサーバーへ")
                            }
                        }
                    }
                }
            }
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                ReportInfoCard(
                    appVersion = uiState.appVersion,
                    buildNumber = uiState.buildNumber,
                    timestampJst = uiState.timestampJst,
                    comment = uiState.comment,
                    onCommentChanged = viewModel::onCommentChanged,
                )
            }

            item {
                AttachmentCard(
                    attachments = uiState.attachments,
                    onAddPhoto = {
                        photoPickerLauncher.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    },
                    enabled = !uiState.isSending,
                )
            }

            if (uiState.previews.any { it.isLoading }) {
                item {
                    ProgressCard(
                        readyCount = uiState.previews.count { !it.isLoading && it.absolutePath != null },
                        totalCount = uiState.previews.size,
                    )
                }
            }

            items(uiState.previews, key = { it.filter.filterKey }) { preview ->
                PreviewCard(preview = preview)
            }
        }
    }

    if (uiState.showDiscardDialog) {
        ConfirmDialog(
            title = "改善レポートを送信せずにもどりますか？",
            message = "生成済みのプレビュー、追加した写真、入力したコメントは破棄されます。",
            confirmText = "OK",
            onConfirm = {
                viewModel.onDiscardConfirmed()
            },
            onDismiss = {
                viewModel.onDiscardDismissed()
            },
        )
    }

    if (uiState.errorMessage != null) {
        ConfirmDialog(
            title = "送信に失敗しました",
            message = uiState.errorMessage ?: "",
            confirmText = "再試行",
            dismissText = "キャンセル",
            onConfirm = {
                viewModel.clearError()
                launchQrScanner(
                    context = context,
                    onSuccess = { rawValue ->
                        if (rawValue.isNullOrBlank()) {
                            viewModel.onScannerFailed("QRコードの内容を読み取れませんでした。")
                        } else {
                            viewModel.submitScannedConfig(rawValue)
                        }
                    },
                    onFailure = { message ->
                        viewModel.onScannerFailed(message)
                    },
                )
            },
            onDismiss = {
                viewModel.clearError()
            },
        )
    }

    if (uiState.showSuccessFeedback) {
        SuccessFeedbackOverlay()
    }
}

@Composable
private fun SuccessFeedbackOverlay() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.28f)),
        contentAlignment = Alignment.Center,
    ) {
        Card(
            shape = RoundedCornerShape(28.dp),
        ) {
            Column(
                modifier = Modifier
                    .width(240.dp)
                    .padding(horizontal = 24.dp, vertical = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    "✔",
                    fontSize = 40.sp,
                    color = Color(0xFF137333),
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "レポート送信完了",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun AttachmentCard(
    attachments: List<ImprovementReportAttachmentState>,
    onAddPhoto: () -> Unit,
    enabled: Boolean,
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("追加で送る写真", fontWeight = FontWeight.Bold)
                    Text(
                        "比較用の写真を任意で追加できます。画像のみ追加可能で、PDF などは選択できません。全フィルタの生成中でも操作できます。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Button(onClick = onAddPhoto, enabled = enabled) {
                    Icon(
                        imageVector = Icons.Default.AddPhotoAlternate,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Text("写真を追加")
                }
            }

            if (attachments.isEmpty()) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    color = MaterialTheme.colorScheme.surface,
                    tonalElevation = 1.dp,
                ) {
                    Text(
                        "追加写真はまだありません。CamScanner との比較画像など、補足したい写真がある場合だけ追加します。",
                        modifier = Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    attachments.forEachIndexed { index, attachment ->
                        AttachmentItem(
                            attachment = attachment,
                            index = index,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachmentItem(
    attachment: ImprovementReportAttachmentState,
    index: Int,
) {
    val bitmapState = rememberBitmapFromUriString(attachment.attachment.uriString)

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(84.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    bitmapState.bitmap != null -> {
                        Image(
                            bitmap = bitmapState.bitmap.asImageBitmap(),
                            contentDescription = attachment.attachment.displayName,
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                        )
                    }

                    bitmapState.isLoading -> {
                        CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 3.dp)
                    }

                    else -> {
                        Text(
                            "画像",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    attachment.attachment.displayName,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "写真 ${index + 1} / 追加画像として一緒に送信",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ReportInfoCard(
    appVersion: String,
    buildNumber: String,
    timestampJst: String,
    comment: String,
    onCommentChanged: (String) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("レポート情報", fontWeight = FontWeight.Bold)
            ReadOnlyField(label = "アプリのバージョン / ビルド番号", value = "$appVersion ($buildNumber)")
            ReadOnlyField(label = "日時 (JST)", value = timestampJst)
            OutlinedTextField(
                value = comment,
                onValueChange = onCommentChanged,
                label = { Text("コメント (必須)") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                maxLines = 6,
                supportingText = {
                    Text("${comment.length} / 300")
                },
            )
        }
    }
}

@Composable
private fun ReadOnlyField(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 1.dp,
        ) {
            Text(
                value,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun ProgressCard(
    readyCount: Int,
    totalCount: Int,
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 3.dp,
            )
            Column {
                Text(
                    "変換プレビューを生成中...",
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "$readyCount / $totalCount 件の画像を準備しました。すべて完了すると送信ボタンが活性化します。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun PreviewCard(preview: ImprovementReportPreviewState) {
    val bitmapState = rememberBitmapFromAbsolutePath(preview.absolutePath)
    val bitmap = bitmapState.bitmap
    val aspectRatio = if (bitmap != null) {
        computePageAspectRatio(bitmap.width, bitmap.height)
    } else {
        210f / 297f
    }

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(preview.filter.displayName, fontWeight = FontWeight.Bold)
                Text(
                    when {
                        preview.isLoading || bitmapState.isLoading -> "生成中"
                        preview.errorMessage != null -> "エラー"
                        else -> "準備完了"
                    },
                    fontSize = 12.sp,
                    color = when {
                        preview.errorMessage != null -> MaterialTheme.colorScheme.error
                        preview.isLoading || bitmapState.isLoading -> MaterialTheme.colorScheme.onSurfaceVariant
                        else -> Color(0xFF137333)
                    },
                )
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(aspectRatio)
                    .shadow(6.dp, RoundedCornerShape(16.dp))
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.White)
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    preview.errorMessage != null -> {
                        Text(
                            preview.errorMessage,
                            modifier = Modifier.padding(16.dp),
                            color = MaterialTheme.colorScheme.error,
                        )
                    }

                    bitmap != null -> {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "${preview.filter.displayName} プレビュー",
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Fit,
                        )
                    }

                    else -> {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 3.dp)
                            Text(
                                "プレビューを準備中…",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun launchQrScanner(
    context: Context,
    onSuccess: (String?) -> Unit,
    onFailure: (String) -> Unit,
) {
    val activity = context.findActivity()
    if (activity == null) {
        onFailure("QRコードリーダーを起動できませんでした。")
        return
    }

    val options = GmsBarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
        .build()

    val scanner = GmsBarcodeScanning.getClient(activity, options)
    scanner.startScan()
        .addOnSuccessListener { barcode ->
            onSuccess(barcode.rawValue)
        }
        .addOnFailureListener { error ->
            onFailure(error.message ?: "QRコードの読み取りに失敗しました。")
        }
        .addOnCanceledListener {
            // User dismissed the scanner intentionally. Keep the current screen state.
        }
}

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is android.content.ContextWrapper -> baseContext.findActivity()
    else -> null
}

private data class UriBitmapState(
    val bitmap: Bitmap? = null,
    val isLoading: Boolean = true,
)

@Composable
private fun rememberBitmapFromUriString(uriString: String?): UriBitmapState {
    val context = LocalContext.current
    return produceState(initialValue = UriBitmapState(), uriString) {
        if (uriString.isNullOrBlank()) {
            value = UriBitmapState(bitmap = null, isLoading = false)
            return@produceState
        }

        value = UriBitmapState(bitmap = null, isLoading = true)
        val bitmap = withContext(Dispatchers.IO) {
            decodeBitmapFromUri(context, Uri.parse(uriString), 512)
        }
        value = UriBitmapState(bitmap = bitmap, isLoading = false)
    }.value
}

private fun decodeBitmapFromUri(
    context: Context,
    uri: Uri,
    maxDimension: Int,
): Bitmap? {
    val resolver = context.contentResolver
    val boundsOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { input ->
        BitmapFactory.decodeStream(input, null, boundsOptions)
    } ?: return null

    if (boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) {
        return null
    }

    val sampleSize = calculateInSampleSize(boundsOptions.outWidth, boundsOptions.outHeight, maxDimension)
    val decodeOptions = BitmapFactory.Options().apply {
        inSampleSize = sampleSize
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }
    return resolver.openInputStream(uri)?.use { input ->
        BitmapFactory.decodeStream(input, null, decodeOptions)
    }
}

private fun calculateInSampleSize(
    width: Int,
    height: Int,
    maxDimension: Int,
): Int {
    var sampleSize = 1
    while (max(width, height) / sampleSize > maxDimension * 2) {
        sampleSize *= 2
    }
    return sampleSize
}

private fun tryTakePersistablePermission(
    context: Context,
    uri: Uri,
) {
    runCatching {
        context.contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
        )
    }
}
