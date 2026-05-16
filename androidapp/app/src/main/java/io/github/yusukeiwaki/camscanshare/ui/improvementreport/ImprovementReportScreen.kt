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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddPhotoAlternate
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Card
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
import io.github.yusukeiwaki.camscanshare.data.reporting.ImprovementReportAttachment
import io.github.yusukeiwaki.camscanshare.ui.components.ConfirmDialog
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
    debugCaptureId: String?,
    onClose: () -> Unit,
    viewModel: ImprovementReportViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(),
    ) { uris ->
        if (uris.isNotEmpty()) {
            uris.forEach { uri ->
                tryTakePersistablePermission(context, uri)
            }
            viewModel.onPhotosPicked(uris)
        }
    }

    LaunchedEffect(pageId, sourceImagePath, rotationDegrees, currentFilterKey, debugCaptureId) {
        viewModel.initialize(
            pageId = pageId,
            sourceImagePath = sourceImagePath,
            rotationDegrees = rotationDegrees,
            currentFilterKey = currentFilterKey,
            debugCaptureId = debugCaptureId,
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
                            "デバッグ出力と比較写真を送信",
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
                            uiState.comment.isBlank() -> "コメントを入力すると送信ボタンが有効になります。"
                            uiState.attachments.isNotEmpty() -> "追加写真 ${uiState.attachments.size} 枚も含めて、この撮影の画像処理デバッグ出力とログを送信します。"
                            else -> "この撮影の画像処理デバッグ出力とログを送信します。未送信のまま戻ると、入力したコメントは破棄されます。"
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
                    onRemoveAttachment = viewModel::onRemoveAttachment,
                    enabled = !uiState.isSending,
                )
            }

            item {
                DebugPayloadCard()
            }
        }
    }

    if (uiState.showDiscardDialog) {
        ConfirmDialog(
            title = "改善レポートを送信せずにもどりますか？",
            message = "入力したコメントと追加写真は破棄されます。",
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
private fun AttachmentCard(
    attachments: List<ImprovementReportAttachment>,
    onAddPhoto: () -> Unit,
    onRemoveAttachment: (ImprovementReportAttachment) -> Unit,
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
                    Text("比較用の追加写真", fontWeight = FontWeight.Bold)
                    Text(
                        "CamScanner など別アプリの出力画像やスクリーンショットを任意で添付できます。",
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
                        "追加写真はまだありません。比較結果をコメントで説明したい場合だけ添付します。",
                        modifier = Modifier.padding(16.dp),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    attachments.forEachIndexed { index, attachment ->
                        AttachmentItem(
                            attachment = attachment,
                            index = index,
                            onRemoveAttachment = onRemoveAttachment,
                            enabled = enabled,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AttachmentItem(
    attachment: ImprovementReportAttachment,
    index: Int,
    onRemoveAttachment: (ImprovementReportAttachment) -> Unit,
    enabled: Boolean,
) {
    val bitmapState = rememberBitmapFromUriString(attachment.uriString)

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
                    .size(64.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    bitmapState.bitmap != null -> {
                        Image(
                            bitmap = bitmapState.bitmap.asImageBitmap(),
                            contentDescription = attachment.displayName,
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Crop,
                        )
                    }

                    bitmapState.isLoading -> {
                        CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 3.dp)
                    }

                    else -> {
                        Icon(
                            imageVector = Icons.Default.AddPhotoAlternate,
                            contentDescription = null,
                            modifier = Modifier.size(28.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(attachment.displayName, fontWeight = FontWeight.Bold)
                Text(
                    "追加写真 ${index + 1} / ${attachment.mimeType ?: "種類不明"}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            IconButton(
                onClick = { onRemoveAttachment(attachment) },
                enabled = enabled,
            ) {
                Icon(Icons.Default.Delete, contentDescription = "追加写真を削除")
            }
        }
    }
}

@Composable
private fun DebugPayloadCard() {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("送信されるデータ", fontWeight = FontWeight.Bold)
            Text(
                "各フィルタの再生成は行わず、端末内に保存済みのこの撮影のデバッグ成果物を zip にまとめて送信します。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            PayloadRow(
                label = "source.jpg",
                value = "対象ページの元画像が見つかった場合に同梱します。",
            )
            PayloadRow(
                label = "attachments/",
                value = "任意で追加した比較用写真を同梱します。",
            )
            PayloadRow(
                label = "debug/",
                value = "この撮影に紐づく画像処理セッションの metadata.json、中間 PNG、timings.jsonl をディレクトリごと同梱します。",
            )
        }
    }
}

@Composable
private fun PayloadRow(
    label: String,
    value: String,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(label, fontWeight = FontWeight.Bold)
            Text(
                value,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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
