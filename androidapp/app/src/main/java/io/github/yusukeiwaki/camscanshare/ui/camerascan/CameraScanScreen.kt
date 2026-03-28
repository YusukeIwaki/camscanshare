package io.github.yusukeiwaki.camscanshare.ui.camerascan

import android.Manifest
import android.graphics.PointF
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessor
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
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
import java.util.concurrent.Executors

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
    val lifecycleOwner = LocalLifecycleOwner.current
    val haptic = LocalHapticFeedback.current

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
    val cameraExecutor = remember { Executors.newSingleThreadExecutor() }
    val imageProcessor = remember { ImageProcessor() }
    val paperDetector = remember { lazy { PaperDetector() } }

    // Detected corners for overlay (normalized 0..1) + source image aspect ratio
    var detectedCorners by remember { mutableStateOf<List<PointF>?>(null) }
    var analysisImageAspectRatio by remember { mutableStateOf(3f / 4f) } // width/height of rotated analysis image

    DisposableEffect(Unit) {
        onDispose { cameraExecutor.shutdown() }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (cameraPermissionGranted) {
            // Camera preview with ImageAnalysis for detection
            AndroidView(
                factory = { ctx ->
                    PreviewView(ctx).also { previewView ->
                        val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                        cameraProviderFuture.addListener({
                            val cameraProvider = cameraProviderFuture.get()
                            val preview = Preview.Builder().build().also {
                                it.surfaceProvider = previewView.surfaceProvider
                            }

                            val imageAnalysis = ImageAnalysis.Builder()
                                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                .build()
                                .also { analysis ->
                                    analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                                        try {
                                            val bitmap = imageProcessor.toBitmapWithCorrectRotation(imageProxy)
                                            analysisImageAspectRatio = bitmap.width.toFloat() / bitmap.height.toFloat()
                                            val corners = paperDetector.value.detect(bitmap)
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

            // Detection overlay — maps normalized image coords to preview coords
            // PreviewView uses FILL scale type: image is scaled up to fill the view, center-cropped
            val corners = detectedCorners
            if (corners != null && corners.size == 4) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val viewW = size.width
                    val viewH = size.height
                    val viewAspect = viewW / viewH
                    val imgAspect = analysisImageAspectRatio

                    // FILL: use the larger scale so image covers the entire view
                    val scale: Float
                    val offsetX: Float
                    val offsetY: Float
                    if (imgAspect > viewAspect) {
                        // Image is wider than view → crop left/right
                        scale = viewH // normalized coords * viewH = pixel in scaled image height
                        val scaledImgW = viewH * imgAspect
                        offsetX = (scaledImgW - viewW) / 2f
                        offsetY = 0f
                    } else {
                        // Image is taller than view → crop top/bottom
                        scale = viewW / imgAspect
                        offsetX = 0f
                        val scaledImgH = viewW / imgAspect
                        offsetY = (scaledImgH - viewH) / 2f
                    }

                    val pts = corners.map { corner ->
                        val imgX = corner.x * viewH * imgAspect  // if wider
                        val imgY = corner.y * viewH
                        if (imgAspect > viewAspect) {
                            Offset(corner.x * (viewH * imgAspect) - offsetX, corner.y * viewH - offsetY)
                        } else {
                            Offset(corner.x * (viewW) - offsetX, corner.y * (viewW / imgAspect) - offsetY)
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
        } else {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text("カメラの使用を許可してください", color = Color.White, textAlign = TextAlign.Center)
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
            val endX = 0.1f
            val endY = 0.88f
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

        // Bottom controls
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
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
                // Left: close button or thumbnail stack
                if (uiState.capturedPageCount == 0) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.15f))
                            .border(1.5.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                            .clickable { onClose() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Default.Close, contentDescription = "閉じる", tint = Color.White, modifier = Modifier.size(24.dp))
                    }
                } else {
                    Box(
                        modifier = Modifier.size(52.dp).clickable { onNavigateToPageList(uiState.documentId) },
                    ) {
                        uiState.lastThumbnail?.let { thumb ->
                            Image(
                                bitmap = thumb.asImageBitmap(),
                                contentDescription = "撮影済みページ",
                                modifier = Modifier.size(52.dp).clip(RoundedCornerShape(12.dp))
                                    .border(1.5.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(12.dp)),
                                contentScale = ContentScale.Crop,
                            )
                        }
                        Box(
                            modifier = Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp)
                                .height(20.dp).clip(RoundedCornerShape(10.dp))
                                .background(MaterialTheme.colorScheme.primary).padding(horizontal = 6.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text("${uiState.capturedPageCount}", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }

                // Center: capture button
                Box(
                    modifier = Modifier
                        .size(72.dp)
                        .clip(CircleShape)
                        .border(4.dp, Color.White, CircleShape)
                        .padding(6.dp)
                        .clip(CircleShape)
                        .background(Color.White)
                        .clickable(enabled = !uiState.isCapturing && cameraPermissionGranted) {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            imageCapture.takePicture(
                                cameraExecutor,
                                object : ImageCapture.OnImageCapturedCallback() {
                                    override fun onCaptureSuccess(image: ImageProxy) {
                                        var bitmap = imageProcessor.toBitmapWithCorrectRotation(image)
                                        image.close()
                                        // Re-detect paper in the captured image and apply perspective correction
                                        val corners = paperDetector.value.detect(bitmap)
                                        if (corners != null && corners.size == 4) {
                                            val corrected = paperDetector.value.correctPerspective(bitmap, corners)
                                            bitmap.recycle()
                                            bitmap = corrected
                                        }
                                        viewModel.onCaptureImage(bitmap)
                                    }
                                    override fun onError(exception: ImageCaptureException) {
                                        Log.e("CameraScan", "Capture failed", exception)
                                    }
                                },
                            )
                        },
                )

                Spacer(Modifier.width(52.dp))
            }
        }
    }
}
