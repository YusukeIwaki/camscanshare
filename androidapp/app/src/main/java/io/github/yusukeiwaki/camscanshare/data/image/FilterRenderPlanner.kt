package io.github.yusukeiwaki.camscanshare.data.image

data class FilterRenderPlan(
    val selectedFilterKey: String,
    val bitmapFilterKey: String? = null,
    val colorMatrixFilterKey: String? = null,
)

object FilterRenderPlanner {
    fun planPreview(
        selectedFilterKey: String,
        showOriginal: Boolean = false,
    ): FilterRenderPlan {
        if (showOriginal) {
            return FilterRenderPlan(selectedFilterKey = selectedFilterKey)
        }

        return when (selectedFilterKey) {
            "magic" -> FilterRenderPlan(
                selectedFilterKey = selectedFilterKey,
                bitmapFilterKey = "magic",
            )
            "original" -> FilterRenderPlan(selectedFilterKey = selectedFilterKey)
            else -> FilterRenderPlan(
                selectedFilterKey = selectedFilterKey,
                colorMatrixFilterKey = selectedFilterKey,
            )
        }
    }

    fun planPersistedFilter(selectedFilterKey: String): String = selectedFilterKey
}
