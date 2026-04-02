package io.github.yusukeiwaki.camscanshare.data.preview

data class AppliedPreviewPaths(
    val smallPreviewPath: String,
    val largePreviewPath: String,
)

fun persistAppliedPreviewPaths(
    oldSmallPreviewPath: String?,
    oldLargePreviewPath: String?,
    deleteSmall: (String) -> Unit,
    deleteLarge: (String) -> Unit,
    saveSmall: () -> String,
    saveLarge: () -> String,
): AppliedPreviewPaths {
    oldSmallPreviewPath?.let(deleteSmall)
    oldLargePreviewPath?.let(deleteLarge)

    return AppliedPreviewPaths(
        smallPreviewPath = saveSmall(),
        largePreviewPath = saveLarge(),
    )
}
