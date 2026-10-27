package com.tonyredondo.sonora

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun LyricsEditorDialog(model: PlayerModel, source: Song) {
    val text by model.lyricsEditorText.collectAsStateWithLifecycle()
    val busy by model.lyricsEditorBusy.collectAsStateWithLifecycle()
    val issue by model.lyricsEditorIssue.collectAsStateWithLifecycle()
    var discard by remember { mutableStateOf(false) }
    var aiMenu by remember { mutableStateOf(false) }
    var fieldBounds by remember { mutableStateOf(Rect.Zero) }
    var parentOrigin by remember { mutableStateOf(Offset.Zero) }
    fun leave() {
        if (!busy) {
            if (text != source.lyricsText) discard = true else model.closeLyricsEditor()
        }
    }
    Dialog(
        ::leave,
        properties =
            DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        // A Dialog owns a different focus root from the player window.
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        fun closeEditor() {
            focus.clearFocus(force = true)
            keyboard?.hide()
            leave()
        }
        BackHandler { closeEditor() }
        Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier.systemBarsPadding()
                    .imePadding()
                    .onGloballyPositioned { parentOrigin = it.boundsInRoot().topLeft }
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val press =
                                awaitFirstDown(
                                    requireUnconsumed = false,
                                    pass = PointerEventPass.Initial,
                                )
                            if (!fieldBounds.contains(press.position + parentOrigin)) {
                                focus.clearFocus(force = true)
                                keyboard?.hide()
                            }
                        }
                    },
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = ::closeEditor, enabled = !busy) { Text("Cancelar") }
                    Text(
                        "Editar letra",
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    TextButton(
                        onClick = {
                            focus.clearFocus()
                            keyboard?.hide()
                            model.saveLyricsEditor()
                        },
                        enabled = !busy,
                    ) {
                        Text("Guardar")
                    }
                }
                Text(
                    source.title,
                    Modifier.padding(horizontal = 20.dp),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                )
                if (source.artist.isNotBlank())
                    Text(
                        source.artist,
                        Modifier.padding(horizontal = 20.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                OutlinedTextField(
                    text,
                    model::setLyricsDraft,
                    Modifier.fillMaxWidth()
                        .weight(1f)
                        .padding(16.dp)
                        .testTag("lyricsTextInput")
                        .onGloballyPositioned { fieldBounds = it.boundsInRoot() },
                    enabled = !busy,
                    placeholder = { Text("Escribe o pega la letra completa") },
                    keyboardOptions =
                        KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Default),
                )
                issue?.let {
                    Text(
                        it,
                        Modifier.padding(horizontal = 20.dp),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                if (busy)
                    LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 20.dp))
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        IconButton(
                            onClick = {
                                focus.clearFocus()
                                keyboard?.hide()
                                aiMenu = true
                            },
                            enabled = !busy,
                        ) {
                            Icon(Icons.Rounded.AutoAwesome, "Herramientas de letras con IA")
                        }
                        DropdownMenu(aiMenu, { aiMenu = false }) {
                            LyricsAIMode.entries.forEach { mode ->
                                DropdownMenuItem(
                                    text = { Text(mode.label + " con IA") },
                                    onClick = {
                                        aiMenu = false
                                        model.lyricsAI.open(source, text, mode)
                                    },
                                    enabled = mode != LyricsAIMode.REPAIR || text.isNotBlank(),
                                )
                            }
                        }
                    }
                    TextButton(
                        onClick = {
                            focus.clearFocus()
                            keyboard?.hide()
                            model.openManualTiming(source, text)
                        },
                        enabled = !busy && text.isNotBlank(),
                    ) {
                        Icon(Icons.Rounded.GraphicEq, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Marcar tiempos")
                    }
                    Text(
                        "Los cambios se guardan en Sonora.",
                        Modifier.weight(1f).padding(start = 12.dp),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        if (discard)
            AlertDialog(
                onDismissRequest = { discard = false },
                title = { Text("¿Descartar los cambios?") },
                text = { Text("La letra guardada se conservará.") },
                confirmButton = {
                    TextButton(
                        onClick = {
                            discard = false
                            model.closeLyricsEditor()
                        },
                    ) {
                        Text("Descartar")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { discard = false }) { Text("Seguir editando") }
                },
            )
    }
}

@Composable
fun ManualTimingDialog(model: PlayerModel, source: Song) {
    val draft by model.timingDraft.collectAsStateWithLifecycle()
    val cursor by model.timingCursor.collectAsStateWithLifecycle()
    val issue by model.timingIssue.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val current = playback.currentId == source.id
    val lines = draft?.lines.orEmpty()
    val complete = lines.isNotEmpty() && lines.all { it.timeMs != null }
    val list = rememberLazyListState()
    LaunchedEffect(cursor) { if (cursor in lines.indices) list.animateScrollToItem(cursor) }
    Dialog(
        { model.timingSource.value = null },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.systemBarsPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = { model.timingSource.value = null }) { Text("Cancelar") }
                    Text(
                        "Marcar tiempos",
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    TextButton(onClick = model::applyManualTiming, enabled = complete) {
                        Text("Usar en el borrador")
                    }
                }
                Text(
                    source.title,
                    Modifier.padding(horizontal = 20.dp),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                )
                Text(
                    if (current) "Escucha la canción y marca cada frase cuando empieza."
                    else "Reproduce esta canción para poder marcar sus frases.",
                    Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodyMedium,
                )
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f).testTag("timingLines"),
                    contentPadding = PaddingValues(16.dp),
                    state = list,
                ) {
                    itemsIndexed(lines, key = { _, line -> line.id }) { index, line ->
                        ListItem(
                            headlineContent = { Text(line.text.ifBlank { "♪" }) },
                            supportingContent = {
                                Text(line.timeMs?.let(::lyricTimestamp) ?: "Sin marcar")
                            },
                            colors =
                                ListItemDefaults.colors(
                                    containerColor =
                                        if (index == cursor)
                                            MaterialTheme.colorScheme.primary.copy(alpha = .14f)
                                        else MaterialTheme.colorScheme.surface,
                                ),
                            modifier =
                                Modifier.fillMaxWidth().clickable {
                                    model.timingCursor.value = index
                                },
                        )
                    }
                }
                issue?.let {
                    Text(
                        it,
                        Modifier.padding(horizontal = 20.dp),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    IconButton(onClick = model::togglePlayback, enabled = current) {
                        Icon(
                            if (playback.showsPause) Icons.Rounded.Pause
                            else Icons.Rounded.PlayArrow,
                            "Reproducir o pausar",
                        )
                    }
                    Button(
                        onClick = model::stampPhrase,
                        enabled = current && lines.isNotEmpty(),
                        modifier = Modifier.weight(1f).testTag("stampPhrase"),
                    ) {
                        Text(
                            if (complete) "Volver a marcar frase"
                            else "Marcar frase ${cursor+1} de ${lines.size}",
                        )
                    }
                    TextButton(
                        onClick = {
                            model.timingDraft.value = draft?.clearTiming()
                            model.timingCursor.value = 0
                            model.timingIssue.value = null
                        },
                    ) {
                        Text("Reiniciar")
                    }
                }
            }
        }
    }
}
