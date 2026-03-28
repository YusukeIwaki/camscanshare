package io.github.yusukeiwaki.camscanshare.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import io.github.yusukeiwaki.camscanshare.ui.camerascan.CameraScanScreen
import io.github.yusukeiwaki.camscanshare.ui.documentlist.DocumentListScreen
import io.github.yusukeiwaki.camscanshare.ui.pageedit.PageEditScreen
import io.github.yusukeiwaki.camscanshare.ui.pagelist.PageListScreen
import kotlinx.serialization.Serializable

// Type-safe navigation routes
@Serializable
object DocumentList

@Serializable
data class CameraScan(val documentId: Long = 0L, val retakePageId: Long = 0L)

@Serializable
data class PageList(val documentId: Long)

@Serializable
data class PageEdit(val documentId: Long, val initialPageIndex: Int = 0)

@Composable
fun AppNavigation() {
    val navController = rememberNavController()

    NavHost(navController = navController, startDestination = DocumentList) {
        composable<DocumentList> {
            DocumentListScreen(
                onDocumentClick = { documentId ->
                    navController.navigate(PageList(documentId))
                },
                onNewScanClick = {
                    navController.navigate(CameraScan())
                },
            )
        }

        composable<CameraScan> { backStackEntry ->
            val route = backStackEntry.toRoute<CameraScan>()
            CameraScanScreen(
                documentId = route.documentId,
                retakePageId = route.retakePageId,
                onClose = { navController.popBackStack() },
                onNavigateToPageList = { documentId ->
                    navController.navigate(PageList(documentId)) {
                        popUpTo(DocumentList)
                    }
                },
            )
        }

        composable<PageList> { backStackEntry ->
            val route = backStackEntry.toRoute<PageList>()
            PageListScreen(
                documentId = route.documentId,
                onBack = { navController.popBackStack() },
                onPageClick = { pageIndex ->
                    navController.navigate(PageEdit(route.documentId, pageIndex))
                },
                onAddPageClick = {
                    navController.navigate(CameraScan(route.documentId))
                },
            )
        }

        composable<PageEdit> { backStackEntry ->
            val route = backStackEntry.toRoute<PageEdit>()
            PageEditScreen(
                documentId = route.documentId,
                initialPageIndex = route.initialPageIndex,
                onBack = { navController.popBackStack() },
                onRetake = { pageId ->
                    navController.navigate(CameraScan(route.documentId, retakePageId = pageId))
                },
            )
        }
    }
}
