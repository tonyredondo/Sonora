package com.tonyredondo.sonora

import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(model: PlayerModel) {
    var mode by remember { mutableStateOf("Canciones") }
    var group by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var playlistName by remember { mutableStateOf<String?>(null) }
    var addSong by remember { mutableStateOf<Song?>(null) }
    var exportList by remember { mutableStateOf<MusicPlaylist?>(null) }
    val editMetadata by model.metadataEditorSource.collectAsStateWithLifecycle()
    val playlists by model.graph.playlists.collectAsStateWithLifecycle()
    BackHandler(group != null) { group = null }
    val songs by model.graph.songs.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val importing by model.graph.importing.collectAsStateWithLifecycle()
    val context = LocalContext.current
    fun retain(uri: android.net.Uri) {
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (error: SecurityException) {
                model.graph.issue.value = error.userMessage()
            }
        }
    }
    val folder =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            uri?.let {
                retain(it)
                model.graph.importTree(it)
            }
        }
    val files =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            uris.forEach(::retain)
            model.graph.importFiles(uris)
        }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sonora") },
                actions = {
                    IconButton(
                        onClick = {
                            files.launch(
                                arrayOf("audio/*", "application/ogg", "application/octet-stream"),
                            )
                        },
                        enabled = importing == null,
                    ) {
                        Icon(Icons.Rounded.Add, "Añadir archivos")
                    }
                    IconButton(onClick = { folder.launch(null) }, enabled = importing == null) {
                        Icon(Icons.Rounded.FolderOpen, "Vincular carpeta")
                    }
                    IconButton(onClick = { model.showSettings.value = true }) {
                        Icon(Icons.Rounded.Settings, "Servicios online")
                    }
                },
            )
        },
        bottomBar = {
            if (playback.currentId != null)
                Surface(tonalElevation = 4.dp) {
                    Column(
                        Modifier.navigationBarsPadding()
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        playback.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(
                                Modifier.weight(1f).clickable { model.showPlayer.value = true },
                            ) {
                                Text(playback.title.ifEmpty { "Audio" }, maxLines = 1)
                                Text(playback.artist, style = MaterialTheme.typography.bodySmall)
                            }
                            IconButton(onClick = model::previous) {
                                Icon(Icons.Rounded.SkipPrevious, "Anterior")
                            }
                            FilledIconButton(onClick = model::togglePlayback) {
                                Icon(
                                    if (playback.showsPause) Icons.Rounded.Pause
                                    else Icons.Rounded.PlayArrow,
                                    if (playback.showsPause) "Pausa" else "Reproducir",
                                )
                            }
                            IconButton(onClick = model::next) {
                                Icon(Icons.Rounded.SkipNext, "Siguiente")
                            }
                        }
                        Slider(
                            value =
                                playback.positionMs
                                    .toFloat()
                                    .coerceIn(0f, playback.durationMs.coerceAtLeast(1).toFloat()),
                            onValueChange = { model.seek(it.toLong()) },
                            valueRange = 0f..playback.durationMs.coerceAtLeast(1).toFloat(),
                        )
                    }
                }
        },
    ) { padding ->
        if (songs.isEmpty())
            Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text("Tu música, contigo.", style = MaterialTheme.typography.headlineLarge)
                Spacer(Modifier.height(12.dp))
                Text("Abre tus archivos o vincula una carpeta para escucharlos en Sonora.")
                Spacer(Modifier.height(24.dp))
                Button(
                    onClick = {
                        files.launch(
                            arrayOf("audio/*", "application/ogg", "application/octet-stream"),
                        )
                    },
                    enabled = importing == null,
                ) {
                    Text("Añadir archivos")
                }
                OutlinedButton(onClick = { folder.launch(null) }, enabled = importing == null) {
                    Text("Vincular carpeta")
                }
                importing?.let {
                    LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text("Leyendo $it canciones…")
                }
            }
        else
            Column(Modifier.fillMaxSize().padding(padding)) {
                OutlinedTextField(
                    query,
                    { query = it },
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                    placeholder = { Text("Buscar en tu música") },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Rounded.Search, null) },
                )
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 20.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    listOf("Canciones", "Álbumes", "Artistas", "Listas", "Favoritos").forEach { item
                        ->
                        FilterChip(
                            mode == item,
                            {
                                mode = item
                                group = null
                            },
                            label = { Text(item) },
                        )
                    }
                }
                if (group != null)
                    TextButton(onClick = { group = null }) {
                        Icon(Icons.Rounded.ArrowBack, null)
                        Text("Volver")
                    }
                val byId = remember(songs) { songs.associateBy { it.id } }
                val base =
                    remember(mode, group, songs, playlists) {
                        when (mode) {
                            "Favoritos" -> songs.filter { it.favorite }
                            "Álbumes" ->
                                songs.filter {
                                    group == null || "${it.artist}\u0000${it.album}" == group
                                }
                            "Artistas" -> songs.filter { group == null || it.artist == group }
                            "Listas" ->
                                if (group == null) emptyList()
                                else
                                    playlists
                                        .firstOrNull { it.id == group }
                                        ?.songIds
                                        .orEmpty()
                                        .mapNotNull { id -> byId[id] }
                            else -> songs
                        }
                    }
                val shown =
                    remember(base, query) {
                        base.filter {
                            query.isBlank() ||
                                listOf(it.title, it.artist, it.album).any { field ->
                                    field.contains(query, ignoreCase = true)
                                }
                        }
                    }
                val groups =
                    remember(shown, mode) {
                        shown.groupBy {
                            if (mode == "Álbumes") "${it.artist}\u0000${it.album}" else it.artist
                        }
                    }
                LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                    if (mode == "Listas" && group == null) {
                        item {
                            TextButton(
                                onClick = { playlistName = "" },
                                Modifier.padding(horizontal = 16.dp),
                            ) {
                                Icon(Icons.Rounded.Add, null)
                                Text("Crear lista")
                            }
                        }
                        items(
                            playlists.filter { it.name.contains(query, ignoreCase = true) },
                            key = { it.id },
                        ) { list ->
                            ListItem(
                                headlineContent = { Text(list.name) },
                                supportingContent = { Text("${list.songIds.size} canciones") },
                                leadingContent = { Icon(Icons.Rounded.PlaylistPlay, null) },
                                trailingContent = {
                                    IconButton(onClick = { exportList = list }) {
                                        Icon(Icons.Rounded.IosShare, "Exportar lista")
                                    }
                                },
                                modifier = Modifier.clickable { group = list.id },
                            )
                        }
                    } else if (mode in listOf("Álbumes", "Artistas") && group == null) {
                        items(groups.entries.toList(), key = { it.key }) { entry ->
                            ListItem(
                                headlineContent = {
                                    Text(
                                        if (mode == "Álbumes")
                                            entry.value.first().album.ifBlank { "Sin álbum" }
                                        else entry.key.ifBlank { "Artista desconocido" },
                                    )
                                },
                                supportingContent = { Text("${entry.value.size} canciones") },
                                leadingContent = {
                                    SongArtwork(
                                        entry.value.first().displayArtworkPath(),
                                        Modifier.size(56.dp),
                                    )
                                },
                                modifier = Modifier.clickable { group = entry.key },
                            )
                        }
                    } else {
                        importing?.let {
                            item { Text("Leyendo $it canciones…", Modifier.padding(20.dp)) }
                        }
                        itemsIndexed(shown, key = { index, song -> "$index:${song.id}" }) {
                            index,
                            song ->
                            ListItem(
                                leadingContent = {
                                    SongArtwork(song.displayArtworkPath(), Modifier.size(56.dp))
                                },
                                headlineContent = { Text(song.title) },
                                supportingContent = {
                                    Text(
                                        listOf(song.artist, song.album)
                                            .filter(String::isNotBlank)
                                            .joinToString(" · "),
                                    )
                                },
                                trailingContent = {
                                    Row {
                                        IconButton(
                                            onClick = { model.metadataEditorSource.value = song },
                                            Modifier.testTag("metadata:${song.id}"),
                                        ) {
                                            Icon(Icons.Rounded.Info, "Información del archivo")
                                        }
                                        IconButton(onClick = { addSong = song }) {
                                            Icon(Icons.Rounded.PlaylistAdd, "Añadir a lista")
                                        }
                                        IconButton(onClick = { model.graph.favorite(song) }) {
                                            Icon(
                                                if (song.favorite) Icons.Rounded.Favorite
                                                else Icons.Rounded.FavoriteBorder,
                                                "Favorito",
                                                tint =
                                                    if (song.favorite) SonoraAmber
                                                    else MaterialTheme.colorScheme.onSurface,
                                            )
                                        }
                                    }
                                },
                                modifier = Modifier.clickable { model.play(shown, index) },
                            )
                        }
                    }
                }
            }
    }
    editMetadata?.let { song ->
        MetadataEditorDialog(song, model.graph) { model.metadataEditorSource.value = null }
    }
    exportList?.let { list ->
        PlaylistExportDialog(list, model.graph) { exportList = null }
    }
    playlistName?.let { name ->
        AlertDialog(
            onDismissRequest = { playlistName = null },
            title = { Text("Crear lista") },
            text = {
                OutlinedTextField(
                    name,
                    { playlistName = it },
                    label = { Text("Nombre") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        model.graph.createPlaylist(name)
                        playlistName = null
                    },
                    enabled = name.isNotBlank(),
                ) {
                    Text("Crear")
                }
            },
            dismissButton = { TextButton(onClick = { playlistName = null }) { Text("Cancelar") } },
        )
    }
    addSong?.let { song ->
        AlertDialog(
            onDismissRequest = { addSong = null },
            title = { Text("Añadir a lista") },
            text = {
                if (playlists.isEmpty()) Text("Crea una lista desde la pestaña Listas.")
                else
                    LazyColumn {
                        items(playlists, key = { it.id }) { list ->
                            TextButton(
                                onClick = {
                                    model.graph.addToPlaylist(list.id, listOf(song.id))
                                    addSong = null
                                },
                            ) {
                                Text(list.name)
                            }
                        }
                    }
            },
            confirmButton = { TextButton(onClick = { addSong = null }) { Text("Listo") } },
        )
    }
}
