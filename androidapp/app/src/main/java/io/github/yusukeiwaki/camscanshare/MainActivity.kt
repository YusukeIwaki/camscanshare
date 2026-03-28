package io.github.yusukeiwaki.camscanshare

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dagger.hilt.android.AndroidEntryPoint
import io.github.yusukeiwaki.camscanshare.ui.navigation.AppNavigation
import io.github.yusukeiwaki.camscanshare.ui.theme.CamScanShareTheme

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            CamScanShareTheme {
                AppNavigation()
            }
        }
    }
}
