package com.tonyredondo.sonora

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONArray
import org.json.JSONObject

/** Four HTTP workers share validated, language-specific results; paging never submits work. */
class RemotePreparation(private val graph: AppGraph) {
    private data class Work(
        val targets: MutableSet<String>,
        val stage: PreparationStage,
        val path: String,
        val body: JSONObject,
        val settings: OnlineSettings,
        val cacheKey: String,
        val admissionKey: String,
        val document: LyricsDocument? = null,
        val refresh: Boolean = false,
        val sources: MutableMap<String, Song> = mutableMapOf(),
    )

    private var preparationVersion = 0L
    private val versions = mutableMapOf<Pair<String, PreparationStage>, Long>()
    private val suspended = mutableSetOf<Pair<String, PreparationStage>>()
    private val desired = mutableMapOf<Pair<String, PreparationStage>, String>()
    private val pending = mutableMapOf<String, Work>()
    private var currentSettings: OnlineSettings? = null
    private var epoch = 0L
    private val queue = Channel<Work>(8)

    init {
        repeat(4) {
            graph.scope.launch {
                for (work in queue) try {
                    process(work)
                } finally {
                    pending.remove(work.admissionKey)
                }
            }
        }
    }

    fun prepare(ids: List<String>, refresh: Boolean = false, albumScope: Boolean = false) {
        val version = ++preparationVersion
        ids.forEach { id ->
            listOf(PreparationStage.TRANSLATION, PreparationStage.MEANING, PreparationStage.ALBUM)
                .forEach { stage ->
                    suspended.add(id to stage)
                    versions[id to stage] = version
                }
        }
        val settings = graph.online.value
        if (settings !== currentSettings) {
            currentSettings = settings
            epoch++
        }
        val admissionEpoch = epoch
        graph.scope.launch {
            try {
                val (tracks, library) =
                    withContext(Dispatchers.IO) {
                        val tracks = ids.distinct().mapNotNull(graph.store::song)
                        tracks to
                            if (albumScope && tracks.isNotEmpty())
                                graph.store.albumSongs(tracks.first().artist, tracks.first().album)
                            else graph.store.songs()
                    }
                if (graph.online.value !== settings) return@launch
                val queued =
                    withContext(Dispatchers.IO) {
                        graph
                            .queuedSongIds()
                            .filter { id ->
                                id !in graph.songIndex.value && tracks.none { it.id == id }
                            }
                            .mapNotNull(graph.store::song)
                    }
                val all = (library + tracks + queued).distinctBy { it.id }
                val albumGroups = all.groupBy {
                    it.artist.trim().lowercase(java.util.Locale.ROOT) +
                        "\u0000" +
                        it.album.trim().lowercase(java.util.Locale.ROOT)
                }
                val albums = mutableSetOf<String>()
                for (song in tracks) {
                    try {
                        val doc = LyricsDocument.parse(song.lyricsText)
                        if (doc.lines.any { it.text.isNotBlank() }) {
                            submit(
                                listOf(song.id),
                                PreparationStage.TRANSLATION,
                                "v1/lyrics/translate",
                                ProxyContent.translationInput(doc, settings.language),
                                settings,
                                doc,
                                refresh,
                                admissionEpoch,
                                version,
                            )
                            if (graph.character.pending(song.id)) {
                                progress(
                                    listOf(song.id),
                                    PreparationStage.MEANING,
                                    PreparationState.WAITING,
                                    "Esperando el estilo y ambiente de la canción…",
                                )
                            } else
                                submit(
                                    listOf(song.id),
                                    PreparationStage.MEANING,
                                    "v1/lyrics/interpret",
                                    ProxyContent.meaningInput(
                                        song,
                                        graph.extras.value[song.id] ?: SongExtras(),
                                        settings.language,
                                    ),
                                    settings,
                                    null,
                                    refresh,
                                    admissionEpoch,
                                    version,
                                )
                        } else {
                            unavailable(
                                listOf(song.id),
                                PreparationStage.TRANSLATION,
                                "Esta canción todavía no tiene letra.",
                                version,
                            )
                            unavailable(
                                listOf(song.id),
                                PreparationStage.MEANING,
                                "Añade la letra para preparar el significado.",
                                version,
                            )
                        }
                        val albumId =
                            song.artist.trim().lowercase(java.util.Locale.ROOT) +
                                "\u0000" +
                                song.album.trim().lowercase(java.util.Locale.ROOT)
                        if (song.album.isBlank()) {
                            unavailable(
                                listOf(song.id),
                                PreparationStage.ALBUM,
                                "La canción no tiene un álbum indicado.",
                                version,
                            )
                            continue
                        }
                        if (!albums.add(albumId)) continue
                        val initialCorpus = albumGroups[albumId].orEmpty()
                        if (song.id in graph.queuedSongIds()) {
                            val missing = initialCorpus.filter {
                                graph.extras.value[it.id]?.progress?.get(PreparationStage.TAGS) ==
                                    null
                            }
                            if (missing.isNotEmpty()) graph.character.prepare(missing.map { it.id })
                        }
                        var refreshed = initialCorpus
                        val inspected = mutableSetOf<String>()
                        while (true) {
                            val completed = refreshed.filter {
                                it.lyricsText.isBlank() &&
                                    !graph.lyrics.pending(it.id) &&
                                    it.id !in inspected
                            }
                            if (completed.isEmpty()) break
                            inspected.addAll(completed.map { it.id })
                            val latest =
                                withContext(Dispatchers.IO) {
                                    completed.associate { it.id to graph.store.song(it.id) }
                                }
                            refreshed = refreshed.map { latest[it.id] ?: it }
                        }
                        val corpus =
                            refreshed.sortedWith(
                                compareBy<Song> {
                                        if (it.trackNumber > 0) it.trackNumber else Int.MAX_VALUE
                                    }
                                    .thenComparator { a, b -> compareNatural(a.title, b.title) },
                            )
                        if (corpus.any { it.lyricsText.isBlank() && graph.lyrics.pending(it.id) }) {
                            progress(
                                eligible(corpus.map { it.id }, PreparationStage.ALBUM, version),
                                PreparationStage.ALBUM,
                                PreparationState.WAITING,
                                "Buscando las letras del álbum…",
                            )
                            continue
                        }
                        if (corpus.any { graph.character.pending(it.id) }) {
                            progress(
                                eligible(corpus.map { it.id }, PreparationStage.ALBUM, version),
                                PreparationStage.ALBUM,
                                PreparationState.WAITING,
                                "Esperando el estilo y ambiente del álbum…",
                            )
                            continue
                        }
                        if (corpus.none { ProxyContent.lyrics(it).isNotBlank() }) {
                            unavailable(
                                corpus.map { it.id },
                                PreparationStage.ALBUM,
                                "Añade letras de este álbum para preparar su descripción.",
                                version,
                            )
                            continue
                        }
                        require(
                            corpus.size <= 100 &&
                                corpus.sumOf { ProxyContent.lyrics(it).toByteArray().size } <=
                                    262144,
                        ) {
                            "El álbum supera el tamaño permitido para analizarlo."
                        }
                        val album =
                            JSONObject()
                                .put("title", song.album)
                                .put("artist", song.artist)
                                .put(
                                    "tracks",
                                    JSONArray(
                                        corpus.map { track ->
                                            JSONObject()
                                                .put(
                                                    "context",
                                                    ProxyContent.context(
                                                        track,
                                                        graph.extras.value[track.id]
                                                            ?: SongExtras(),
                                                    ),
                                                )
                                                .put("lyrics", ProxyContent.lyrics(track))
                                                .put("genre", track.genre)
                                        },
                                    ),
                                )
                        submit(
                            corpus.map { it.id },
                            PreparationStage.ALBUM,
                            "v1/albums/interpret",
                            JSONObject()
                                .put("album", album)
                                .put("language", settings.language)
                                .put("effort", "medium"),
                            settings,
                            null,
                            refresh,
                            admissionEpoch,
                            version,
                        )
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        progress(
                            listOf(song.id),
                            PreparationStage.MEANING,
                            PreparationState.FAILED,
                            error.userMessage(),
                        )
                    }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                ids.forEach { id ->
                    progress(
                        listOf(id),
                        PreparationStage.MEANING,
                        PreparationState.FAILED,
                        error.userMessage(),
                    )
                }
            }
        }
    }

    private suspend fun submit(
        ids: List<String>,
        stage: PreparationStage,
        path: String,
        body: JSONObject,
        settings: OnlineSettings,
        document: LyricsDocument?,
        refresh: Boolean,
        admissionEpoch: Long,
        version: Long,
    ) {
        val targets = eligible(ids, stage, version)
        if (targets.isEmpty()) return
        val key = remoteCacheKey(settings, path, body)
        targets.forEach { id ->
            versions[id to stage] = version
            if (desired[id to stage] != key) clearContent(id, stage)
            desired[id to stage] = key
            suspended.remove(id to stage)
        }
        val sources =
            withContext(Dispatchers.IO) {
                targets.mapNotNull { id -> graph.store.song(id)?.let { id to it } }.toMap()
            }
        val admissionKey = "$key:$admissionEpoch"
        pending[admissionKey]?.let { existing ->
            existing.targets.addAll(targets)
            existing.sources.putAll(sources)
            return
        }
        progress(targets, stage, PreparationState.WAITING, "Preparación pendiente…")
        val work =
            Work(
                targets.toMutableSet(),
                stage,
                path,
                body,
                settings,
                key,
                admissionKey,
                document,
                refresh,
            )
        work.sources.putAll(sources)
        pending[admissionKey] = work
        queue.send(work)
    }

    private suspend fun process(work: Work) {
        try {
            val cached =
                if (work.refresh) null
                else withContext(Dispatchers.IO) { graph.store.state(work.cacheKey) }
            if (cached != null)
                try {
                    val value = JSONObject(cached)
                    validate(work, value)
                    rememberPortable(work, value)
                    publish(work, value)
                    return
                } catch (_: Exception) {
                    /* A corrupt cache is replaced only after a valid response. */
                }
            if (work.stage != PreparationStage.TRANSLATION && !work.refresh) {
                val portable =
                    withContext(Dispatchers.IO) {
                        work.targets.firstNotNullOfOrNull { id ->
                            graph.store.song(id)?.let {
                                PortableInterpretations.load(
                                    graph.store,
                                    it,
                                    work.settings.language,
                                    work.stage == PreparationStage.ALBUM,
                                    work.body.optJSONObject("album"),
                                )
                            }
                        }
                    }
                if (portable != null) {
                    if (graph.online.value.language == work.settings.language)
                        publishText(work, PortableInterpretations.explanation(portable))
                    return
                }
            }
            if (graph.online.value !== work.settings || currentTargets(work).isEmpty()) return
            if (work.settings.endpoint.isBlank()) throw ProxyFailure("not_configured")
            if (!work.settings.enabled && !work.refresh) throw ProxyFailure("disabled")
            var attempt = 0
            while (true) {
                if (graph.online.value !== work.settings) return
                progress(
                    currentTargets(work),
                    work.stage,
                    PreparationState.RUNNING,
                    when (work.stage) {
                        PreparationStage.TRANSLATION -> "Traduciendo con Codex…"
                        PreparationStage.ALBUM -> "Preparando información del álbum…"
                        else -> "Preparando información de la canción…"
                    },
                )
                try {
                    val body =
                        JSONObject(work.body.toString()).apply {
                            if (work.refresh) put("refresh", true)
                        }
                    val value =
                        ProxyClient(work.settings, transportState = graph.online)
                            .post(work.path, body)
                    validate(work, value)
                    withContext(Dispatchers.IO) {
                        graph.store.putState(work.cacheKey, value.toString())
                    }
                    rememberPortable(work, value)
                    publish(work, value)
                    return
                } catch (error: ProxyFailure) {
                    if (graph.online.value !== work.settings) return
                    if (!error.transient || ++attempt >= 3) throw error
                    progress(
                        currentTargets(work),
                        work.stage,
                        PreparationState.OFFLINE,
                        "Esperando conexión con el servidor. Reintentando…",
                    )
                    delay(if (attempt == 1) 2000 else 8000)
                }
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (error is ProxyFailure && error.code == "connection_changed") {
                progress(
                    currentTargets(work),
                    work.stage,
                    PreparationState.NEEDS_CONNECTION,
                    "La conexión ha cambiado. Recupera este contenido con el servidor actual.",
                )
                return
            }
            if (graph.online.value === work.settings)
                progress(
                    currentTargets(work),
                    work.stage,
                    when ((error as? ProxyFailure)?.code) {
                        "not_configured" -> PreparationState.NEEDS_CONNECTION
                        "offline",
                        "disabled" -> PreparationState.OFFLINE
                        else -> PreparationState.FAILED
                    },
                    error.userMessage(),
                )
        }
    }

    private suspend fun rememberPortable(work: Work, value: JSONObject) {
        if (work.stage == PreparationStage.TRANSLATION) return
        withContext(Dispatchers.IO) {
            // Keep the exact request inputs. A late response must never acquire edited lyrics.
            val current = work.sources.mapValues { (id, _) -> graph.store.song(id) }
            if (
                work.sources.any { (id, source) ->
                    current[id]?.let {
                        it.title != source.title ||
                            it.artist != source.artist ||
                            it.album != source.album ||
                            it.lyricsText != source.lyricsText
                    } != false
                }
            )
                return@withContext
            work.sources.values.forEach {
                PortableInterpretations.remember(
                    graph.store,
                    it,
                    work.settings.language,
                    work.stage == PreparationStage.ALBUM,
                    value,
                    work.body.optJSONObject("album"),
                )
            }
        }
    }

    private fun validate(work: Work, value: JSONObject) {
        if (work.stage == PreparationStage.TRANSLATION)
            ProxyContent.translation(value, requireNotNull(work.document))
        else ProxyContent.interpretation(value)
    }

    private fun publishText(work: Work, text: String) {
        currentTargets(work).forEach { id ->
            val old = graph.extras.value[id] ?: SongExtras()
            val content =
                if (work.stage == PreparationStage.ALBUM) old.copy(albumMeaning = text)
                else old.copy(meaning = text)
            graph.extras.value =
                graph.extras.value +
                    (id to
                        content.copy(
                            progress =
                                content.progress +
                                    (work.stage to PreparationProgress(PreparationState.READY)),
                        ))
        }
    }

    private fun publish(work: Work, value: JSONObject) {
        validate(work, value)
        val settings = graph.online.value
        if (
            settings.language != work.settings.language ||
                settings.baseUrl() != work.settings.baseUrl()
        )
            return
        currentTargets(work).forEach { id ->
            val old = graph.extras.value[id] ?: SongExtras()
            val content =
                when (work.stage) {
                    PreparationStage.TRANSLATION ->
                        old.copy(
                            translation =
                                ProxyContent.translation(value, requireNotNull(work.document)),
                        )
                    PreparationStage.ALBUM ->
                        old.copy(albumMeaning = ProxyContent.interpretation(value))
                    else -> old.copy(meaning = ProxyContent.interpretation(value))
                }
            graph.extras.value =
                graph.extras.value +
                    (id to
                        content.copy(
                            progress =
                                content.progress +
                                    (work.stage to PreparationProgress(PreparationState.READY)),
                        ))
        }
    }

    private fun unavailable(
        ids: List<String>,
        stage: PreparationStage,
        message: String,
        version: Long,
    ) {
        val targets = eligible(ids, stage, version)
        targets.forEach {
            desired.remove(it to stage)
            suspended.remove(it to stage)
            clearContent(it, stage)
        }
        progress(targets, stage, PreparationState.UNAVAILABLE, message)
    }

    private fun currentTargets(work: Work): List<String> =
        work.targets.filter {
            (it to work.stage) !in suspended && desired[it to work.stage] == work.cacheKey
        }

    private fun eligible(ids: List<String>, stage: PreparationStage, version: Long): List<String> =
        ids.filter {
            (versions[it to stage] ?: 0) <= version
        }

    private fun clearContent(id: String, stage: PreparationStage) {
        val old = graph.extras.value[id] ?: return
        val changed =
            when (stage) {
                PreparationStage.TRANSLATION -> old.copy(translation = emptyMap())
                PreparationStage.ALBUM -> old.copy(albumMeaning = null)
                else -> old.copy(meaning = null)
            }
        graph.extras.value = graph.extras.value + (id to changed)
    }

    private fun progress(
        ids: Collection<String>,
        stage: PreparationStage,
        state: PreparationState,
        message: String,
    ) {
        val changed = graph.extras.value.toMutableMap()
        ids.forEach { id ->
            val old = changed[id] ?: SongExtras()
            changed[id] =
                old.copy(progress = old.progress + (stage to PreparationProgress(state, message)))
        }
        graph.extras.value = changed
    }
}

fun remoteCacheKey(settings: OnlineSettings, path: String, body: JSONObject): String =
    "remote:v1:$path:${settings.language}:" +
        contentDigest(settings.baseUrl()?.toString().orEmpty() + "\n" + body.toString())
