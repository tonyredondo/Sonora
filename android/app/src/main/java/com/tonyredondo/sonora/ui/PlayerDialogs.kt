package com.tonyredondo.sonora

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun ExpandedPageDialog(
    model: PlayerModel,
    song: Song?,
    extras: SongExtras,
    page: PlayerPage,
    dismiss: () -> Unit,
) {
    var offset by remember { mutableStateOf(false) }
    var understanding by remember { mutableStateOf(false) }
    val follow by model.followLyrics.collectAsStateWithLifecycle()
    val loop by model.graph.loop.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val tools by model.graph.songTools.collectAsStateWithLifecycle()
    Dialog(dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            if (page == PlayerPage.ARTWORK) {
                Box {
                    CoverBackdrop(
                        song?.displayArtworkPath() ?: extras.generatedArtwork,
                        extras.panorama,
                        true,
                        false,
                        Modifier.fillMaxSize(),
                    )
                    TextButton(onClick = dismiss, Modifier.statusBarsPadding().padding(16.dp)) {
                        Text("Listo")
                    }
                }
            } else
                Column(Modifier.systemBarsPadding()) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TextButton(onClick = dismiss) { Text("Listo") }
                        Text(
                            if (page in listOf(PlayerPage.LYRICS, PlayerPage.TRANSLATION)) "Letra"
                            else page.label(),
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        if (song != null)
                            IconButton(onClick = { understanding = true }) {
                                Icon(Icons.Rounded.AutoStories, "Comprender letra")
                            }
                    }
                    if (song != null && page in listOf(PlayerPage.LYRICS, PlayerPage.TRANSLATION)) {
                        Text(
                            song.title,
                            Modifier.padding(horizontal = 20.dp),
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 2,
                        )
                        if (song.artist.isNotBlank())
                            Text(
                                song.artist,
                                Modifier.padding(horizontal = 20.dp),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                        ) {
                            LyricTool(Icons.Rounded.Edit, "Editar", "Editar letra") {
                                model.editLyrics(song)
                            }
                            LyricTool(
                                Icons.Rounded.GraphicEq,
                                "Sincronizar",
                                "Marcar tiempos de la letra",
                            ) {
                                model.openManualTiming(song)
                            }
                            LyricTool(
                                Icons.Rounded.VerticalAlignCenter,
                                "Seguir",
                                "Seguir canción",
                                follow,
                            ) {
                                if (follow) model.followLyrics.value = false
                                else model.resumeLyrics()
                            }
                            LyricTool(
                                Icons.Rounded.RepeatOne,
                                "Frase",
                                "Repetir frase",
                                loop?.songId == song.id,
                            ) {
                                if (loop?.songId == song.id) model.graph.loop.value = null
                                else {
                                    val doc = LyricsDocument.parse(song.lyricsText)
                                    val index =
                                        doc.activeLine(
                                            playback.positionMs,
                                            tools[song.id]?.offsetMs ?: 0,
                                        ) ?: 0
                                    model.repeatPhrase(song, index)
                                }
                            }
                            LyricTool(Icons.Rounded.AccessTime, "Tiempos", "Ajustar tiempos") {
                                offset = true
                            }
                        }
                    }
                    PlayerPageContent(
                        model,
                        song,
                        extras,
                        page,
                        true,
                        Modifier.fillMaxWidth().weight(1f),
                        expanded = true,
                    )
                }
        }
    }
    if (offset && song != null) LyricsOffsetDialog(model, song) { offset = false }
    if (understanding && song != null)
        LyricUnderstandingDialog(model, song) { understanding = false }
}

@Composable
private fun LyricTool(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    description: String,
    active: Boolean = false,
    action: () -> Unit,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        FilledTonalIconButton(
            onClick = action,
            Modifier.size(48.dp),
            colors =
                IconButtonDefaults.filledTonalIconButtonColors(
                    containerColor =
                        if (active) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceContainer,
                    contentColor =
                        if (active) MaterialTheme.colorScheme.onPrimary
                        else MaterialTheme.colorScheme.primary,
                ),
        ) {
            Icon(icon, description)
        }
        Text(label, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun LyricsOffsetDialog(model: PlayerModel, song: Song, dismiss: () -> Unit) {
    val all by model.graph.songTools.collectAsStateWithLifecycle()
    val loaded = all.containsKey(song.id)
    LaunchedEffect(song.id) { model.graph.loadSongTools(listOf(song.id)) }
    val source = all[song.id] ?: SongTools()
    var value by remember(song.id, loaded) { mutableFloatStateOf(source.offsetMs / 1000f) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Ajustar tiempos") },
        text = {
            Column {
                Text(
                    "Desplazamiento · ${String.format(java.util.Locale.getDefault(),"%+.1f",value)} s",
                )
                if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
                Slider(
                    value,
                    { value = (it * 10).roundToInt() / 10f },
                    valueRange = -5f..5f,
                    enabled = loaded,
                )
                Text(
                    "Un valor positivo retrasa la letra.",
                    style = MaterialTheme.typography.bodySmall,
                )
                TextButton(onClick = { value = 0f }) { Text("Restablecer") }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    model.graph.setSongTools(
                        song.id,
                        source.copy(offsetMs = (value * 1000).toLong()),
                    )
                    dismiss()
                },
                enabled = loaded,
            ) {
                Text("Guardar")
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancelar") } },
    )
}

@Composable
private fun LyricUnderstandingDialog(model: PlayerModel, song: Song, dismiss: () -> Unit) {
    val all by model.graph.extras.collectAsStateWithLifecycle()
    var page by remember { mutableStateOf(PlayerPage.MEANING) }
    Dialog(dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.systemBarsPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = dismiss) { Text("Listo") }
                    Text("Comprender letra", style = MaterialTheme.typography.titleMedium)
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    FilterChip(
                        page == PlayerPage.MEANING,
                        { page = PlayerPage.MEANING },
                        { Text("Significado") },
                    )
                    FilterChip(
                        page == PlayerPage.TRANSLATION,
                        { page = PlayerPage.TRANSLATION },
                        { Text("Traducción") },
                    )
                }
                PlayerPageContent(
                    model,
                    song,
                    all[song.id] ?: SongExtras(),
                    page,
                    true,
                    Modifier.fillMaxWidth().weight(1f),
                    expanded = true,
                )
            }
        }
    }
}

@Composable
fun QueueDialog(model: PlayerModel, dismiss: () -> Unit) {
    val state by model.playback.collectAsStateWithLifecycle()
    val songs by
        produceState<List<Song?>>(emptyList(), state.queue) {
            value = withContext(Dispatchers.IO) { state.queue.map(model.graph.store::song) }
        }
    Dialog(dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.systemBarsPadding()) {
                Row(Modifier.fillMaxWidth().padding(20.dp)) {
                    Text(
                        "Cola",
                        style = MaterialTheme.typography.headlineMedium,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = dismiss) { Icon(Icons.Rounded.Close, "Listo") }
                }
                LazyColumn {
                    itemsIndexed(songs, key = { index, song -> "$index:${song?.id}" }) { index, song
                        ->
                        ListItem(
                            headlineContent = {
                                Text(
                                    song?.title ?: "Archivo no disponible",
                                    color =
                                        if (index == state.currentIndex)
                                            MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurface,
                                )
                            },
                            supportingContent = { Text(song?.artist.orEmpty()) },
                            modifier =
                                Modifier.clickable {
                                    model.controller?.seekToDefaultPosition(index)
                                    dismiss()
                                },
                        )
                    }
                }
            }
        }
    }
}
