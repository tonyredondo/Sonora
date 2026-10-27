package com.tonyredondo.sonora

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

@Composable
fun PlaylistExportDialog(playlist: MusicPlaylist, graph: AppGraph, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var format by remember { mutableStateOf(PlaylistExportFormat.ORIGINAL) }
    var message by remember { mutableStateOf("") }
    var saved by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var job by remember { mutableStateOf<Job?>(null) }
    val chooser =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                working = true
                saved = false
                message = "Preparando exportación…"
                job = scope.launch {
                    try {
                        try {
                            context.contentResolver.takePersistableUriPermission(
                                uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                            )
                        } catch (_: SecurityException) {}
                        val songs =
                            withContext(Dispatchers.IO) {
                                playlist.songIds.map {
                                    graph.store.song(it)
                                        ?: error("Una canción de la lista ya no está disponible.")
                                }
                            }
                        val result =
                            PlaylistExporter(context, graph.store).export(
                                songs,
                                playlist.name,
                                uri,
                                format,
                            ) {
                                message = it
                            }
                        saved = true
                        message =
                            "${result.files} ${if(result.files==1) "canción" else "canciones"} y ${result.playlistName} guardados en la carpeta elegida."
                    } catch (error: CancellationException) {
                        message = "Exportación cancelada."
                        throw error
                    } catch (error: Exception) {
                        message = error.userMessage()
                    } finally {
                        working = false
                    }
                }
            }
        }
    AlertDialog(
        onDismissRequest = { if (working) job?.cancel() else onDismiss() },
        title = { Text("Exportar playlist") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(playlist.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    "Las canciones numeradas y la lista M3U8 se guardan directamente en la carpeta que elijas. Se incluyen portada, letras e información disponible en cada idioma.",
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = format == PlaylistExportFormat.ORIGINAL,
                        onClick = { format = PlaylistExportFormat.ORIGINAL },
                        enabled = !working,
                        label = { Text("Originales") },
                    )
                    FilterChip(
                        selected = format == PlaylistExportFormat.MP3,
                        onClick = { format = PlaylistExportFormat.MP3 },
                        enabled = !working,
                        label = { Text("MP3 · 320 kb/s") },
                    )
                }
                Text(
                    if (format == PlaylistExportFormat.ORIGINAL)
                        "Conserva el audio original. Los MP3 incluyen la letra en sus etiquetas."
                    else
                        "Convierte a MP3. Los archivos que ya sean MP3 conservan su audio sin recomprimir.",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (working) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (message.isNotBlank()) Text(if (saved) "✓ $message" else message)
            }
        },
        confirmButton = {
            TextButton(
                onClick = { chooser.launch(null) },
                enabled = !working && playlist.songIds.isNotEmpty(),
            ) {
                Text("Elegir carpeta y guardar")
            }
        },
        dismissButton = {
            TextButton(onClick = { if (working) job?.cancel() else onDismiss() }) {
                Text(if (working) "Cancelar" else "Listo")
            }
        },
    )
}
