package com.tonyredondo.sonora

import android.app.Application
import android.content.ComponentName
import android.net.Uri
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest

data class PlaybackViewState(
    val connected: Boolean = false,
    val currentId: String? = null,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val artworkPath: String? = null,
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val repeat: Int = Player.REPEAT_MODE_OFF,
    val shuffle: Boolean = false,
    val currentIndex: Int = -1,
    val queue: List<String> = emptyList(),
    val error: String? = null,
    val playRequested: Boolean = false,
    val suppressed: Boolean = false,
) {
    val showsPause: Boolean
        get() = playing || (buffering && playRequested && !suppressed)
}

class PlayerModel(application: Application) : AndroidViewModel(application) {
    val graph = (application as SonoraApplication).graph
    val playback = MutableStateFlow(PlaybackViewState())
    val visible = MutableStateFlow(false)
    val metadataEditorSource = MutableStateFlow<Song?>(null)
    val showSettings = MutableStateFlow(false)
    val showPlayer = MutableStateFlow(false)
    val currentSong = MutableStateFlow<Song?>(null)
    val lyricsEditorSource = MutableStateFlow<Song?>(null)
    val lyricsEditorText = MutableStateFlow("")
    val lyricsEditorIssue = MutableStateFlow<String?>(null)
    val lyricsEditorBusy = MutableStateFlow(false)
    val timingSource = MutableStateFlow<Song?>(null)
    val timingDraft = MutableStateFlow<LyricsDraft?>(null)
    val timingCursor = MutableStateFlow(0)
    val timingIssue = MutableStateFlow<String?>(null)
    val followLyrics = MutableStateFlow(true)
    private var aiPreview: Job? = null
    private var aiPreviewGeneration = 0
    private var aiPreviewSource: String? = null
    private var aiPreviewIndex = -1
    private var aiPreviewLoop: LoopRegion? = null
    internal val lyricsAI =
        LyricsAIController(
            graph,
            viewModelScope,
            { source, expected, text ->
                if (
                    lyricsEditorSource.value?.id == source.id && lyricsEditorText.value == expected
                ) {
                    setLyricsDraft(text)
                    true
                } else false
            },
            ::stopAILyricPreview,
        )
    val lyricScrollRequest = MutableStateFlow(0)
    val volume = MutableStateFlow(0)
    private val audio =
        application.getSystemService(android.content.Context.AUDIO_SERVICE)
            as android.media.AudioManager
    val maximumVolume: Int = audio.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
    private var lastQueue: List<String> = emptyList()
    private var lastSongId: String? = null
    private var metadataJob: Job? = null
    var controller: MediaController? = null
        private set

    private var pending: Pair<List<MediaItem>, Int>? = null
    private var selectionRevision = 0
    private var openJob: Job? = null
    private val future =
        MediaController.Builder(
                application,
                SessionToken(application, ComponentName(application, PlaybackService::class.java)),
            )
            .setApplicationLooper(Looper.getMainLooper())
            .buildAsync()
    private val listener =
        object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                update(events.contains(Player.EVENT_TIMELINE_CHANGED))
            }
        }

    init {
        future.addListener(
            {
                try {
                    val player = future.get()
                    controller = player
                    player.addListener(listener)
                    pending?.let { start(it.first, it.second) }
                    pending = null
                    update(true)
                } catch (error: Exception) {
                    graph.issue.value =
                        "No se pudo conectar con el reproductor. ${error.userMessage()}"
                }
            },
            ContextCompat.getMainExecutor(application),
        )
        viewModelScope.launch { graph.metadataRevision.collect { reloadCurrentSong() } }
        viewModelScope.launch {
            visible.collectLatest { shown ->
                if (shown) {
                    graph.resumePreparation()
                    while (isActive) {
                        update()
                        delay(250)
                    }
                }
            }
        }
    }

    private fun update(refreshQueue: Boolean = false) {
        val player = controller ?: return
        val metadata = player.mediaMetadata
        val id = player.currentMediaItem?.mediaId
        if (id != lastSongId) {
            lastSongId = id
            reloadCurrentSong()
        }
        if (refreshQueue) {
            val queue = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
            if (queue != lastQueue) {
                lastQueue = queue
                graph.setQueue(queue)
            }
        }
        volume.value = audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
        playback.value =
            PlaybackViewState(
                true,
                player.currentMediaItem?.mediaId,
                metadata.title?.toString().orEmpty(),
                metadata.artist?.toString().orEmpty(),
                metadata.albumTitle?.toString().orEmpty(),
                metadata.artworkUri?.takeIf { it.scheme == "file" }?.path,
                player.isPlaying,
                player.playbackState == Player.STATE_BUFFERING,
                player.currentPosition.coerceAtLeast(0),
                player.duration.coerceAtLeast(0),
                player.repeatMode,
                player.shuffleModeEnabled,
                player.currentMediaItemIndex,
                lastQueue,
                player.playerError?.let {
                    "No se pudo reproducir este archivo (${it.errorCodeName})."
                },
                player.playWhenReady,
                player.playbackSuppressionReason != Player.PLAYBACK_SUPPRESSION_REASON_NONE,
            )
    }

    private fun reloadCurrentSong() {
        val id = controller?.currentMediaItem?.mediaId
        metadataJob?.cancel()
        if (currentSong.value?.id != id) currentSong.value = null
        metadataJob = viewModelScope.launch {
            val song = withContext(Dispatchers.IO) { id?.let(graph.store::song) }
            if (controller?.currentMediaItem?.mediaId == id) currentSong.value = song
        }
    }

    fun editLyrics(song: Song, text: String = song.lyricsText) {
        lyricsEditorText.value = text
        lyricsEditorIssue.value = null
        lyricsEditorSource.value = song
    }

    fun setLyricsDraft(value: String) {
        if (value.toByteArray().size > 1_000_000) {
            lyricsEditorIssue.value = "La letra es demasiado grande."
            return
        }
        lyricsEditorText.value = value
        lyricsEditorIssue.value = null
    }

    fun closeLyricsEditor() {
        if (!lyricsEditorBusy.value) {
            lyricsAI.close()
            lyricsEditorSource.value = null
        }
    }

    fun saveLyricsEditor() {
        if (lyricsEditorBusy.value) return
        val source = lyricsEditorSource.value ?: return
        val text = lyricsEditorText.value
        lyricsEditorBusy.value = true
        lyricsEditorIssue.value = null
        viewModelScope.launch {
            try {
                graph.saveLyrics(source, text)
                lyricsEditorSource.value = null
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                lyricsEditorIssue.value = error.userMessage()
            } finally {
                lyricsEditorBusy.value = false
            }
        }
    }

    internal fun listenToAIFragment(source: Song, start: Double?, end: Double?) {
        val position = start ?: return
        val player = controller ?: return
        if (player.currentMediaItem?.mediaId != source.id || !position.isFinite()) return
        stopAILyricPreview()
        aiPreviewLoop = graph.loop.value
        graph.loop.value = null
        aiPreviewSource = source.id
        aiPreviewIndex = player.currentMediaItemIndex
        val token = ++aiPreviewGeneration
        val from = ((position - .5).coerceAtLeast(0.0) * 1000).toLong()
        val until =
            ((end ?: position + 4).coerceAtLeast(position + 1) * 1000)
                .toLong()
                .coerceAtMost(source.durationMs)
        player.seekTo(from)
        player.play()
        aiPreview = viewModelScope.launch {
            try {
                while (
                    player.currentMediaItem?.mediaId == source.id &&
                        player.currentMediaItemIndex == aiPreviewIndex &&
                        player.playWhenReady &&
                        player.currentPosition < until
                ) delay(30)
            } finally {
                if (aiPreviewGeneration == token) stopAILyricPreview()
            }
        }
    }

    internal fun stopAILyricPreview() {
        aiPreviewGeneration++
        aiPreview?.cancel()
        aiPreview = null
        controller
            ?.takeIf {
                it.currentMediaItem?.mediaId == aiPreviewSource &&
                    it.currentMediaItemIndex == aiPreviewIndex
            }
            ?.pause()
        if (
            controller?.currentMediaItem?.mediaId == aiPreviewSource &&
                controller?.currentMediaItemIndex == aiPreviewIndex &&
                graph.loop.value == null
        )
            graph.loop.value = aiPreviewLoop
        aiPreviewSource = null
        aiPreviewIndex = -1
        aiPreviewLoop = null
    }

    fun openManualTiming(song: Song, text: String = song.lyricsText) {
        timingSource.value = song
        timingDraft.value = LyricsDraft.from(text).clearTiming()
        timingCursor.value = 0
        timingIssue.value = null
    }

    fun stampPhrase() {
        val source = timingSource.value ?: return
        if (controller?.currentMediaItem?.mediaId != source.id) return
        try {
            val old = timingDraft.value ?: return
            timingDraft.value = old.mark(timingCursor.value, controller?.currentPosition ?: return)
            timingCursor.value = (timingCursor.value + 1).coerceAtMost(old.lines.lastIndex)
            timingIssue.value = null
        } catch (error: Exception) {
            timingIssue.value = error.userMessage()
        }
    }

    fun applyManualTiming() {
        val source = timingSource.value ?: return
        try {
            val text = timingDraft.value?.serialize() ?: return
            editLyrics(source, text)
            timingSource.value = null
        } catch (error: Exception) {
            timingIssue.value = error.userMessage()
        }
    }

    fun play(songs: List<Song>, index: Int = 0) {
        selectionRevision++
        openJob?.cancel()
        require(index in songs.indices)
        showPlayer.value = true
        start(songs.map { it.mediaItem() }, index)
    }

    private fun start(items: List<MediaItem>, index: Int) {
        val player = controller
        if (player == null) {
            pending = items to index
            return
        }
        player.setMediaItems(items, index, 0)
        player.prepare()
        player.play()
        update(true)
    }

    fun openExternal(uri: Uri) {
        val revision = ++selectionRevision
        openJob?.cancel()
        showPlayer.value = true
        openJob = viewModelScope.launch {
            try {
                require(validLocalAudioUri(uri.toString())) {
                    "Solo se admiten archivos de audio locales."
                }
                if (uri.scheme == "file") {
                    val path = java.io.File(uri.path ?: "").canonicalPath
                    require(
                        !path.startsWith(getApplication<Application>().dataDir.canonicalPath + "/"),
                    ) {
                        "No se puede abrir un archivo privado desde otra aplicación."
                    }
                }
                val song =
                    withContext(Dispatchers.IO) {
                        graph.reader.read(uri).also {
                            ensureActive()
                            graph.store.saveSongs(listOf(it), inLibrary = false)
                        }
                    }
                if (revision == selectionRevision) {
                    start(listOf(song.mediaItem()), 0)
                    reloadCurrentSong()
                }
            } catch (error: Exception) {
                if (error !is CancellationException) graph.issue.value = error.userMessage()
            }
        }
    }

    fun togglePlayback() {
        val player = controller ?: return
        if (
            player.isPlaying ||
                (player.playWhenReady &&
                    player.playbackState == Player.STATE_BUFFERING &&
                    player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE)
        )
            player.pause()
        else {
            if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition()
            if (player.playbackState == Player.STATE_IDLE || player.playerError != null)
                player.prepare()
            player.play()
        }
        update()
    }

    fun setVolume(value: Int) {
        audio.setStreamVolume(
            android.media.AudioManager.STREAM_MUSIC,
            value.coerceIn(0, maximumVolume),
            0,
        )
        volume.value = audio.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
    }

    fun resumeLyrics() {
        followLyrics.value = true
        lyricScrollRequest.value++
    }

    fun seek(position: Long) {
        graph.loop.value?.let {
            if (position !in it.startMs until it.endMs) graph.loop.value = null
        }
        controller?.seekTo(position.coerceAtLeast(0))
        update()
    }

    fun repeatPhrase(song: Song, index: Int) {
        try {
            require(controller?.currentMediaItem?.mediaId == song.id) {
                "Reproduce esta canción para repetir una frase."
            }
            val region =
                phraseLoop(
                    song.id,
                    LyricsDocument.parse(song.lyricsText),
                    index,
                    controller!!.duration.coerceAtLeast(song.durationMs),
                    graph.songTools.value[song.id]?.offsetMs ?: 0,
                )
            graph.loop.value = region
            controller!!.seekTo(region.startMs)
            controller!!.play()
        } catch (error: Exception) {
            graph.issue.value = error.userMessage()
        }
    }

    fun previous() {
        controller?.seekToPrevious()
        update()
    }

    fun next() {
        controller?.seekToNextMediaItem()
        update()
    }

    fun shuffle() {
        controller?.let { it.shuffleModeEnabled = !it.shuffleModeEnabled }
        update()
    }

    fun repeat() {
        controller?.let {
            it.repeatMode =
                when (it.repeatMode) {
                    Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
                    Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
                    else -> Player.REPEAT_MODE_OFF
                }
        }
        update()
    }

    override fun onCleared() {
        lyricsAI.close()
        controller?.removeListener(listener)
        MediaController.releaseFuture(future)
        super.onCleared()
    }
}
