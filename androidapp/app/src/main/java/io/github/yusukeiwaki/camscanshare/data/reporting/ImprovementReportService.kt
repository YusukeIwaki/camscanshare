package io.github.yusukeiwaki.camscanshare.data.reporting

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessingDebugSink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.inject.Inject
import javax.inject.Singleton

data class ImprovementReportServerConfig(
    val reportUrl: String,
    val token: String,
)

data class ImprovementReportMetadata(
    val appVersion: String,
    val buildNumber: String,
    val timestampJst: String,
    val pageId: Long,
    val currentFilter: String,
    val comment: String,
)

data class ImprovementReportAttachment(
    val uriString: String,
    val displayName: String,
    val mimeType: String?,
)

@Singleton
class ImprovementReportService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val imageFileStorage: ImageFileStorage,
    private val debugSink: ImageProcessingDebugSink,
) {
    fun buildTimestampJst(now: ZonedDateTime = ZonedDateTime.now(ZoneId.of("Asia/Tokyo"))): String =
        now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss 'JST'"))

    fun getAppVersionLabel(): Pair<String, String> {
        val packageManager = context.packageManager
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(context.packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(context.packageName, 0)
        }
        val versionName = packageInfo.versionName ?: "unknown"
        val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toString()
        }
        return versionName to buildNumber
    }

    suspend fun createArchive(
        pageId: Long,
        sourceRelativePath: String,
        attachments: List<ImprovementReportAttachment>,
        debugCaptureId: String?,
    ): File = withContext(Dispatchers.IO) {
        val outputDir = File(context.cacheDir, "improvement-reports").also { it.mkdirs() }
        val archiveFile = File(outputDir, "report-${System.currentTimeMillis()}-$pageId.zip")

        ZipOutputStream(archiveFile.outputStream().buffered()).use { zipOutput ->
            val sourceAbsolutePath = imageFileStorage.getAbsolutePath(sourceRelativePath)
            val sourceFile = File(sourceAbsolutePath)
            if (sourceFile.exists()) {
                addFileToZip(zipOutput, sourceFile, "source.jpg")
            }

            attachments.forEachIndexed { index, attachment ->
                addAttachmentToZip(zipOutput, attachment, index + 1)
            }

            addDebugArtifactsToZip(zipOutput, debugCaptureId)
        }

        archiveFile
    }

    fun resolveAttachment(uri: Uri): ImprovementReportAttachment {
        val displayName = queryDisplayName(uri)
            ?: uri.lastPathSegment
            ?: "attachment"
        return ImprovementReportAttachment(
            uriString = uri.toString(),
            displayName = displayName,
            mimeType = context.contentResolver.getType(uri),
        )
    }

    suspend fun uploadReport(
        config: ImprovementReportServerConfig,
        metadata: ImprovementReportMetadata,
        archiveFile: File,
    ) = withContext(Dispatchers.IO) {
        val boundary = "----CamScanShare${System.currentTimeMillis()}"
        val connection = (URL(config.reportUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            doInput = true
            connectTimeout = 15000
            readTimeout = 60000
            setRequestProperty("Authorization", "Bearer ${config.token}")
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            setChunkedStreamingMode(64 * 1024)
        }

        try {
            DataOutputStream(connection.outputStream).use { output ->
                writeTextPart(output, boundary, "comment", metadata.comment)
                writeTextPart(output, boundary, "appVersion", metadata.appVersion)
                writeTextPart(output, boundary, "buildNumber", metadata.buildNumber)
                writeTextPart(output, boundary, "timestampJst", metadata.timestampJst)
                writeTextPart(output, boundary, "pageId", metadata.pageId.toString())
                writeTextPart(output, boundary, "currentFilter", metadata.currentFilter)
                writeFilePart(output, boundary, "archive", archiveFile, "application/zip")
                output.writeBytes("--$boundary--\r\n")
                output.flush()
            }

            val responseCode = connection.responseCode
            if (responseCode !in 200..299) {
                val errorBody = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw IOException("改善レポート送信に失敗しました (HTTP $responseCode) $errorBody")
            }
        } finally {
            connection.disconnect()
        }
    }

    fun parseScannerPayload(rawValue: String): ImprovementReportServerConfig {
        val uri = android.net.Uri.parse(rawValue)
        if (uri.scheme != "camscanshare" || uri.host != "bug-report-config") {
            throw IllegalArgumentException("QRコードの形式が正しくありません。")
        }

        val reportUrl = uri.getQueryParameter("u")?.trim().orEmpty()
        val token = uri.getQueryParameter("t")?.trim().orEmpty()
        if (reportUrl.isBlank() || token.isBlank()) {
            throw IllegalArgumentException("送信先 URL またはアクセストークンが不足しています。")
        }

        val parsedUrl = URL(reportUrl)
        if (parsedUrl.protocol != "https" && parsedUrl.protocol != "http") {
            throw IllegalArgumentException("送信先 URL の形式が正しくありません。")
        }
        return ImprovementReportServerConfig(reportUrl = reportUrl, token = token)
    }

    private fun addFileToZip(zipOutput: ZipOutputStream, file: File, entryName: String) {
        if (!file.exists()) {
            Log.w("ImprovementReport", "Skipped missing file: ${file.absolutePath}")
            return
        }

        zipOutput.putNextEntry(ZipEntry(entryName))
        BufferedInputStream(FileInputStream(file)).use { input ->
            input.copyTo(zipOutput)
        }
        zipOutput.closeEntry()
    }

    private fun addAttachmentToZip(
        zipOutput: ZipOutputStream,
        attachment: ImprovementReportAttachment,
        index: Int,
    ) {
        val uri = Uri.parse(attachment.uriString)
        val entryName = "attachments/${index.toString().padStart(2, '0')}-${sanitizeZipPathSegment(attachment.displayName)}"
        val input = context.contentResolver.openInputStream(uri)
        if (input == null) {
            Log.w("ImprovementReport", "Skipped unreadable attachment: ${attachment.uriString}")
            return
        }

        zipOutput.putNextEntry(ZipEntry(entryName))
        input.use { it.copyTo(zipOutput) }
        zipOutput.closeEntry()
    }

    private fun queryDisplayName(uri: Uri): String? {
        return context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            }
            ?.takeIf { it.isNotBlank() }
    }

    private fun addDebugArtifactsToZip(zipOutput: ZipOutputStream, debugCaptureId: String?) {
        val root = debugSink.debugRootDirectory ?: return
        val sessions = debugCaptureId
            ?.takeIf { it.isNotBlank() }
            ?.let { debugSink.sessionDirectoriesForCapture(it) }
            .orEmpty()
        val reportMetadata = buildString {
            appendLine("debugRoot: ${root.absolutePath}")
            appendLine("debugCaptureId: ${debugCaptureId ?: "-"}")
            appendLine("includedSessionCount: ${sessions.size}")
            sessions.forEach { appendLine("session: ${it.name}") }
        }
        zipOutput.putNextEntry(ZipEntry("debug/manifest.txt"))
        zipOutput.write(reportMetadata.toByteArray(Charsets.UTF_8))
        zipOutput.closeEntry()

        sessions.forEach { sessionDir ->
            sessionDir.walkTopDown()
                .filter { it.isFile }
                .forEach { file ->
                    val relativePath = file.relativeTo(sessionDir).invariantSeparatorsPath
                    val entryName = "debug/${sanitizeZipPathSegment(sessionDir.name)}/$relativePath"
                    addFileToZip(zipOutput, file, entryName)
                }
        }
    }

    private fun sanitizeZipPathSegment(value: String): String =
        value.replace(Regex("[^A-Za-z0-9._-]"), "_").ifBlank { "session" }

    private fun writeTextPart(
        output: DataOutputStream,
        boundary: String,
        fieldName: String,
        value: String,
    ) {
        output.writeBytes("--$boundary\r\n")
        output.writeBytes("Content-Disposition: form-data; name=\"$fieldName\"\r\n\r\n")
        output.write(value.toByteArray(Charsets.UTF_8))
        output.writeBytes("\r\n")
    }

    private fun writeFilePart(
        output: DataOutputStream,
        boundary: String,
        fieldName: String,
        file: File,
        mimeType: String,
    ) {
        output.writeBytes("--$boundary\r\n")
        output.writeBytes("Content-Disposition: form-data; name=\"$fieldName\"; filename=\"${file.name}\"\r\n")
        output.writeBytes("Content-Type: $mimeType\r\n\r\n")
        file.inputStream().use { input ->
            input.copyTo(output)
        }
        output.writeBytes("\r\n")
    }
}
