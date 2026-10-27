package com.tonyredondo.sonora

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private object ArtworkBitmaps {
    private val cache =
        object : LruCache<String, Bitmap>(32 * 1024 * 1024) {
            override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
        }

    suspend fun read(path: String, pixels: Int): Bitmap? =
        withContext(Dispatchers.IO) {
            val file = File(path)
            val key = "$path:$pixels:${file.length()}:${file.lastModified()}"
            cache.get(key)?.let {
                return@withContext it
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (
                bounds.outWidth <= 0 ||
                    bounds.outHeight <= 0 ||
                    bounds.outWidth.toLong() * bounds.outHeight > 48_000_000
            )
                return@withContext null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > pixels) sample *= 2
            BitmapFactory.decodeFile(
                    path,
                    BitmapFactory.Options().apply {
                        inSampleSize = sample
                        inScaled = false
                    },
                )
                ?.also { cache.put(key, it) }
        }
}

@Composable
fun rememberArtwork(path: String?, pixels: Int = 1600): Bitmap? {
    val image by
        produceState<Bitmap?>(null, path, pixels) {
            value = path?.let { ArtworkBitmaps.read(it, pixels) }
        }
    return image
}

@Composable
fun SongArtwork(path: String?, modifier: Modifier = Modifier) {
    val bitmap = rememberArtwork(path, 320)
    Box(
        modifier.background(MaterialTheme.colorScheme.surfaceContainer),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null)
            Image(
                bitmap.asImageBitmap(),
                null,
                Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        else
            Icon(
                Icons.Rounded.GraphicEq,
                null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.fillMaxSize().padding(12.dp),
            )
    }
}

@Composable
fun CoverBackdrop(
    original: String?,
    panorama: String?,
    wide: Boolean,
    textPage: Boolean,
    modifier: Modifier = Modifier,
) {
    val square = rememberArtwork(original)
    val extended = rememberArtwork(panorama, 2048)
    val base = MaterialTheme.colorScheme.background
    Box(modifier.background(base)) {
        if (extended != null && wide)
            Image(
                extended.asImageBitmap(),
                null,
                Modifier.fillMaxSize(),
                alignment = Alignment.CenterStart,
                contentScale = ContentScale.Crop,
            )
        else if (square != null) {
            Image(
                square.asImageBitmap(),
                null,
                Modifier.fillMaxSize().blur(32.dp),
                contentScale = ContentScale.Crop,
                alpha = .65f,
            )
            Image(
                square.asImageBitmap(),
                null,
                Modifier.fillMaxHeight()
                    .then(if (wide) Modifier.aspectRatio(1f) else Modifier.fillMaxWidth()),
                contentScale = ContentScale.Fit,
            )
        } else
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(
                    Icons.Rounded.GraphicEq,
                    null,
                    tint = MaterialTheme.colorScheme.primary.copy(alpha = .28f),
                    modifier = Modifier.size(140.dp),
                )
            }
        if (textPage)
            Box(
                Modifier.fillMaxSize()
                    .background(
                        if (wide)
                            Brush.horizontalGradient(
                                listOf(base.copy(alpha = .08f), base.copy(alpha = .74f)),
                            )
                        else
                            Brush.verticalGradient(
                                listOf(base.copy(alpha = .64f), base.copy(alpha = .72f)),
                            ),
                    ),
            )
        Box(
            Modifier.fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        .84f to Color.Transparent,
                        1f to base,
                    ),
                ),
        )
    }
}
