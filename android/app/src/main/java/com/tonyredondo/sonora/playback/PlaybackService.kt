package com.tonyredondo.sonora

import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlaybackService : MediaLibraryService() {
    private lateinit var player: ExoPlayer
    private var listeningProcessor = ListeningAudioProcessor()
    private lateinit var transitions: CrossfadeCoordinator
    private val effectsSong = MutableStateFlow<String?>(null)
    private val restorationReady = MutableStateFlow(false)
    private var session: MediaLibrarySession? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val graph
        get() = (application as SonoraApplication).graph

    private val snapshots = Channel<PlaybackSnapshot>(Channel.CONFLATED)
    private var applyingRestore = false
    private var revision = 0
    private var disposed = false

    override fun onCreate() {
        super.onCreate()
        player = PlaybackPlayerFactory.create(this, listeningProcessor, true)
        session = MediaLibrarySession.Builder(this, player, LibraryCallback()).build()
        graph.scope.launch(Dispatchers.IO) {
            for (snapshot in snapshots) {
                try {
                    graph.store.saveSnapshot(snapshot)
                } catch (error: Exception) {
                    graph.issue.value = error.userMessage()
                }
            }
        }
        player.addListener(playbackListener)
        transitions =
            CrossfadeCoordinator(
                scope,
                { player },
                { graph.transitions.value },
                { graph.listening.value },
                { graph.loop.value != null || graph.sleepTimer.value?.songId != null },
                { graph.sleepTimer.value?.songId != null },
                { id ->
                    withContext(Dispatchers.IO) {
                        val song =
                            graph.store.song(id) ?: error("La canción ya no está disponible.")
                        val settings = graph.listening.value
                        val members =
                            if (
                                settings.normalization == NormalizationMode.ALBUM &&
                                    song.album.isNotBlank()
                            )
                                graph.store.albumSongs(song.artist, song.album)
                            else emptyList()
                        val result =
                            normalizationGain(
                                settings.normalization,
                                song,
                                members,
                                graph.extras.value,
                            )
                        MixTrack(
                            settings,
                            result.multiplier,
                            graph.extras.value[id] ?: SongExtras(),
                        )
                    }
                },
                { processor -> PlaybackPlayerFactory.create(this, processor, false) },
                { incoming, processor -> acceptHandoff(incoming, processor) },
                { graph.transitionInfo.value = it },
            )
        scope.launch {
            combine(graph.listening, effectsSong, graph.metadataRevision, graph.extras) {
                    settings,
                    id,
                    _,
                    extras ->
                    Triple(settings, id, extras)
                }
                .collectLatest { (settings, id, extras) ->
                    try {
                        val song = withContext(Dispatchers.IO) { id?.let(graph.store::song) }
                        val members =
                            withContext(Dispatchers.IO) {
                                if (
                                    song != null &&
                                        settings.normalization == NormalizationMode.ALBUM &&
                                        song.album.isNotBlank()
                                )
                                    graph.store.albumSongs(song.artist, song.album)
                                else emptyList()
                            }
                        val result =
                            normalizationGain(settings.normalization, song, members, extras)
                        graph.normalizationInfo.value = result.message
                        listeningProcessor.apply(settings, result.multiplier)
                        graph.preparation.prepare(result.neededIds, notifyCharacter = false)
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        graph.issue.value = error.userMessage()
                    }
                }
        }
        scope.launch {
            combine(graph.sleepTimer, restorationReady) { timer, restored -> timer to restored }
                .collectLatest { (timer, restored) ->
                    if (!restored && timer?.songId != null) return@collectLatest
                    player.pauseAtEndOfMediaItems = timer?.songId != null
                    if (
                        timer?.songId != null &&
                            (timer.songId != player.currentMediaItem?.mediaId ||
                                timer.occurrenceIndex != player.currentMediaItemIndex)
                    ) {
                        graph.setSleepTimer(null)
                    } else if (timer?.deadlineMs != null) {
                        delay((timer.deadlineMs - System.currentTimeMillis()).coerceAtLeast(0))
                        player.pause()
                        graph.loop.value = null
                        graph.setSleepTimer(null)
                    }
                }
        }
        scope.launch {
            graph.sound.collect { value ->
                val parameters = androidx.media3.common.PlaybackParameters(value.speed, value.pitch)
                if (player.playbackParameters != parameters) player.playbackParameters = parameters
            }
        }
        scope.launch {
            graph.loop.collectLatest { region ->
                if (region != null) {
                    region.validate()
                    while (isActive) {
                        if (player.currentMediaItem?.mediaId != region.songId) {
                            graph.loop.value = null
                            break
                        }
                        if (
                            (player.isPlaying ||
                                (player.playWhenReady &&
                                    player.playbackState == Player.STATE_ENDED)) &&
                                player.currentPosition >= region.endMs
                        ) {
                            player.seekTo(region.startMs)
                            if (player.playWhenReady) player.play()
                        }
                        delay(if (player.isPlaying) 30 else 200)
                    }
                }
            }
        }
        scope.launch {
            val captured = revision
            try {
                val saved =
                    withContext(Dispatchers.IO) {
                        graph.store.snapshot()?.let { snapshot ->
                            snapshot to
                                snapshot.ids.map { id ->
                                    graph.store.song(id)
                                        ?: error(
                                            "La cola guardada contiene una canción que ya no está disponible.",
                                        )
                                }
                        }
                    }
                if (
                    saved != null &&
                        captured == revision &&
                        player.mediaItemCount == 0 &&
                        saved.first.ids.isNotEmpty()
                ) {
                    val (snapshot, songs) = saved
                    applyingRestore = true
                    try {
                        player.setMediaItems(
                            songs.map { it.mediaItem() },
                            snapshot.currentIndex,
                            snapshot.positionMs,
                        )
                        player.shuffleModeEnabled = snapshot.shuffle
                        player.repeatMode = snapshot.repeat.media3()
                        player.playWhenReady = false
                    } finally {
                        applyingRestore = false
                    }
                }
            } catch (error: Exception) {
                if (error !is CancellationException) graph.issue.value = error.userMessage()
            } finally {
                restorationReady.value = true
            }
        }
        scope.launch {
            graph.metadataRevision.collect {
                val ids = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
                val songs = withContext(Dispatchers.IO) { ids.map(graph.store::song) }
                songs.forEachIndexed { index, song ->
                    if (
                        song != null &&
                            index < player.mediaItemCount &&
                            player.getMediaItemAt(index).mediaId == song.id
                    ) {
                        val current = player.getMediaItemAt(index)
                        val fresh = song.mediaItem()
                        if (
                            current.localConfiguration != fresh.localConfiguration ||
                                current.clippingConfiguration != fresh.clippingConfiguration
                        )
                            player.replaceMediaItem(index, fresh)
                        else if (current.mediaMetadata != fresh.mediaMetadata)
                            player.replaceMediaItem(
                                index,
                                current.buildUpon().setMediaMetadata(fresh.mediaMetadata).build(),
                            )
                    }
                }
            }
        }
        scope.launch {
            while (isActive) {
                delay(5000)
                if (player.mediaItemCount > 0) persist()
            }
        }
    }

    private fun acceptHandoff(incoming: ExoPlayer, processor: ListeningAudioProcessor) {
        val outgoing = player
        val resume = outgoing.playWhenReady
        try {
            for (index in 0 until outgoing.mediaItemCount) {
                val item = incoming.getMediaItemAt(index)
                val latest = outgoing.getMediaItemAt(index).mediaMetadata
                if (item.mediaMetadata != latest)
                    incoming.replaceMediaItem(
                        index,
                        item.buildUpon().setMediaMetadata(latest).build(),
                    )
            }
            incoming.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                true,
            )
            requireNotNull(session).setPlayer(incoming)
        } catch (error: Exception) {
            if (resume) outgoing.play()
            throw error
        }
        outgoing.removeListener(playbackListener)
        player = incoming
        listeningProcessor = processor
        incoming.addListener(playbackListener)
        effectsSong.value = incoming.currentMediaItem?.mediaId
        revision++
        persist()
    }

    private val playbackListener =
        object : Player.Listener {
            override fun onTimelineChanged(
                timeline: androidx.media3.common.Timeline,
                reason: Int,
            ) {
                if (!applyingRestore) revision++
                graph.setQueue(
                    (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId },
                )
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (
                    !playWhenReady &&
                        reason == Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM &&
                        graph.sleepTimer.value?.songId != null
                )
                    graph.setSleepTimer(null)
            }

            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                effectsSong.value = item?.mediaId
                graph.sleepTimer.value?.let { timer ->
                    if (
                        timer.songId != null &&
                            (timer.songId != item?.mediaId ||
                                timer.occurrenceIndex != player.currentMediaItemIndex)
                    )
                        graph.setSleepTimer(null)
                }
                val loop = graph.loop.value ?: return
                if (
                    item?.mediaId != loop.songId ||
                        reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO ||
                        reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK
                )
                    graph.loop.value = null
            }

            override fun onPlaybackParametersChanged(
                parameters: androidx.media3.common.PlaybackParameters,
            ) {
                val value = SoundSettings(parameters.speed, parameters.pitch)
                if (value.speed in .5f..2f && value.pitch in .5f..2f) graph.setSound(value)
            }

            override fun onEvents(player: Player, events: Player.Events) {
                if (!applyingRestore && !disposed && revision > 0) persist()
            }
        }

    private fun persist() {
        if (disposed || applyingRestore) return
        val ids = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
        val current = player.currentMediaItemIndex.takeIf { it in ids.indices } ?: -1
        snapshots.trySend(
            PlaybackSnapshot(
                ids,
                ids.getOrNull(current),
                player.currentPosition.coerceAtLeast(0),
                player.shuffleModeEnabled,
                when (player.repeatMode) {
                    Player.REPEAT_MODE_ONE -> RepeatMode.ONE
                    Player.REPEAT_MODE_ALL -> RepeatMode.ALL
                    else -> RepeatMode.OFF
                },
                graph.page.value,
                current,
            ),
        )
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? =
        if (controllerInfo.uid == applicationInfo.uid || controllerInfo.isTrusted) session else null

    override fun onDestroy() {
        persist()
        disposed = true
        transitions.close()
        snapshots.close()
        scope.cancel()
        session?.release()
        session = null
        player.release()
        super.onDestroy()
    }

    private inner class LibraryCallback : MediaLibrarySession.Callback {
        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> = result {
            LibraryResult.ofItem(
                MediaItem.Builder()
                    .setMediaId("library")
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle("Sonora")
                            .setIsBrowsable(true)
                            .setIsPlayable(false)
                            .build(),
                    )
                    .build(),
                params,
            )
        }

        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = result {
            if (parentId != "library" || page < 0 || pageSize <= 0 || pageSize > 200)
                LibraryResult.ofError(androidx.media3.session.SessionError.ERROR_BAD_VALUE)
            else
                LibraryResult.ofItemList(
                    graph.store
                        .songs()
                        .drop(
                            (page.toLong() * pageSize).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                        )
                        .take(pageSize)
                        .map { it.mediaItem() },
                    params,
                )
        }

        override fun onAddMediaItems(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: List<MediaItem>,
        ): ListenableFuture<List<MediaItem>> = result {
            mediaItems.map { item ->
                if (item.localConfiguration != null) {
                    require(validLocalAudioUri(item.localConfiguration!!.uri.toString())) {
                        "Solo se admiten archivos de audio locales."
                    }
                    val uri = item.localConfiguration!!.uri
                    val id = item.mediaId.ifEmpty { contentDigest(uri.toString()) }
                    if (graph.store.song(id) == null) {
                        val song =
                            try {
                                graph.reader.read(uri)
                            } catch (_: java.io.FileNotFoundException) {
                                Song(id, uri.toString(), uri.lastPathSegment ?: "Audio")
                            } catch (_: IllegalArgumentException) {
                                Song(id, uri.toString(), uri.lastPathSegment ?: "Audio")
                            }
                        graph.store.saveSongs(listOf(song), inLibrary = false)
                        song.mediaItem()
                    } else item.buildUpon().setMediaId(id).build()
                } else
                    (graph.store.song(item.mediaId) ?: error("La canción ya no está disponible."))
                        .mediaItem()
            }
        }

        private fun <T> result(action: () -> T): ListenableFuture<T> {
            val future = SettableFuture.create<T>()
            scope.launch(Dispatchers.IO) {
                try {
                    future.set(action())
                } catch (error: Exception) {
                    future.setException(error)
                }
            }
            return future
        }
    }
}

fun RepeatMode.media3(): Int =
    when (this) {
        RepeatMode.OFF -> Player.REPEAT_MODE_OFF
        RepeatMode.ALL -> Player.REPEAT_MODE_ALL
        RepeatMode.ONE -> Player.REPEAT_MODE_ONE
    }

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
fun Song.mediaItem(): MediaItem =
    MediaItem.Builder()
        .setMediaId(id)
        .setUri(uri)
        .setClippingConfiguration(
            cueSegment()?.let {
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionUs(it.startUs)
                    .setEndPositionUs(it.endUs ?: C.TIME_END_OF_SOURCE)
                    .build()
            } ?: MediaItem.ClippingConfiguration.UNSET,
        )
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(artist)
                .setAlbumTitle(album)
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setArtworkUri(displayArtworkPath()?.let { Uri.fromFile(File(it)) })
                .build(),
        )
        .build()
