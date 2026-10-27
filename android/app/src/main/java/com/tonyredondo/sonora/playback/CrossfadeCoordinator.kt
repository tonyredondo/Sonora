package com.tonyredondo.sonora

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ShuffleOrder.DefaultShuffleOrder
import kotlinx.coroutines.*

internal data class MixTrack(
    val settings: ListeningSettings,
    val gain: Double,
    val extras: SongExtras,
)

/**
 * Two independent PCM pipelines overlap. The already-playing incoming player becomes the session
 * player, so its intro is heard once and controls retain the full queue and relative position. All
 * player access and ownership changes occur on the service's main looper.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class CrossfadeCoordinator(
    scope: CoroutineScope,
    private val current: () -> ExoPlayer,
    private val settings: () -> TransitionSettings,
    private val listening: () -> ListeningSettings,
    private val blocked: () -> Boolean,
    private val endTimer: () -> Boolean,
    private val prepare: suspend (String) -> MixTrack,
    private val create: (ListeningAudioProcessor) -> ExoPlayer,
    private val handoff: (ExoPlayer, ListeningAudioProcessor) -> Unit,
    private val status: (String) -> Unit,
) : AutoCloseable {
    private val job = SupervisorJob(scope.coroutineContext[Job])
    private val worker = CoroutineScope(scope.coroutineContext + job)
    private var incoming: ExoPlayer? = null
    private var processor: ListeningAudioProcessor? = null
    private var preparing: Job? = null
    private var pair: String? = null
    private var rejected: String? = null
    private var outgoingExtras = SongExtras()
    private var incomingExtras = SongExtras()
    private var startedAt: Long? = null
    private var overlapMs = 0L
    private var pendingPlan: TransitionPlan? = null
    private var observed: ExoPlayer? = null
    private var queueRevision = 0L
    private var queueIdentity =
        emptyList<Triple<String, MediaItem.LocalConfiguration?, MediaItem.ClippingConfiguration>>()
    private val listener =
        object : Player.Listener {
            override fun onPositionDiscontinuity(
                old: Player.PositionInfo,
                new: Player.PositionInfo,
                reason: Int,
            ) {
                if (reason != Player.DISCONTINUITY_REASON_AUTO_TRANSITION) cancel()
            }

            override fun onTimelineChanged(timeline: Timeline, reason: Int) {
                if (reason == Player.TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED) {
                    val value = identity(current())
                    if (value != queueIdentity) {
                        queueIdentity = value
                        queueRevision++
                        rejected = null
                        cancel()
                    }
                }
            }

            override fun onPlayWhenReadyChanged(value: Boolean, reason: Int) {
                if (!value && reason != Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM)
                    incoming?.pause()
            }

            override fun onShuffleModeEnabledChanged(value: Boolean) {
                rejected = null
                cancel()
            }

            override fun onRepeatModeChanged(value: Int) {
                rejected = null
                cancel()
            }
        }

    init {
        observe(current())
        worker.launch {
            while (isActive) {
                try {
                    tick()
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    rejected = pair
                    cancel()
                    status("Continúa sin mezcla: ${error.userMessage()}")
                }
                val player = current()
                val nearEnd =
                    player.isPlaying &&
                        settings().mode != TransitionMode.CONTINUOUS &&
                        player.duration > 0 &&
                        player.duration - player.currentPosition <= settings().seconds * 1000 + 5000
                delay(if (incoming != null || preparing?.isActive == true || nearEnd) 25 else 500)
            }
        }
    }

    private fun observe(player: ExoPlayer) {
        observed?.removeListener(listener)
        observed = player
        queueIdentity = identity(player)
        player.addListener(listener)
    }

    private fun identity(player: ExoPlayer) =
        (0 until player.mediaItemCount).map { index ->
            val item = player.getMediaItemAt(index)
            Triple(item.mediaId, item.localConfiguration, item.clippingConfiguration)
        }

    private fun key(player: ExoPlayer, next: Int): String =
        "${player.currentMediaItemIndex}:$next:$queueRevision:${settings()}:${listening()}"

    private suspend fun tick() {
        val player = current()
        val options = settings()
        if (
            options.mode == TransitionMode.CONTINUOUS ||
                blocked() ||
                player.repeatMode == Player.REPEAT_MODE_ONE ||
                player.playerError != null ||
                player.duration == C.TIME_UNSET ||
                player.duration <= 0
        ) {
            cancel()
            return
        }
        val next = player.nextMediaItemIndex
        if (next == C.INDEX_UNSET || next == player.currentMediaItemIndex) {
            cancel()
            return
        }
        val key = key(player, next)
        if (pair != null && pair != key) cancel()
        if (!player.playWhenReady && startedAt == null) {
            cancel()
            return
        }
        val remaining = player.duration - player.currentPosition
        if (
            pair == null &&
                rejected != key &&
                player.isPlaying &&
                remaining <= options.seconds * 1000 + 5000
        ) {
            pair = key
            val outgoingId = player.currentMediaItem!!.mediaId
            val nextId = player.getMediaItemAt(next).mediaId
            preparing = worker.launch {
                try {
                    val outgoing = prepare(outgoingId)
                    val track = prepare(nextId)
                    ensureActive()
                    if (pair != key || current() !== player) return@launch
                    val effects =
                        ListeningAudioProcessor().apply { apply(track.settings, track.gain) }
                    val standby = create(effects)
                    incoming = standby
                    processor = effects
                    outgoingExtras = outgoing.extras
                    incomingExtras = track.extras
                    standby.volume = 0f
                    standby.playbackParameters = player.playbackParameters
                    standby.setMediaItems(
                        (0 until player.mediaItemCount).map(player::getMediaItemAt),
                        next,
                        0,
                    )
                    val order = mutableListOf<Int>()
                    val timeline = player.currentTimeline
                    var index = timeline.getFirstWindowIndex(true)
                    while (index != C.INDEX_UNSET && order.size < player.mediaItemCount) {
                        order.add(index)
                        index = timeline.getNextWindowIndex(index, Player.REPEAT_MODE_OFF, true)
                    }
                    if (order.size == player.mediaItemCount)
                        standby.setShuffleOrder(DefaultShuffleOrder(order.toIntArray(), 0))
                    standby.shuffleModeEnabled = player.shuffleModeEnabled
                    standby.repeatMode = player.repeatMode
                    standby.pauseAtEndOfMediaItems = true
                    standby.prepare()
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    rejected = key
                    cancel()
                    status("Continúa sin mezcla: ${error.userMessage()}")
                }
            }
        }
        val standby = incoming ?: return
        if (standby.playerError != null) {
            rejected = pair
            cancel()
            status("Continúa sin mezcla: no se pudo preparar la siguiente canción.")
            return
        }
        standby.playbackParameters = player.playbackParameters
        val start = startedAt
        if (start == null) {
            if (remaining < 250 && standby.playbackState != Player.STATE_READY) {
                rejected = pair
                cancel()
                status("Continúa sin mezcla: la siguiente canción no estuvo lista a tiempo.")
                return
            }
            if (
                !player.isPlaying ||
                    standby.playbackState != Player.STATE_READY ||
                    standby.duration <= 0
            )
                return
            val plan =
                pendingPlan
                    ?: TransitionPlanner.plan(
                            options,
                            player.duration / 1000.0,
                            standby.duration / 1000.0,
                            outgoingExtras.bpm,
                            incomingExtras.bpm,
                            outgoingExtras.tailBeat,
                            incomingExtras.headBeat,
                        )
                        .also {
                            pendingPlan = it
                            if (it.incomingSkip > 0)
                                standby.seekTo((it.incomingSkip * 1000).toLong())
                        }
            if (standby.playbackState != Player.STATE_READY) return
            if (remaining > plan.duration * 1000) return
            if (remaining < 250) {
                rejected = pair
                cancel()
                status("Continúa sin mezcla: la siguiente canción no estuvo lista a tiempo.")
                return
            }
            overlapMs = remaining
            startedAt = player.currentPosition
            player.pauseAtEndOfMediaItems = true
            standby.play()
            status(
                if (plan.aligned)
                    "Mezcla alineada${if(plan.estimated) " con pulso estimado" else ""}"
                else if (plan.estimated) "Fundido ajustado al BPM estimado" else "Crossfade",
            )
        } else {
            if ((!player.playWhenReady || !player.isPlaying) && remaining > 60) {
                standby.pause()
                return
            }
            if (player.isPlaying && !standby.playWhenReady) standby.play()
            if (!standby.isPlaying && remaining > 60) {
                rejected = pair
                cancel()
                status("Continúa sin mezcla: se interrumpió la siguiente canción.")
                return
            }
            val progress = ((player.currentPosition - start).toFloat() / overlapMs).coerceIn(0f, 1f)
            player.volume = 1 - progress
            standby.volume = progress
            if (remaining <= 35 || player.playbackState == Player.STATE_ENDED) {
                val effects = requireNotNull(processor)
                observed?.removeListener(listener)
                observed = null
                standby.volume = 1f
                standby.pauseAtEndOfMediaItems = endTimer()
                try {
                    handoff(standby, effects)
                } catch (error: Exception) {
                    observe(current())
                    throw error
                }
                incoming = null
                processor = null
                preparing = null
                pair = null
                startedAt = null
                pendingPlan = null
                rejected = null
                observe(standby)
                player.release()
            }
        }
    }

    fun cancel() {
        val wasMixing = startedAt != null
        preparing?.cancel()
        preparing = null
        incoming?.release()
        incoming = null
        processor = null
        pair = null
        startedAt = null
        pendingPlan = null
        if (wasMixing) {
            val player = current()
            player.volume = 1f
            player.pauseAtEndOfMediaItems = endTimer()
        }
    }

    override fun close() {
        job.cancel()
        observed?.removeListener(listener)
        observed = null
        cancel()
    }
}
