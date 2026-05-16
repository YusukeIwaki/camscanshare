package io.github.yusukeiwaki.camscanshare.data.image

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

enum class DebugMatColor {
    GRAY,
    RGB,
    BGR,
    RGBA,
}

class ImageProcessingDebugSession internal constructor(
    internal val directory: File?,
    val category: String,
    val label: String,
) {
    private val imageIndex = AtomicInteger(0)
    private val timingLock = Any()

    val isEnabled: Boolean
        get() = directory != null

    internal fun nextImageFileName(label: String): String =
        "%02d_%s.png".format(Locale.US, imageIndex.incrementAndGet(), sanitize(label))

    internal fun appendTiming(line: String) {
        val dir = directory ?: return
        synchronized(timingLock) {
            File(dir, "timings.jsonl").appendText(line + "\n")
        }
    }

    private fun sanitize(value: String): String =
        value.replace(Regex("[^A-Za-z0-9._-]+"), "_").trim('_').ifBlank { "artifact" }
}

@Singleton
class ImageProcessingDebugSink private constructor(
    private val rootDirectory: File?,
    private val isWritingEnabled: Boolean,
    private val debugCaptureId: String? = null,
) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        rootDirectory = resolveRootDirectory(context),
        isWritingEnabled = false,
    )

    val debugRootDirectory: File?
        get() = rootDirectory

    fun startSession(
        category: String,
        label: String,
        metadata: Map<String, String> = emptyMap(),
    ): ImageProcessingDebugSession {
        val root = rootDirectory
        if (!isWritingEnabled || root == null) {
            return ImageProcessingDebugSession(null, category, label)
        }
        val timestamp = timestampFormat.format(Date())
        val safeCategory = sanitize(category)
        val safeLabel = sanitize(label)
        val safeCaptureId = debugCaptureId?.let(::sanitize)
        val dirName = listOfNotNull(timestamp, safeCaptureId, safeCategory, safeLabel).joinToString("_")
        val dir = File(root, dirName)
        return try {
            dir.mkdirs()
            val session = ImageProcessingDebugSession(dir, category, label)
            val captureMetadata = debugCaptureId?.let { mapOf("debugCaptureId" to it) }.orEmpty()
            writeText(
                session,
                "metadata.json",
                jsonObject(
                    mapOf(
                        "category" to category,
                        "label" to label,
                        "createdAt" to timestamp,
                        "path" to dir.absolutePath,
                    ) + captureMetadata + metadata,
                ),
            )
            Log.d(TAG, "Debug session: ${dir.absolutePath}")
            session
        } catch (e: Exception) {
            Log.w(TAG, "Failed to create debug session", e)
            ImageProcessingDebugSession(null, category, label)
        }
    }

    fun writeBitmap(session: ImageProcessingDebugSession?, label: String, bitmap: Bitmap?) {
        val dir = session?.directory ?: return
        if (bitmap == null || bitmap.isRecycled) return

        val file = File(dir, session.nextImageFileName(label))
        try {
            file.outputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write bitmap artifact '$label'", e)
        }
    }

    fun writeMat(
        session: ImageProcessingDebugSession?,
        label: String,
        mat: Mat?,
        color: DebugMatColor = DebugMatColor.GRAY,
    ) {
        val dir = session?.directory ?: return
        if (mat == null || mat.empty()) return

        val rgba = Mat()
        val normalized = normalizeTo8Bit(mat)
        try {
            when (color) {
                DebugMatColor.GRAY -> Imgproc.cvtColor(normalized, rgba, Imgproc.COLOR_GRAY2RGBA)
                DebugMatColor.RGB -> Imgproc.cvtColor(normalized, rgba, Imgproc.COLOR_RGB2RGBA)
                DebugMatColor.BGR -> Imgproc.cvtColor(normalized, rgba, Imgproc.COLOR_BGR2RGBA)
                DebugMatColor.RGBA -> normalized.copyTo(rgba)
            }
            val bitmap = Bitmap.createBitmap(rgba.width(), rgba.height(), Bitmap.Config.ARGB_8888)
            Utils.matToBitmap(rgba, bitmap)
            val file = File(dir, session.nextImageFileName(label))
            file.outputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            }
            bitmap.recycle()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write Mat artifact '$label'", e)
        } finally {
            rgba.release()
            normalized.release()
        }
    }

    fun writeText(session: ImageProcessingDebugSession?, fileName: String, text: String) {
        val dir = session?.directory ?: return
        try {
            File(dir, fileName).writeText(text)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write debug text '$fileName'", e)
        }
    }

    fun recordTiming(
        session: ImageProcessingDebugSession?,
        stage: String,
        durationMs: Double,
        metadata: Map<String, String> = emptyMap(),
    ) {
        if (session?.isEnabled != true) return
        val entry = mapOf(
            "stage" to stage,
            "durationMs" to "%.3f".format(Locale.US, durationMs),
        ) + metadata
        Log.d(TAG, "${session?.category ?: "image"}:${session?.label ?: "-"} $stage ${entry["durationMs"]}ms")
        session?.appendTiming(jsonObject(entry))
    }

    fun recordTimingSince(
        session: ImageProcessingDebugSession?,
        stage: String,
        startElapsedRealtimeNanos: Long,
        metadata: Map<String, String> = emptyMap(),
    ) {
        val durationMs = (SystemClock.elapsedRealtimeNanos() - startElapsedRealtimeNanos).toDouble() / 1_000_000.0
        recordTiming(session, stage, durationMs, metadata)
    }

    fun recentSessionDirectories(limit: Int = 40): List<File> {
        val root = rootDirectory ?: return emptyList()
        return root.listFiles()
            .orEmpty()
            .filter { it.isDirectory }
            .sortedByDescending { it.lastModified() }
            .take(limit)
    }

    fun sessionDirectoriesForCapture(debugCaptureId: String, limit: Int = 12): List<File> {
        val expected = "\"debugCaptureId\":\"${escapeJson(debugCaptureId)}\""
        return recentSessionDirectories(limit = 200)
            .filter { sessionDir ->
                val metadataFile = File(sessionDir, "metadata.json")
                metadataFile.exists() && runCatching {
                    metadataFile.readText().contains(expected)
                }.getOrDefault(false)
            }
            .sortedBy { it.lastModified() }
            .take(limit)
    }

    private fun normalizeTo8Bit(mat: Mat): Mat {
        val source = Mat()
        if (mat.channels() == 1) {
            mat.copyTo(source)
        } else if (mat.channels() == 3 || mat.channels() == 4) {
            mat.copyTo(source)
        } else {
            Core.extractChannel(mat, source, 0)
        }

        if (source.depth() == CvType.CV_8U) {
            return source
        }

        val normalized = Mat()
        Core.normalize(source, normalized, 0.0, 255.0, Core.NORM_MINMAX)
        source.release()
        val result = Mat()
        normalized.convertTo(result, CvType.CV_8U)
        normalized.release()
        return result
    }

    private fun jsonObject(values: Map<String, String>): String =
        values.entries.joinToString(prefix = "{", postfix = "}") { (key, value) ->
            "\"${escapeJson(key)}\":\"${escapeJson(value)}\""
        }

    private fun escapeJson(value: String): String =
        buildString {
            value.forEach { char ->
                when (char) {
                    '\\' -> append("\\\\")
                    '"' -> append("\\\"")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> append(char)
                }
            }
        }

    private fun sanitize(value: String): String =
        value.replace(Regex("[^A-Za-z0-9._-]+"), "_").trim('_').ifBlank { "session" }

    companion object {
        private const val TAG = "ImageProcessingDebug"
        private val timestampFormat = SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.US)

        fun noOp(): ImageProcessingDebugSink =
            ImageProcessingDebugSink(rootDirectory = null, isWritingEnabled = false)

        fun newCaptureId(): String =
            "capture-${timestampFormat.format(Date())}-${UUID.randomUUID()}"

        fun fromContext(
            context: Context,
            isWritingEnabled: Boolean = true,
            debugCaptureId: String? = null,
        ): ImageProcessingDebugSink =
            ImageProcessingDebugSink(
                rootDirectory = resolveRootDirectory(context.applicationContext),
                isWritingEnabled = isWritingEnabled,
                debugCaptureId = debugCaptureId,
            )

        private fun resolveRootDirectory(context: Context): File {
            val baseDir = context.getExternalFilesDir(null) ?: context.filesDir
            return File(baseDir, "image-processing-debug").apply { mkdirs() }
        }
    }
}
