package com.tonyredondo.sonora

import android.app.Application
import android.net.Uri
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

class SonoraApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }
}

class AppGraph(val application: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val store = LibraryStore(application)
    val reader = LocalAudio(application)
    val metadataRevision = MutableStateFlow(0L)
    val songIndex = MutableStateFlow<Map<String, Song>>(emptyMap())
    val songs = MutableStateFlow<List<Song>>(emptyList())
    val playlists = MutableStateFlow<List<MusicPlaylist>>(emptyList())
    val ready = MutableStateFlow(false)
    val issue = MutableStateFlow<String?>(null)
    val importing = MutableStateFlow<Int?>(null)
    val page = MutableStateFlow(PlayerPage.LYRICS)
    val sound = MutableStateFlow(SoundSettings())
    val transitions = MutableStateFlow(TransitionSettings())
    val transitionInfo = MutableStateFlow("")
    private val transitionWrites = Channel<TransitionSettings>(Channel.CONFLATED)
    val listening = MutableStateFlow(ListeningSettings())
    val normalizationInfo = MutableStateFlow("Desactivada")
    val sleepTimer = MutableStateFlow<SleepTimer?>(null)
    private val listeningWrites = Channel<ListeningSettings>(Channel.CONFLATED)
    private val timerWrites = Channel<SleepTimer?>(Channel.CONFLATED)
    val songTools = MutableStateFlow<Map<String, SongTools>>(emptyMap())
    val loop = MutableStateFlow<LoopRegion?>(null)
    private val toolWrites = Channel<Pair<String, SongTools>>(Channel.UNLIMITED)
    val extras = MutableStateFlow<Map<String, SongExtras>>(emptyMap())
    private val onlineStore = OnlineSettingsStore(application)
    val online = MutableStateFlow(OnlineSettings())
    val lyrics = LyricsPreparation(this)
    val remote = RemotePreparation(this)
    val panorama = PanoramaPreparation(this)
    val character = AudioCharacterPreparation(this)
    val artwork = GeneratedArtworkPreparation(this)
    private var queuedSongs: List<String> = emptyList()
    val preparation = PreparationEngine(this)
    private val pageWrites = Channel<PlayerPage>(Channel.CONFLATED)
    private val soundWrites = Channel<SoundSettings>(Channel.CONFLATED)

    init {
        scope.launch(Dispatchers.IO) {
            for (value in transitionWrites) try {
                store.putState("transitions-v1", value.encode())
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch(Dispatchers.IO) {
            for (value in listeningWrites) try {
                store.putState("listening-v1", value.encode())
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch(Dispatchers.IO) {
            for (value in timerWrites) try {
                store.putState("sleep-v1", value?.encode() ?: "null")
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch(Dispatchers.IO) {
            for ((id, value) in toolWrites) try {
                store.putState("song-tools-v1:$id", value.encode())
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch {
            extras
                .map { all ->
                    all.mapValues { (_, extra) ->
                        listOf(
                            extra.styles,
                            extra.moods,
                            extra.meaning,
                            extra.albumMeaning,
                            extra.progress[PreparationStage.TAGS]?.state,
                            extra.progress[PreparationStage.ALBUM]?.state,
                        )
                    }
                }
                .distinctUntilChanged()
                .collect { artwork.prepare(queuedSongs) }
        }

        scope.launch(Dispatchers.IO) {
            for (value in soundWrites) try {
                store.putState("sound-v1", value.encode())
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch(Dispatchers.IO) {
            for (value in pageWrites) try {
                store.putState("page", value.name)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    try {
                        online.value = onlineStore.read()
                    } catch (_: Exception) {
                        issue.value =
                            "No se pudo leer la conexión guardada. Vuelve a guardarla en Ajustes; se conserva la configuración existente."
                    }
                    try {
                        store.state("sound-v1")?.let { sound.value = SoundSettings.decode(it) }
                        store.state("transitions-v1")?.let {
                            transitions.value = TransitionSettings.decode(it)
                        }
                    } catch (error: Exception) {
                        issue.value = error.userMessage()
                    }
                    try {
                        store.state("listening-v1")?.let {
                            listening.value = ListeningSettings.decode(it)
                        }
                    } catch (error: Exception) {
                        issue.value = error.userMessage()
                    }
                    try {
                        store
                            .state("sleep-v1")
                            ?.takeIf { it != "null" }
                            ?.let {
                                val saved = SleepTimer.decode(it)
                                if (
                                    saved.deadlineMs != null &&
                                        saved.deadlineMs <= System.currentTimeMillis()
                                )
                                    timerWrites.trySend(null)
                                else sleepTimer.value = saved
                            }
                    } catch (error: Exception) {
                        issue.value = error.userMessage()
                    }
                    store.state("page")?.let { saved ->
                        PlayerPage.entries.firstOrNull { it.name == saved }?.let { page.value = it }
                    }
                    refresh()
                }
            } catch (error: Exception) {
                issue.value = error.userMessage()
            } finally {
                ready.value = true
                character.prepare(queuedSongs)
                remote.prepare(queuedSongs)
                panorama.prepare(queuedSongs)
                artwork.prepare(queuedSongs)
            }
        }
    }

    suspend fun refresh(metadataChanged: Boolean = false) {
        val (tracks, lists) = withContext(Dispatchers.IO) { store.songs() to store.playlists() }
        withContext(Dispatchers.Main.immediate) {
            if (metadataChanged) {
                val changed =
                    tracks
                        .filter { song ->
                            songIndex.value[song.id]?.let { old ->
                                old.lyricsText != song.lyricsText ||
                                    old.title != song.title ||
                                    old.artist != song.artist ||
                                    old.album != song.album
                            } == true
                        }
                        .map { it.id }
                        .toSet()
                extras.value =
                    extras.value.mapValues { (id, old) ->
                        if (id in changed)
                            old.copy(translation = emptyMap(), meaning = null, albumMeaning = null)
                        else old
                    }
            }
            songs.value = tracks
            songIndex.value = tracks.associateBy { it.id }
            playlists.value = lists
            metadataRevision.value++
            if (metadataChanged) {
                preparation.prepare(queuedSongs)
                lyrics.prepare(queuedSongs)
                character.prepare(queuedSongs)
                remote.prepare(queuedSongs)
                panorama.prepare(queuedSongs)
                artwork.prepare(queuedSongs)
            }
        }
    }

    fun loadSongTools(ids: List<String>) {
        val missing = ids.distinct().filter { it !in songTools.value }
        if (missing.isEmpty()) return
        scope.launch {
            try {
                val values =
                    withContext(Dispatchers.IO) {
                        missing.associateWith { id ->
                            store.state("song-tools-v1:$id")?.let(SongTools::decode) ?: SongTools()
                        }
                    }
                songTools.value = values + songTools.value
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                issue.value = error.userMessage()
            }
        }
    }

    fun setSongTools(id: String, value: SongTools) {
        require(id.isNotBlank())
        value.validate()
        songTools.value = songTools.value + (id to value)
        toolWrites.trySend(id to value)
    }

    suspend fun saveMetadata(song: Song, draft: MetadataDraft) {
        withContext(Dispatchers.IO) { store.updateMetadata(song, draft) }
        withContext(Dispatchers.Main.immediate) {
            extras.value[song.id]?.let { old ->
                extras.value =
                    extras.value +
                        (song.id to
                            old.copy(
                                meaning = null,
                                albumMeaning = null,
                                generatedArtwork = null,
                                panorama = null,
                                progress =
                                    old.progress -
                                        setOf(
                                            PreparationStage.MEANING,
                                            PreparationStage.ALBUM,
                                            PreparationStage.ARTWORK,
                                            PreparationStage.PANORAMA,
                                        ),
                            ))
            }
        }
        refresh(metadataChanged = true)
    }

    suspend fun saveLyrics(song: Song, text: String) =
        scope
            .async {
                withContext(Dispatchers.IO) { store.updateLyrics(song, text) }
                extras.value =
                    extras.value.mapValues { (id, old) ->
                        if (id == song.id)
                            old.copy(
                                translation = emptyMap(),
                                meaning = null,
                                albumMeaning = null,
                                progress =
                                    old.progress -
                                        setOf(
                                            PreparationStage.TRANSLATION,
                                            PreparationStage.MEANING,
                                            PreparationStage.ALBUM,
                                        ),
                            )
                        else old
                    }
                refresh(metadataChanged = true)
            }
            .await()

    fun setTransitions(value: TransitionSettings) {
        value.validate()
        if (value == transitions.value) return
        transitions.value = value
        transitionInfo.value = ""
        transitionWrites.trySend(value)
    }

    fun setListening(value: ListeningSettings) {
        value.validate()
        val copied =
            value.copy(equalizer = value.equalizer.copy(gains = value.equalizer.gains.toList()))
        if (copied == listening.value) return
        listening.value = copied
        listeningWrites.trySend(copied)
    }

    fun setSleepTimer(value: SleepTimer?) {
        value?.validate()
        if (value?.deadlineMs != null && value.deadlineMs <= System.currentTimeMillis()) {
            sleepTimer.value = null
            timerWrites.trySend(null)
            return
        }
        if (value?.deadlineMs != null)
            require(value.deadlineMs - System.currentTimeMillis() <= 86_400_000)
        if (value?.songId != null) loop.value = null
        sleepTimer.value = value
        timerWrites.trySend(value)
    }

    fun setSound(value: SoundSettings) {
        value.validate()
        if (value == sound.value) return
        sound.value = value
        soundWrites.trySend(value)
    }

    fun selectPage(value: PlayerPage) {
        page.value = value
        pageWrites.trySend(value)
    }

    fun importTree(uri: Uri) {
        if (importing.value != null) return
        importing.value = 0
        scope.launch {
            try {
                val tracks =
                    withContext(Dispatchers.IO) { reader.scanTree(uri) { importing.value = it } }
                require(tracks.isNotEmpty()) {
                    "La carpeta no contiene archivos de audio reconocidos."
                }
                withContext(Dispatchers.IO) { store.saveSongs(tracks) }
                refresh(metadataChanged = true)
            } catch (error: Exception) {
                if (error !is CancellationException) issue.value = error.userMessage()
            } finally {
                importing.value = null
            }
        }
    }

    fun importFiles(uris: List<Uri>) {
        if (uris.isEmpty() || importing.value != null) return
        importing.value = 0
        scope.launch {
            try {
                val tracks =
                    withContext(Dispatchers.IO) {
                        uris.mapIndexed { index, uri ->
                            ensureActive()
                            reader.read(uri).also { importing.value = index + 1 }
                        }
                    }
                withContext(Dispatchers.IO) { store.saveSongs(tracks) }
                refresh(metadataChanged = true)
            } catch (error: Exception) {
                if (error !is CancellationException) issue.value = error.userMessage()
            } finally {
                importing.value = null
            }
        }
    }

    fun queuedSongIds(): List<String> = queuedSongs

    fun setQueue(ids: List<String>) {
        if (ids == queuedSongs) return
        queuedSongs = ids.toList()
        loadSongTools(ids)
        preparation.prepare(ids)
        lyrics.prepare(ids)
        character.prepare(ids)
        remote.prepare(ids)
        panorama.prepare(ids)
        artwork.prepare(ids)
    }

    fun prepareAgain() {
        preparation.prepare(queuedSongs, refresh = true)
        character.prepare(queuedSongs, refresh = true)
        remote.prepare(queuedSongs, refresh = true)
        artwork.prepare(queuedSongs, retryFailed = true)
    }

    fun resumePreparation() {
        lyrics.prepare(queuedSongs)
        character.prepare(queuedSongs)
        remote.prepare(queuedSongs)
        panorama.prepare(queuedSongs)
        artwork.resume(queuedSongs)
    }

    suspend fun saveOnline(value: OnlineSettings) =
        scope
            .async {
                withContext(Dispatchers.IO) { onlineStore.write(value) }
                online.value = value
                extras.value =
                    extras.value.mapValues { (_, old) ->
                        old.copy(translation = emptyMap(), meaning = null, albumMeaning = null)
                    }
                lyrics.prepare(queuedSongs)
                character.prepare(queuedSongs)
                remote.prepare(queuedSongs)
                panorama.prepare(queuedSongs)
                artwork.prepare(queuedSongs)
            }
            .await()

    fun favorite(song: Song) = mutate { store.setFavorite(song.id, !song.favorite) }

    fun createPlaylist(name: String) = mutate { store.createPlaylist(name) }

    fun addToPlaylist(id: String, songs: List<String>) = mutate {
        val old = store.playlists().firstOrNull { it.id == id } ?: error("La lista ya no existe.")
        store.setPlaylistSongs(id, old.songIds + songs)
    }

    fun mutate(action: () -> Unit) {
        scope.launch {
            try {
                withContext(Dispatchers.IO) { action() }
                refresh()
            } catch (error: Exception) {
                if (error !is CancellationException) issue.value = error.userMessage()
            }
        }
    }
}

fun Throwable.userMessage(): String =
    when (this) {
        is SecurityException ->
            "Sonora ya no tiene acceso a este archivo. Vuelve a elegir su carpeta."
        is java.io.FileNotFoundException ->
            "El archivo no está disponible. Comprueba su ubicación y el permiso de lectura."
        else -> localizedMessage?.takeIf { it.isNotBlank() } ?: "No se pudo completar la operación."
    }
