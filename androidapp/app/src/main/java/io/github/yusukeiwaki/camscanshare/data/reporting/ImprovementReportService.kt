package io.github.yusukeiwaki.camscanshare.data.reporting

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import io.github.yusukeiwaki.camscanshare.data.file.ImageFileStorage
import io.github.yusukeiwaki.camscanshare.data.file.PreviewFileStorage
import io.github.yusukeiwaki.camscanshare.data.preview.WorkingPreviewManager
import io.github.yusukeiwaki.camscanshare.ui.pageedit.ImageFilter
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
)

@Singleton
class ImprovementReportService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val workingPreviewManager: WorkingPreviewManager,
    private val previewFileStorage: PreviewFileStorage,
    private val imageFileStorage: ImageFileStorage,
) {
    suspend fun ensurePreview(
        pageId: Long,
        sourceRelativePath: String,
        filterKey: String,
        rotationDegrees: Int,
    ): String? = withContext(Dispatchers.IO) {
        val bitmap = workingPreviewManager.getOrCompute(
            pageId = pageId,
            sourceRelativePath = sourceRelativePath,
            filterKey = filterKey,
            rotationDegrees = rotationDegrees,
        ) ?: return@withContext null

        try {
            val absolutePath = previewFileStorage.getWorkingAbsolutePath(pageId, filterKey, rotationDegrees)
            if (File(absolutePath).exists()) absolutePath else null
        } finally {
            bitmap.recycle()
        }
    }

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
        previewPaths: Map<String, String>,
        attachments: List<ImprovementReportAttachment>,
    ): File = withContext(Dispatchers.IO) {
        val outputDir = File(context.cacheDir, "improvement-reports").also { it.mkdirs() }
        val archiveFile = File(outputDir, "report-${System.currentTimeMillis()}-$pageId.zip")

        ZipOutputStream(archiveFile.outputStream().buffered()).use { zipOutput ->
            val originalPath = previewPaths[ImageFilter.ORIGINAL.filterKey]
            if (originalPath != null) {
                addFileToZip(zipOutput, File(originalPath), "original.jpg")
            }

            ImageFilter.entries
                .filter { it != ImageFilter.ORIGINAL }
                .forEach { filter ->
                    val absolutePath = previewPaths[filter.filterKey] ?: return@forEach
                    addFileToZip(zipOutput, File(absolutePath), "filter-${filter.filterKey}.jpg")
                }

            // Keep the current source image path visible for debugging if needed.
            val sourceAbsolutePath = imageFileStorage.getAbsolutePath(sourceRelativePath)
            val sourceFile = File(sourceAbsolutePath)
            if (sourceFile.exists()) {
                addFileToZip(zipOutput, sourceFile, "source.jpg")
            }

            attachments.forEachIndexed { index, attachment ->
                addUriToZip(
                    zipOutput = zipOutput,
                    uri = Uri.parse(attachment.uriString),
                    entryName = buildAttachmentEntryName(index, attachment.displayName),
                )
            }
        }

        archiveFile
    }

    fun resolveAttachment(uri: Uri): ImprovementReportAttachment? {
        val displayName = queryDisplayName(uri) ?: return null
        return ImprovementReportAttachment(
            uriString = uri.toString(),
            displayName = displayName,
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

    private fun addUriToZip(
        zipOutput: ZipOutputStream,
        uri: Uri,
        entryName: String,
    ) {
        val resolver = context.contentResolver
        resolver.openInputStream(uri)?.use { input ->
            zipOutput.putNextEntry(ZipEntry(entryName))
            input.copyTo(zipOutput)
            zipOutput.closeEntry()
        } ?: throw IOException("添付画像を開けませんでした: $uri")
    }

    private fun queryDisplayName(uri: Uri): String? {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                return cursor.getString(index)
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
    }

    private fun buildAttachmentEntryName(index: Int, displayName: String): String {
        val extension = displayName.substringAfterLast('.', "")
            .lowercase()
            .replace(Regex("[^a-z0-9]"), "")
            .ifBlank { "jpg" }
        return "extra-${index + 1}.$extension"
    }

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
