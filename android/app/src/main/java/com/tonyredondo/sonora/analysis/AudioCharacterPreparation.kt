package com.tonyredondo.sonora

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject

/** The server owns one local tagging model; client uploads remain bounded and reuse sampled PCM. */
class AudioCharacterPreparation(private val graph: AppGraph) {
    private data class Work(
        val song: Song,
        val settings: OnlineSettings,
        val key: String,
        val refresh: Boolean,
    )

    private val desired = mutableMapOf<String, String>()
    private val pending = mutableSetOf<String>()
    private val queue = Channel<Work>(8)

    init {
        repeat(4) {
            graph.scope.launch {
                for (work in queue) try {
                    process(work)
                } finally {
                    pending.remove(work.key)
                    if (!graph.online.value.sameTransport(work.settings))
                        prepare(listOf(work.song.id))
                }
            }
        }
    }

    fun pending(id: String): Boolean =
        graph.extras.value[id]?.progress?.get(PreparationStage.TAGS)?.state in
            setOf(PreparationState.WAITING, PreparationState.RUNNING)

    fun prepare(ids: List<String>, refresh: Boolean = false) {
        ids.distinct().forEach {
            setProgress(it, PreparationState.WAITING, "Preparando estilo y ambiente…")
        }
        val settings = graph.online.value
        graph.scope.launch {
            for (id in ids.distinct()) try {
                val song = withContext(Dispatchers.IO) { graph.store.song(id) } ?: continue
                val key =
                    "character-v1:" +
                        contentDigest("${settings.endpoint.trimEnd('/')}|${audioSourceKey(song)}")
                desired[id] = key
                if (!pending.add(key)) continue
                queue.send(Work(song, settings, key, refresh))
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                setProgress(id, PreparationState.FAILED, error.userMessage())
            }
        }
    }

    private suspend fun process(work: Work) {
        val id = work.song.id
        try {
            val cached =
                if (work.refresh) null
                else withContext(Dispatchers.IO) { graph.store.state(work.key) }
            if (cached != null)
                try {
                    publish(work, AudioCharacter.parse(JSONObject(cached)))
                    return
                } catch (_: ProxyFailure) {
                    /* Preserve it until a valid replacement exists. */
                }
            if (work.settings.endpoint.trimEnd('/') != graph.online.value.endpoint.trimEnd('/'))
                return
            if (work.settings.endpoint.isBlank() || !work.settings.enabled) {
                setProgress(
                    id,
                    PreparationState.NEEDS_CONNECTION,
                    "Configura el servidor para analizar estilo y ambiente.",
                )
                return
            }
            val audio =
                withContext(Dispatchers.IO) { AudioPreviewStore(graph.application).read(work.song) }
            if (audio == null) {
                val audioState =
                    graph.extras.value[id]?.progress?.get(PreparationStage.AUDIO)?.state
                if (audioState == PreparationState.FAILED || audioState == PreparationState.READY) {
                    setProgress(
                        id,
                        PreparationState.UNAVAILABLE,
                        "No hay una muestra de audio suficiente para analizar el estilo.",
                    )
                } else {
                    setProgress(id, PreparationState.WAITING, "Esperando el análisis de audio…")
                    if (!graph.preparation.pending(id)) graph.preparation.prepare(listOf(id))
                }
                return
            }
            setProgress(id, PreparationState.RUNNING, "Analizando estilo y ambiente…")
            val client = ProxyClient(work.settings, transportState = graph.online)
            var response: JSONObject? = null
            for (attempt in 0..2) try {
                response = client.audioCharacter(audio, work.refresh)
                break
            } catch (failure: ProxyFailure) {
                if (!failure.transient || attempt == 2) throw failure
                delay(if (attempt == 0) 2000 else 8000)
            }
            val value = requireNotNull(response)
            val character = AudioCharacter.parse(value)
            withContext(Dispatchers.IO) { graph.store.putState(work.key, value.toString()) }
            publish(work, character)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (desired[id] == work.key)
                setProgress(
                    id,
                    if (error is ProxyFailure && error.code == "offline") PreparationState.OFFLINE
                    else PreparationState.FAILED,
                    error.userMessage(),
                )
        } finally {
            if (!pending(id)) {
                val queued = graph.queuedSongIds()
                val affected =
                    if (id in queued) listOf(id)
                    else
                        withContext(Dispatchers.IO) {
                            queued.filter { target ->
                                graph.store.song(target)?.let {
                                    it.album.isNotBlank() &&
                                        it.album.equals(work.song.album, true) &&
                                        it.artist.equals(work.song.artist, true)
                                } == true
                            }
                        }
                if (affected.isNotEmpty()) graph.remote.prepare(affected, albumScope = true)
            }
        }
    }

    private fun publish(work: Work, value: AudioCharacter) {
        if (desired[work.song.id] != work.key) return
        val id = work.song.id
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        character = value,
                        styles = value.styles.take(2).map { it.label },
                        moods = value.prominentMoods,
                        progress =
                            old.progress +
                                (PreparationStage.TAGS to
                                    PreparationProgress(PreparationState.READY)),
                    ))
    }

    private fun setProgress(id: String, state: PreparationState, message: String) {
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        progress =
                            old.progress +
                                (PreparationStage.TAGS to PreparationProgress(state, message)),
                    ))
    }
}
