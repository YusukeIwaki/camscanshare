package io.github.yusukeiwaki.camscanshare.ui.camerascan

import android.Manifest
import android.content.res.Configuration
import android.graphics.PointF
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import io.github.yusukeiwaki.camscanshare.data.image.DeshadowFilter
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessingDebugSink
import io.github.yusukeiwaki.camscanshare.ui.components.CameraBottomControlMode
import io.github.yusukeiwaki.camscanshare.ui.components.cameraBottomControlMode
import io.github.yusukeiwaki.camscanshare.ui.components.SmallPreviewImage
import kotlinx.coroutines.delay
import java.util.concurrent.Executors

private const val CAMERA_PREVIEW_PORTRAIT_ASPECT_RATIO = 3f / 4f
private const val CAMERA_PREVIEW_LANDSCAPE_ASPECT_RATIO = 4f / 3f

@Composable
fun CameraScanScreen(
    documentId: Long,
    retakePageId: Long = 0L,
    onClose: () -> Unit,
    onNavigateToPageList: (Long) -> Unit,
    viewModel: CameraScanViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptic = LocalHapticFeedback.current
    val isLandscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    val viewfinderAspectRatio = if (isLandscape) {
        CAMERA_PREVIEW_LANDSCAPE_ASPECT_RATIO
    } else {
        CAMERA_PREVIEW_PORTRAIT_ASPECT_RATIO
    }

    LaunchedEffect(documentId, retakePageId) {
        viewModel.initialize(documentId, retakePageId)
    }

    // Auto-close after retake is done
    LaunchedEffect(uiState.retakeDone) {
        if (uiState.retakeDone) {
            onClose()
        }
    }

    var cameraPermissionGranted by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted -> cameraPermissionGranted = granted }

    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) cameraPermissionGranted = true
        else permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    val imageCapture = remember { ImageCapture.Builder().build() }
    val previewResolutionSelector = remember {
        ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
            .build()
    }
    val cameraExecutor = remember { Executors.newSingleThreadExecutor() }
    val normalDebugSink = remember { ImageProcessingDebugSink.noOp() }
    val imageProcessor = remember(normalDebugSink) {
        ImageProcessor(normalDebugSink, DeshadowFilter(context.applicationContext, normalDebugSink))
    }
    val documentSegmenter = remember { DocumentSegmenter(context.applicationContext) }
    val paperDetector = remember(normalDebugSink, documentSegmenter) {
        lazy { PaperDetector(normalDebugSink, documentSegmenter) }
    }

    // Detected corners for overlay (normalized 0..1) + source image aspect ratio
    var detectedCorners by remember { mutableStateOf<List<PointF>?>(null) }
    var analysisImageAspectRatio by remember { mutableStateOf(3f / 4f) } // width/height of rotated analysis image
    var showReportChip by remember { mutableStateOf(false) }
    var reportCaptureArmed by remember { mutableStateOf(false) }

    LaunchedEffect(cameraPermissionGranted) {
        showReportChip = false
        reportCaptureArmed = false
        if (cameraPermissionGranted) {
            delay(5_000)
            showReportChip = true
        }
    }

    DisposableEffect(Unit) {
        onDispose { cameraExecutor.shutdown() }
    }

    val bottomControlMode = if (uiState.retakePageId != 0L) {
        CameraBottomControlMode.CLOSE_BUTTON
    } else {
        cameraBottomControlMode(uiState.capturedPageCount)
    }
    val onCaptureClick = {
        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
        val captureForReport = reportCaptureArmed
        val debugCaptureId = if (captureForReport) {
            ImageProcessingDebugSink.newCaptureId()
        } else {
            null
        }
        val previewCornersAtCapture = detectedCorners?.map { PointF(it.x, it.y) }
        reportCaptureArmed = false
        imageCapture.takePicture(
            cameraExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    val captureDebugSink = if (captureForReport) {
                        ImageProcessingDebugSink.fromContext(
                            context,
                            isWritingEnabled = true,
                            debugCaptureId = debugCaptureId,
                        )
                    } else {
                        normalDebugSink
                    }
                    val captureImageProcessor = if (captureForReport) {
                        ImageProcessor(
                            captureDebugSink,
                            DeshadowFilter(context.applicationContext, captureDebugSink),
                        )
                    } else {
                        imageProcessor
                    }
                    val capturePaperDetector = if (captureForReport) {
                        PaperDetector(captureDebugSink, documentSegmenter)
                    } else {
                        paperDetector.value
                    }
                    var bitmap = captureImageProcessor.toBitmapWithCorrectRotation(image)
                    image.close()
                    Log.d("CameraScan", "Captured image size: ${bitmap.width}x${bitmap.height}")
                    // Re-detect paper in the captured image and apply perspective correction
                    val corners = capturePaperDetector.detectForCapture(bitmap, previewCornersAtCapture)
                    if (corners != null && corners.size == 4) {
                        val corrected = capturePaperDetector.correctDocumentGeometry(bitmap, corners)
                        Log.d("CameraScan", "Corrected image size: ${corrected.width}x${corrected.height}")
                        bitmap.recycle()
                        bitmap = corrected
                    }
                    viewModel.onCaptureImage(
                        bitmap,
                        isDebugCapture = captureForReport,
                        debugCaptureId = debugCaptureId,
                    )
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e("CameraScan", "Capture failed", exception)
                }
            },
        )
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (cameraPermissionGranted) {
            BoxWithConstraints(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                val containerAspect = if (maxHeight.value > 0f) {
                    maxWidth.value / maxHeight.value
                } else {
                    viewfinderAspectRatio
                }
                val viewfinderModifier = if (containerAspect > viewfinderAspectRatio) {
                    Modifier
                        .fillMaxHeight()
                        .aspectRatio(viewfinderAspectRatio, matchHeightConstraintsFirst = true)
                } else {
                    Modifier
                        .fillMaxWidth()
                        .aspectRatio(viewfinderAspectRatio)
                }

                Box(modifier = viewfinderModifier.background(Color.Black)) {
                    // Camera preview with ImageAnalysis for detection. The viewfinder matches
                    // the 4:3 capture frame in the current display orientation without cropping.
                    AndroidView(
                        factory = { ctx ->
                            PreviewView(ctx).also { previewView ->
                                previewView.scaleType = PreviewView.ScaleType.FIT_CENTER
                                val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                                cameraProviderFuture.addListener({
                                    val cameraProvider = cameraProviderFuture.get()
                                    val preview = Preview.Builder()
                                        .setResolutionSelector(previewResolutionSelector)
                                        .build()
                                        .also {
                                            it.surfaceProvider = previewView.surfaceProvider
                                        }

                                    val imageAnalysis = ImageAnalysis.Builder()
                                        .setResolutionSelector(previewResolutionSelector)
                                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                        .build()
                                        .also { analysis ->
                                            analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                                                try {
                                                    val bitmap = imageProcessor.toBitmapWithCorrectRotation(imageProxy)
                                                    analysisImageAspectRatio = bitmap.width.toFloat() / bitmap.height.toFloat()
                                                    val corners = paperDetector.value.detectStabilized(bitmap)
                                                    detectedCorners = corners
                                                    bitmap.recycle()
                                                } catch (e: Exception) {
                                                    Log.e("CameraScan", "Detection failed", e)
                                                } finally {
                                                    imageProxy.close()
                                                }
                                            }
                                        }

                                    try {
                                        cameraProvider.unbindAll()
                                        cameraProvider.bindToLifecycle(
                                            lifecycleOwner,
                                            CameraSelector.DEFAULT_BACK_CAMERA,
                                            preview,
                                            imageCapture,
                                            imageAnalysis,
                                        )
                                    } catch (e: Exception) {
                                        Log.e("CameraScan", "Camera bind failed", e)
                                    }
                                }, ContextCompat.getMainExecutor(ctx))
                            }
                        },
                        modifier = Modifier.fillMaxSize(),
                    )

                    // Detection overlay maps normalized image coords into the FIT_CENTER preview.
                    val corners = detectedCorners
                    val animatedCorners = corners?.mapIndexed { i, pt ->
                        val ax by animateFloatAsState(pt.x, tween(150), label = "cx$i")
                        val ay by animateFloatAsState(pt.y, tween(150), label = "cy$i")
                        PointF(ax, ay)
                    }
                    if (animatedCorners != null && animatedCorners.size == 4) {
                        @Suppress("NAME_SHADOWING")
                        val corners = animatedCorners
                        Canvas(modifier = Modifier.fillMaxSize()) {
                            val viewW = size.width
                            val viewH = size.height
                            val viewAspect = viewW / viewH
                            val imgAspect = analysisImageAspectRatio

                            val pts = corners.map { corner ->
                                if (imgAspect > viewAspect) {
                                    val scaledImgH = viewW / imgAspect
                                    val offsetY = (viewH - scaledImgH) / 2f
                                    Offset(corner.x * viewW, offsetY + corner.y * scaledImgH)
                                } else {
                                    val scaledImgW = viewH * imgAspect
                                    val offsetX = (viewW - scaledImgW) / 2f
                                    Offset(offsetX + corner.x * scaledImgW, corner.y * viewH)
                                }
                            }

                            val path = Path().apply {
                                moveTo(pts[0].x, pts[0].y)
                                pts.drop(1).forEach { lineTo(it.x, it.y) }
                                close()
                            }
                            drawPath(path, Color(0x181A73E8))
                            drawPath(path, Color(0xFF1A73E8), style = Stroke(width = 3f))
                            for (pt in pts) {
                                drawCircle(Color(0xFF1A73E8), radius = 8f, center = pt)
                            }
                        }
                    }
                }
            }
        } else {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text("カメラの使用を許可してください", color = Color.White, textAlign = TextAlign.Center)
            }
        }

        AnimatedVisibility(
            visible = cameraPermissionGranted && showReportChip,
            modifier = if (isLandscape) {
                Modifier
                    .align(Alignment.TopStart)
                    .padding(top = 24.dp, start = 16.dp)
            } else {
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 52.dp, end = 16.dp)
            },
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(120)),
        ) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(18.dp))
                    .background(
                        if (reportCaptureArmed) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            Color.Black.copy(alpha = 0.58f)
                        }
                    )
                    .border(
                        width = 1.dp,
                        color = Color.White.copy(alpha = if (reportCaptureArmed) 0.72f else 0.32f),
                        shape = RoundedCornerShape(18.dp),
                    )
                    .clickable {
                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                        reportCaptureArmed = !reportCaptureArmed
                    }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "開発元に報告",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        // Flash overlay
        AnimatedVisibility(
            visible = uiState.showFlash,
            enter = fadeIn(tween(50)),
            exit = fadeOut(tween(350)),
        ) {
            Box(modifier = Modifier.fillMaxSize().background(Color.White.copy(alpha = 0.9f)))
        }

        // Flying page animation: image flies from center to thumbnail stack
        val flyingBitmap = uiState.flyingThumbnail
        if (flyingBitmap != null) {
            val animProgress = remember { Animatable(0f) }
            LaunchedEffect(flyingBitmap) {
                animProgress.snapTo(0f)
                animProgress.animateTo(1f, tween(600, easing = androidx.compose.animation.core.FastOutSlowInEasing))
                viewModel.onFlyingAnimationDone()
            }
            val progress = animProgress.value
            // Start: center of screen, scale 0.6. End: bottom-left thumbnail area, scale 0.12
            val startX = 0.5f
            val startY = 0.45f
            val endX = if (isLandscape) 0.9f else 0.1f
            val endY = if (isLandscape) 0.86f else 0.88f
            val currentX = startX + (endX - startX) * progress
            val currentY = startY + (endY - startY) * progress
            val currentScale = 0.6f + (0.12f - 0.6f) * progress
            val currentAlpha = 1f - progress * 0.3f
            val currentRotation = -5f * progress

            Image(
                bitmap = flyingBitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        translationX = currentX * size.width - size.width / 2
                        translationY = currentY * size.height - size.height / 2
                        scaleX = currentScale
                        scaleY = currentScale
                        alpha = currentAlpha
                        rotationZ = currentRotation
                    },
                contentScale = ContentScale.Fit,
            )
        }

        if (isLandscape) {
            LandscapeCameraControls(
                bottomControlMode = bottomControlMode,
                lastPageSmallPreviewAbsPath = uiState.lastPageSmallPreviewAbsPath,
                capturedPageCount = uiState.capturedPageCount,
                isCaptureEnabled = !uiState.isCapturing && cameraPermissionGranted,
                onClose = onClose,
                onNavigateToPageList = { onNavigateToPageList(uiState.documentId) },
                onCaptureClick = onCaptureClick,
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        } else {
            PortraitCameraControls(
                bottomControlMode = bottomControlMode,
                lastPageSmallPreviewAbsPath = uiState.lastPageSmallPreviewAbsPath,
                capturedPageCount = uiState.capturedPageCount,
                isCaptureEnabled = !uiState.isCapturing && cameraPermissionGranted,
                onClose = onClose,
                onNavigateToPageList = { onNavigateToPageList(uiState.documentId) },
                onCaptureClick = onCaptureClick,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Composable
private fun PortraitCameraControls(
    bottomControlMode: CameraBottomControlMode,
    lastPageSmallPreviewAbsPath: String?,
    capturedPageCount: Int,
    isCaptureEnabled: Boolean,
    onClose: () -> Unit,
    onNavigateToPageList: () -> Unit,
    onCaptureClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(
                brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                    colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)),
                )
            )
            .navigationBarsPadding()
            .padding(bottom = 24.dp, top = 40.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CameraLeftAction(
                mode = bottomControlMode,
                lastPageSmallPreviewAbsPath = lastPageSmallPreviewAbsPath,
                capturedPageCount = capturedPageCount,
                onClose = onClose,
                onNavigateToPageList = onNavigateToPageList,
            )
            CameraCaptureButton(
                enabled = isCaptureEnabled,
                onClick = onCaptureClick,
            )
            Spacer(Modifier.width(52.dp))
        }
    }
}

@Composable
private fun LandscapeCameraControls(
    bottomControlMode: CameraBottomControlMode,
    lastPageSmallPreviewAbsPath: String?,
    capturedPageCount: Int,
    isCaptureEnabled: Boolean,
    onClose: () -> Unit,
    onNavigateToPageList: () -> Unit,
    onCaptureClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxHeight()
            .width(132.dp)
            .background(
                brush = androidx.compose.ui.graphics.Brush.horizontalGradient(
                    colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)),
                )
            )
            .navigationBarsPadding()
            .padding(end = 24.dp, top = 24.dp, bottom = 24.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxHeight().align(Alignment.CenterEnd),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Spacer(Modifier.height(52.dp))
            CameraCaptureButton(
                enabled = isCaptureEnabled,
                onClick = onCaptureClick,
            )
            CameraLeftAction(
                mode = bottomControlMode,
                lastPageSmallPreviewAbsPath = lastPageSmallPreviewAbsPath,
                capturedPageCount = capturedPageCount,
                onClose = onClose,
                onNavigateToPageList = onNavigateToPageList,
            )
        }
    }
}

@Composable
private fun CameraLeftAction(
    mode: CameraBottomControlMode,
    lastPageSmallPreviewAbsPath: String?,
    capturedPageCount: Int,
    onClose: () -> Unit,
    onNavigateToPageList: () -> Unit,
) {
    when (mode) {
        CameraBottomControlMode.CLOSE_BUTTON -> {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White.copy(alpha = 0.15f))
                    .border(1.5.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                    .clickable { onClose() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = "閉じる",
                    tint = Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }
        }

        CameraBottomControlMode.THUMBNAIL_STACK -> {
            Box(
                modifier = Modifier.size(52.dp).clickable { onNavigateToPageList() },
            ) {
                SmallPreviewImage(
                    absolutePath = lastPageSmallPreviewAbsPath,
                    modifier = Modifier
                        .size(52.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .border(1.5.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(12.dp)),
                    contentDescription = "撮影済みページ",
                )
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .offset(x = 6.dp, y = (-6).dp)
                        .height(20.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.primary)
                        .padding(horizontal = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "$capturedPageCount",
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}

@Composable
private fun CameraCaptureButton(
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(72.dp)
            .clip(CircleShape)
            .border(4.dp, Color.White, CircleShape)
            .padding(6.dp)
            .clip(CircleShape)
            .background(Color.White)
            .clickable(enabled = enabled) { onClick() },
    )
}
