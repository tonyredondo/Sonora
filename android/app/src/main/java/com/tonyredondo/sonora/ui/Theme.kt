package com.tonyredondo.sonora

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val SonoraAmber = Color(0xFFF5B869)
val SonoraBackground = Color(0xFF0E1011)

@Composable
fun SonoraTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme =
            darkColorScheme(
                primary = SonoraAmber,
                onPrimary = Color.Black,
                background = SonoraBackground,
                surface = SonoraBackground,
                surfaceContainerLowest = Color(0xFF080A0B),
                surfaceContainerLow = Color(0xFF17191A),
                surfaceContainer = Color(0xFF222324),
                surfaceContainerHigh = Color(0xFF2B2D2F),
                surfaceContainerHighest = Color(0xFF353739),
                surfaceVariant = Color(0xFF27292B),
                onSurfaceVariant = Color(0xFFA6A6AA),
                outlineVariant = Color(0xFF45474A),
                surfaceTint = Color.Transparent,
                primaryContainer = Color(0xFF573E23),
                onPrimaryContainer = Color(0xFFFFDDAE),
                secondaryContainer = Color(0xFF303234),
                onSecondaryContainer = Color.White,
                onBackground = Color.White,
                onSurface = Color.White,
                secondary = Color(0xFFA6A6AA),
            ),
        content = content,
    )
}
