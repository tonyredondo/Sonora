package com.tonyredondo.sonora

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONArray
import org.json.JSONObject

/** Queue changes never discard completed work. Only the decoder is serialized. */
class PreparationEngine(private val graph: AppGraph) {
    private val pending = mutableMapOf<String, Boolean>()
    private val work = Channel<Pair<String, Boolean>>(Channel.UNLIMITED)

    init {
        graph.scope.launch {
            for ((id, refresh) in work) {
                var stale = false
                try {
                    stale = analyze(id, refresh)
                } finally {
                    val notify = pending.remove(id) == true
                    if (stale) prepare(listOf(id), notifyCharacter = notify)
                    else if (notify) graph.character.prepare(listOf(id))
                }
            }
        }
    }

    fun prepare(songIds: List<String>, refresh: Boolean = false, notifyCharacter: Boolean = true) {
        songIds.distinct().forEach { id ->
            val exists = pending.containsKey(id)
            pending[id] = pending[id] == true || notifyCharacter
            if (!exists) {
                setProgress(
                    id,
                    PreparationProgress(PreparationState.WAITING, "Análisis pendiente…"),
                )
                work.trySend(id to refresh)
            }
        }
    }

    fun pending(id: String): Boolean = pending.containsKey(id)

    private suspend fun analyze(id: String, refresh: Boolean): Boolean {
        var source: String? = null
        try {
            val song = withContext(Dispatchers.IO) { graph.store.song(id) } ?: return false
            source = audioSourceKey(song)
            val key = "audio:rms-volume-v3:" + source
            setProgress(id, PreparationProgress(PreparationState.RUNNING, "Analizando audio…"))
            val cached =
                if (refresh) null
                else withContext(Dispatchers.IO) { graph.store.state(key) }?.let(::decode)
            val result =
                cached
                    ?: withContext(Dispatchers.Default) {
                            LocalAudioAnalyzer(graph.application).analyze(song)
                        }
                        .also { value ->
                            withContext(Dispatchers.IO) {
                                value.characterWav?.let {
                                    AudioPreviewStore(graph.application).write(song, it)
                                }
                                graph.store.putState(key, encode(value))
                            }
                        }
            val latest = withContext(Dispatchers.IO) { graph.store.song(id) } ?: return false
            if (audioSourceKey(latest) != source) return true
            val old = graph.extras.value[id] ?: SongExtras()
            graph.extras.value =
                graph.extras.value +
                    (id to
                        old.copy(
                            bpm = result.bpm,
                            headBeat = result.headBeat,
                            tailBeat = result.tailBeat,
                            waveform = result.waveform,
                            volume = result.volume,
                            volumeSupported = result.volumeSupported,
                            audioSource = source,
                            progress =
                                old.progress +
                                    (PreparationStage.AUDIO to
                                        PreparationProgress(PreparationState.READY)),
                        ))
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            setProgress(
                id,
                PreparationProgress(PreparationState.FAILED, error.userMessage()),
                source,
            )
        }
        return false
    }

    private fun setProgress(id: String, value: PreparationProgress, source: String? = null) {
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        audioSource = source ?: old.audioSource,
                        progress = old.progress + (PreparationStage.AUDIO to value),
                    ))
    }

    private fun encode(value: AudioAnalysis): String =
        JSONObject()
            .put("bpm", value.bpm ?: JSONObject.NULL)
            .put("head_beat", value.headBeat?.encode())
            .put("tail_beat", value.tailBeat?.encode())
            .put("waveform", JSONArray(value.waveform))
            .put("volume", value.volume?.encode() ?: JSONObject.NULL)
            .put("volume_supported", value.volumeSupported)
            .toString()

    private fun decode(text: String): AudioAnalysis? =
        try {
            val value = JSONObject(text)
            val wave = value.getJSONArray("waveform")
            require(wave.length() == 512)
            val levels =
                (0 until wave.length()).map {
                    wave.getDouble(it).toFloat().also { sample ->
                        require(sample.isFinite() && sample in 0f..1f)
                    }
                }
            val bpm =
                if (value.isNull("bpm")) null
                else value.getDouble("bpm").also { require(it.isFinite() && it in 40.0..170.0) }
            AudioAnalysis(
                bpm,
                levels,
                volume =
                    if (value.isNull("volume")) null
                    else VolumeMeasurement.decode(value.getString("volume")),
                volumeSupported = value.getBoolean("volume_supported"),
                headBeat = value.optJSONObject("head_beat")?.let(BeatGrid::decode),
                tailBeat = value.optJSONObject("tail_beat")?.let(BeatGrid::decode),
            )
        } catch (_: Exception) {
            null
        }
}
