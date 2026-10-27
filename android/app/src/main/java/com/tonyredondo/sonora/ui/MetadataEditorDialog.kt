package com.tonyredondo.sonora

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

@Composable
fun MetadataEditorDialog(song: Song, graph: AppGraph, dismiss: () -> Unit) {
    var title by rememberSaveable(song.id) { mutableStateOf(song.title) }
    var artist by rememberSaveable(song.id) { mutableStateOf(song.artist) }
    var album by rememberSaveable(song.id) { mutableStateOf(song.album) }
    var genre by rememberSaveable(song.id) { mutableStateOf(song.genre) }
    var track by
        rememberSaveable(song.id) {
            mutableStateOf(song.trackNumber.takeIf { it > 0 }?.toString().orEmpty())
        }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun draft() =
        MetadataDraft(
            title,
            artist,
            album,
            genre,
            if (track.isBlank()) 0 else track.toIntOrNull() ?: -1,
        )
    fun close() {
        if (draft() != MetadataDraft.from(song)) discard = true else dismiss()
    }
    AlertDialog(
        onDismissRequest = { if (!saving) close() },
        title = { Text("Información del archivo") },
        text = {
            val focus = LocalFocusManager.current
            val keyboard = LocalSoftwareKeyboardController.current
            val fields = remember { mutableMapOf<String, Rect>() }
            var origin by remember { mutableStateOf(Offset.Zero) }
            fun field(key: String) =
                Modifier.fillMaxWidth().onGloballyPositioned { fields[key] = it.boundsInRoot() }
            Column(
                Modifier.onGloballyPositioned { origin = it.boundsInRoot().topLeft }
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val down =
                                awaitFirstDown(
                                    requireUnconsumed = false,
                                    pass = PointerEventPass.Initial,
                                )
                            if (fields.values.none { it.contains(down.position + origin) }) {
                                focus.clearFocus()
                                keyboard?.hide()
                            }
                        }
                    }
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "Los cambios se guardan en Sonora y se incluyen al exportar. El archivo de origen se conserva.",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    title,
                    { title = it },
                    field("title"),
                    label = { Text("Título") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions =
                        KeyboardActions(
                            onDone = {
                                focus.clearFocus()
                                keyboard?.hide()
                            },
                        ),
                    enabled = !saving,
                )
                OutlinedTextField(
                    artist,
                    { artist = it },
                    field("artist"),
                    label = { Text("Artista") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions =
                        KeyboardActions(
                            onDone = {
                                focus.clearFocus()
                                keyboard?.hide()
                            },
                        ),
                    enabled = !saving,
                )
                OutlinedTextField(
                    album,
                    { album = it },
                    field("album"),
                    label = { Text("Álbum") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions =
                        KeyboardActions(
                            onDone = {
                                focus.clearFocus()
                                keyboard?.hide()
                            },
                        ),
                    enabled = !saving,
                )
                OutlinedTextField(
                    genre,
                    { genre = it },
                    field("genre"),
                    label = { Text("Género") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions =
                        KeyboardActions(
                            onDone = {
                                focus.clearFocus()
                                keyboard?.hide()
                            },
                        ),
                    enabled = !saving,
                )
                OutlinedTextField(
                    track,
                    { track = it },
                    field("track"),
                    label = { Text("Número de pista") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions =
                        KeyboardActions(
                            onDone = {
                                focus.clearFocus()
                                keyboard?.hide()
                            },
                        ),
                    enabled = !saving,
                )
                Text(
                    "${song.format} · ${song.durationMs/1000} s",
                    style = MaterialTheme.typography.bodySmall,
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !saving,
                onClick = {
                    saving = true
                    scope.launch {
                        try {
                            graph.saveMetadata(song, draft())
                            dismiss()
                        } catch (e: Exception) {
                            if (e is CancellationException) throw e
                            error = e.userMessage()
                        } finally {
                            saving = false
                        }
                    }
                },
            ) {
                Text("Guardar en Sonora")
            }
        },
        dismissButton = { TextButton(enabled = !saving, onClick = ::close) { Text("Cancelar") } },
    )
    if (discard)
        AlertDialog(
            onDismissRequest = { discard = false },
            title = { Text("¿Descartar los cambios?") },
            confirmButton = { TextButton(onClick = dismiss) { Text("Descartar") } },
            dismissButton = {
                TextButton(onClick = { discard = false }) { Text("Seguir editando") }
            },
        )
}
