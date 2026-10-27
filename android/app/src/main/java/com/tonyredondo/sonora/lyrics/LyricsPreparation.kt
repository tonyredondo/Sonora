package com.tonyredondo.sonora

import kotlin.math.abs
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject

/** Missing lyrics are looked up before the complete album corpus is interpreted. */
class LyricsPreparation(private val graph: AppGraph) {
    private val queued = mutableSetOf<String>()
    private val work = Channel<String>(Channel.UNLIMITED)

    init {
        graph.scope.launch {
            for (id in work) {
                val transport = graph.online.value
                var affectsAlbum = false
                try {
                    val song = withContext(Dispatchers.IO) { graph.store.song(id) }
                    if (song?.hasLyricsOverride() == true) {
                        progress(
                            id,
                            if (song.lyricsText.isBlank()) PreparationState.UNAVAILABLE
                            else PreparationState.READY,
                            if (song.lyricsText.isBlank())
                                "Esta canción tiene una letra vacía guardada por ti."
                            else "",
                        )
                    } else if (song != null && song.lyricsText.isBlank()) {
                        affectsAlbum = true
                        lookup(song)
                    }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    progress(id, PreparationState.FAILED, error.userMessage())
                } finally {
                    queued.remove(id)
                    if (!graph.online.value.sameTransport(transport)) prepare(listOf(id))
                    if (affectsAlbum) graph.remote.prepare(listOf(id), albumScope = true)
                }
            }
        }
    }

    fun pending(id: String): Boolean = id in queued

    fun prepare(ids: List<String>) {
        ids.distinct()
            .filter { graph.songIndex.value[it]?.lyricsText.isNullOrBlank() }
            .forEach { if (queued.add(it)) work.trySend(it) }
    }

    private suspend fun lookup(song: Song) {
        val id = song.id
        try {
            if (song.artist.isBlank() || song.album.isBlank() || song.durationMs < 1000) {
                progress(
                    id,
                    PreparationState.UNAVAILABLE,
                    "Faltan datos de artista, álbum o duración para buscar la letra.",
                )
                return
            }
            val settings = graph.online.value
            val key =
                "lyrics:lrclib-v1:" +
                    contentDigest(
                        listOf(
                                settings.baseUrl()?.toString().orEmpty(),
                                song.title,
                                song.artist,
                                song.album,
                                (song.durationMs / 1000).toString(),
                            )
                            .joinToString("\n"),
                    )
            val cached =
                withContext(Dispatchers.IO) { graph.store.state(key) }
                    ?.let {
                        try {
                            JSONObject(it)
                        } catch (_: Exception) {
                            null
                        }
                    }
            if (
                cached?.optBoolean("missing") == true &&
                    cached.optLong("expires") > System.currentTimeMillis()
            ) {
                progress(
                    id,
                    PreparationState.UNAVAILABLE,
                    "No se ha encontrado una letra para esta canción.",
                )
                return
            }
            var value = cached?.optJSONObject("data")
            if (value == null) {
                if (!settings.enabled || settings.endpoint.isBlank()) {
                    progress(
                        id,
                        PreparationState.NEEDS_CONNECTION,
                        "Configura el servidor para buscar la letra.",
                    )
                    return
                }
                progress(id, PreparationState.RUNNING, "Buscando letra…")
                var attempt = 0
                while (true) {
                    if (graph.online.value !== settings) return
                    try {
                        value =
                            ProxyClient(settings, transportState = graph.online)
                                .get(
                                    "v1/lyrics",
                                    mapOf(
                                        "title" to song.title,
                                        "artist" to song.artist,
                                        "album" to song.album,
                                        "duration" to (song.durationMs / 1000).toString(),
                                    ),
                                )
                                .getJSONObject("data")
                        break
                    } catch (error: ProxyFailure) {
                        if (error.status == 404) {
                            withContext(Dispatchers.IO) {
                                graph.store.putState(
                                    key,
                                    JSONObject()
                                        .put("missing", true)
                                        .put("expires", System.currentTimeMillis() + 300000)
                                        .toString(),
                                )
                            }
                            progress(
                                id,
                                PreparationState.UNAVAILABLE,
                                "No se ha encontrado una letra para esta canción.",
                            )
                            return
                        }
                        if (!error.transient || ++attempt >= 3) throw error
                        progress(
                            id,
                            PreparationState.OFFLINE,
                            "Esperando conexión para buscar la letra…",
                        )
                        delay(if (attempt == 1) 2000 else 8000)
                    }
                }
            }
            val response = requireNotNull(value)
            require(
                response.optString("trackName").equals(song.title, true) &&
                    response.optString("artistName").equals(song.artist, true) &&
                    response.optString("albumName").equals(song.album, true) &&
                    abs(response.optDouble("duration", Double.NaN) - song.durationMs / 1000.0) <= 3,
            ) {
                "La letra encontrada no corresponde a esta canción."
            }
            val text =
                (response.opt("syncedLyrics") as? String)?.takeIf {
                    LyricsDocument.parse(it).isTimed
                } ?: (response.opt("plainLyrics") as? String).orEmpty()
            require(text.toByteArray().size <= 1_000_000) {
                "La letra encontrada es demasiado grande."
            }
            if (text.isBlank()) {
                progress(
                    id,
                    PreparationState.UNAVAILABLE,
                    if (response.optBoolean("instrumental"))
                        "La canción está identificada como instrumental."
                    else "No se ha encontrado una letra.",
                )
                return
            }
            withContext(Dispatchers.IO) {
                graph.store.putState(key, JSONObject().put("data", response).toString())
                val current = graph.store.song(id) ?: return@withContext
                // A lookup never overwrites edits made while its request was in flight.
                if (
                    current.lyricsText.isBlank() &&
                        current.title == song.title &&
                        current.artist == song.artist &&
                        current.album == song.album
                ) {
                    val metadata = JSONObject(current.metadata).put("lyricsSource", "LRCLIB")
                    graph.store.saveSongs(
                        listOf(current.copy(lyricsText = text, metadata = metadata.toString())),
                        inLibrary = false,
                    )
                }
            }
            graph.refresh()
            progress(id, PreparationState.READY, "")
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            progress(id, PreparationState.FAILED, error.userMessage())
        }
    }

    private fun progress(id: String, state: PreparationState, message: String) {
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        progress =
                            old.progress +
                                (PreparationStage.LYRICS to PreparationProgress(state, message)),
                    ))
    }
}
