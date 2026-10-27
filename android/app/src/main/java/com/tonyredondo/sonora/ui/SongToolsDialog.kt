package com.tonyredondo.sonora

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.UUID
import kotlin.math.roundToInt

@Composable
fun SongToolsDialog(model: PlayerModel, song: Song, dismiss: () -> Unit) {
    val all by model.graph.songTools.collectAsStateWithLifecycle()
    val extras by model.graph.extras.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val loop by model.graph.loop.collectAsStateWithLifecycle()
    val tools = all[song.id] ?: SongTools()
    val loaded = all.containsKey(song.id)
    LaunchedEffect(song.id) { model.graph.loadSongTools(listOf(song.id)) }
    var name by remember(song.id) { mutableStateOf("") }
    var issue by remember(song.id) { mutableStateOf<String?>(null) }
    val current = playback.currentId == song.id
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("BPM y marcadores") },
        text = {
            val focus = LocalFocusManager.current
            val keyboard = LocalSoftwareKeyboardController.current
            fun finishTyping() {
                focus.clearFocus(force = true)
                keyboard?.hide()
            }
            Column(Modifier.fillMaxWidth()) {
                Text(song.title, style = MaterialTheme.typography.titleMedium)
                val bpm = extras[song.id]?.bpm?.roundToInt()
                Text(
                    bpm?.let { "$it BPM · estimación" }
                        ?: extras[song.id]?.progress?.get(PreparationStage.AUDIO)?.message?.takeIf {
                            it.isNotBlank()
                        }
                        ?: "No hay un pulso estimado disponible.",
                )
                Spacer(Modifier.height(12.dp))
                if (current) WaveformTimeline(model, playback, extras[song.id]?.waveform.orEmpty())
                if (!loaded) LinearProgressIndicator(Modifier.fillMaxWidth())
                OutlinedTextField(
                    name,
                    { if (it.toByteArray().size <= 200 && it.none(Char::isISOControl)) name = it },
                    label = { Text("Nombre del marcador") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { finishTyping() }),
                    enabled = loaded,
                    modifier = Modifier.fillMaxWidth(),
                )
                TextButton(
                    onClick = {
                        try {
                            val position = model.controller?.currentPosition ?: return@TextButton
                            model.graph.setSongTools(
                                song.id,
                                tools.copy(
                                    markers =
                                        (tools.markers +
                                                SongMarker(
                                                    UUID.randomUUID().toString(),
                                                    name.trim().ifBlank {
                                                        "Marcador ${tools.markers.size + 1}"
                                                    },
                                                    position,
                                                ))
                                            .sortedBy { it.positionMs },
                                ),
                            )
                            name = ""
                            issue = null
                            finishTyping()
                        } catch (error: Exception) {
                            issue = error.userMessage()
                        }
                    },
                    enabled = current && loaded,
                ) {
                    Text("Añadir en ${playbackTime(playback.positionMs)}")
                }
                issue?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 200.dp)) {
                    items(tools.markers, key = { it.id }) { marker ->
                        ListItem(
                            colors =
                                ListItemDefaults.colors(
                                    containerColor = androidx.compose.ui.graphics.Color.Transparent,
                                ),
                            headlineContent = { Text(marker.title) },
                            supportingContent = { Text(playbackTime(marker.positionMs)) },
                            trailingContent = {
                                IconButton(
                                    onClick = {
                                        model.graph.setSongTools(
                                            song.id,
                                            tools.copy(
                                                markers =
                                                    tools.markers.filterNot { it.id == marker.id },
                                            ),
                                        )
                                    },
                                ) {
                                    Icon(Icons.Rounded.DeleteOutline, "Eliminar ${marker.title}")
                                }
                            },
                            modifier =
                                Modifier.clickable(enabled = current) {
                                    model.seek(marker.positionMs)
                                },
                        )
                    }
                }
                if (loop?.songId == song.id)
                    TextButton(onClick = { model.graph.loop.value = null }) {
                        Text("Dejar de repetir fragmento")
                    }
            }
        },
        confirmButton = { TextButton(onClick = dismiss) { Text("Listo") } },
    )
}
