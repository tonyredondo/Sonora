package com.tonyredondo.sonora

import android.graphics.BitmapFactory
import android.util.AtomicFile
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Square covers are durable display metadata. Embedded art and source audio are never rewritten.
 */
class GeneratedArtworkPreparation(
    private val graph: AppGraph,
    private val scope: CoroutineScope = graph.scope,
    private val pollMillis: Long = 2000,
) {
    private data class Work(
        val song: Song,
        val settings: OnlineSettings,
        val body: JSONObject,
        val key: String,
        val retryFailed: Boolean,
        val targets: MutableSet<String>,
    )

    private val queue = Channel<Work>(8)
    private val pending = mutableMapOf<String, Work>()
    private val desired = mutableMapOf<String, String>()
    private val terminal = mutableSetOf<String>()
    private val root = File(graph.application.filesDir, "generated-artwork-v1")

    init {
        repeat(4) {
            scope.launch {
                for (work in queue) try {
                    for (attempt in 0..2) try {
                        process(work)
                        break
                    } catch (failure: ProxyFailure) {
                        if (!failure.transient || attempt == 2) throw failure
                        delay(if (attempt == 0) 2000 else 8000)
                    }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    terminal.add(work.key)
                    progress(
                        work,
                        if (error is ProxyFailure && error.code == "offline")
                            PreparationState.OFFLINE
                        else PreparationState.FAILED,
                        error.userMessage(),
                    )
                } finally {
                    pending.remove(work.key)
                    if (!graph.online.value.sameTransport(work.settings)) {
                        terminal.remove(work.key)
                        prepare(work.targets.toList())
                    }
                }
            }
        }
    }

    fun prepare(ids: List<String>, retryFailed: Boolean = false) {
        val settings = graph.online.value
        scope.launch {
            for (id in ids.distinct()) try {
                val song = withContext(Dispatchers.IO) { graph.store.song(id) } ?: continue
                if (song.artworkPath != null) continue
                val saved = song.displayArtworkPath()
                if (saved != null && withContext(Dispatchers.IO) { File(saved).isFile }) {
                    publish(id, saved)
                    continue
                }
                val extras = graph.extras.value[id] ?: SongExtras()
                if (
                    graph.character.pending(id) ||
                        extras.progress[PreparationStage.ALBUM]?.state in
                            setOf(PreparationState.WAITING, PreparationState.RUNNING)
                ) {
                    progress(
                        id,
                        PreparationState.WAITING,
                        "Esperando la información del álbum para crear la portada…",
                    )
                    continue
                }
                if (song.album.isNotBlank() && extras.progress[PreparationStage.ALBUM] == null) {
                    progress(id, PreparationState.WAITING, "Preparando el contexto del álbum…")
                    continue
                }
                if (!settings.enabled || settings.endpoint.isBlank()) {
                    progress(
                        id,
                        PreparationState.NEEDS_CONNECTION,
                        "Configura el servidor para crear la portada.",
                    )
                    continue
                }
                val body =
                    JSONObject()
                        .put("title", song.title)
                        .put("artist", song.artist)
                        .put("album", song.album)
                        .put("album_description", extras.albumMeaning ?: extras.meaning.orEmpty())
                        .put("genre", song.genre)
                        .put("styles", JSONArray(extras.styles))
                        .put("moods", JSONArray(extras.moods))
                val key = contentDigest("artwork-v2|${settings.endpoint.trimEnd('/')}|$body")
                desired[id] = key
                if (retryFailed) terminal.remove(key)
                if (key in terminal) continue
                val shared = pending[key]
                if (shared != null) shared.targets.add(id)
                else {
                    val work = Work(song, settings, body, key, retryFailed, mutableSetOf(id))
                    pending[key] = work
                    queue.send(work)
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                progress(id, PreparationState.FAILED, error.userMessage())
            }
        }
    }

    fun resume(ids: List<String>) {
        terminal.clear()
        prepare(ids)
    }

    private suspend fun process(work: Work, recoverMissing: Boolean = true) {
        val receipt = withContext(Dispatchers.IO) { readReceipt(work.key) }
        val image = File(root, "${work.key}.png")
        val digest = receipt.optString("sha256")
        if (
            digest.isNotBlank() &&
                withContext(Dispatchers.IO) {
                    image.isFile && contentDigest(image.readBytes()) == digest
                }
        ) {
            saveBinding(work, image.path)
            return
        }
        val client = ProxyClient(work.settings, transportState = graph.online)
        var id = receipt.optString("id")
        if (id.isEmpty() || work.retryFailed) {
            progress(work, PreparationState.RUNNING, "Solicitando portada…")
            val created =
                client.post(
                    "v1/artwork/jobs" + (if (work.retryFailed) "?retry_failed=true" else ""),
                    work.body,
                )
            id = created.optString("id")
            if (!id.matches(Regex("[a-f0-9]{64}"))) throw ProxyFailure("invalid_response")
            receipt.put("id", id)
            withContext(Dispatchers.IO) {
                write(File(root, "${work.key}.json"), receipt.toString().toByteArray())
            }
        }
        if (!id.matches(Regex("[a-f0-9]{64}"))) throw ProxyFailure("invalid_response")
        val path = "v1/artwork/jobs/$id"
        val deadline = android.os.SystemClock.elapsedRealtime() + 12 * 60 * 1000
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            val job =
                try {
                    client.get(path, emptyMap())
                } catch (failure: ProxyFailure) {
                    if (
                        recoverMissing &&
                            failure.code == "artwork_job_not_found" &&
                            failure.status == 404
                    ) {
                        receipt.remove("id")
                        receipt.remove("sha256")
                        withContext(Dispatchers.IO) {
                            write(File(root, "${work.key}.json"), receipt.toString().toByteArray())
                        }
                        process(work, recoverMissing = false)
                        return
                    }
                    throw failure
                }
            if (job.optString("id") != id) throw ProxyFailure("invalid_response")
            when (job.optString("state")) {
                "completed" -> {
                    progress(work, PreparationState.RUNNING, "Descargando portada…")
                    val response = client.image("$path/image", requireDigest = false)
                    withContext(Dispatchers.IO) {
                        validate(response.bytes)
                        write(image, response.bytes)
                        receipt.put("sha256", response.sha256)
                        write(File(root, "${work.key}.json"), receipt.toString().toByteArray())
                    }
                    saveBinding(work, image.path)
                    return
                }
                "queued" ->
                    progress(
                        work.song.id,
                        PreparationState.WAITING,
                        "Portada en espera en el servidor…",
                    )
                "running" -> progress(work, PreparationState.RUNNING, "Creando portada…")
                "failed" -> throw ProxyFailure(job.optString("error", "codex_unavailable"))
                else -> throw ProxyFailure("invalid_response")
            }
            delay(pollMillis)
        }
        progress(
            work.song.id,
            PreparationState.WAITING,
            "La portada sigue preparándose en el servidor.",
        )
    }

    private suspend fun saveBinding(work: Work, path: String) {
        val ids = work.targets.filter { desired[it] == work.key }
        withContext(Dispatchers.IO) {
            ids.forEach { id ->
                if (graph.store.song(id)?.artworkPath == null)
                    graph.store.setGeneratedArtwork(id, path, work.key)
            }
        }
        graph.refresh()
        ids.forEach { publish(it, path) }
        graph.panorama.prepare(ids)
    }

    private fun progress(work: Work, state: PreparationState, message: String) {
        work.targets.filter { desired[it] == work.key }.forEach { progress(it, state, message) }
    }

    private fun publish(id: String, path: String) {
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        generatedArtwork = path,
                        progress =
                            old.progress +
                                (PreparationStage.ARTWORK to
                                    PreparationProgress(PreparationState.READY)),
                    ))
    }

    private fun progress(id: String, state: PreparationState, message: String) {
        val old = graph.extras.value[id] ?: SongExtras()
        graph.extras.value =
            graph.extras.value +
                (id to
                    old.copy(
                        progress =
                            old.progress +
                                (PreparationStage.ARTWORK to PreparationProgress(state, message)),
                    ))
    }

    private fun readReceipt(key: String): JSONObject =
        try {
            AtomicFile(File(root, "$key.json")).openRead().use {
                val bytes = it.readBytes()
                check(bytes.size <= 4096)
                JSONObject(String(bytes, Charsets.UTF_8))
            }
        } catch (_: java.io.FileNotFoundException) {
            JSONObject()
        }

    private fun write(file: File, bytes: ByteArray) {
        check(root.isDirectory || root.mkdirs()) { "No se pudo guardar la portada." }
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            output.write(bytes)
            atomic.finishWrite(output)
        } catch (error: Exception) {
            atomic.failWrite(output)
            throw error
        }
    }

    private fun validate(bytes: ByteArray) {
        if (
            bytes.size !in 45..10_000_000 ||
                !bytes
                    .take(8)
                    .toByteArray()
                    .contentEquals(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10))
        )
            throw ProxyFailure("invalid_response")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth !in 1..2048 || bounds.outWidth != bounds.outHeight)
            throw ProxyFailure("invalid_response")
        val bitmap =
            BitmapFactory.decodeByteArray(
                bytes,
                0,
                bytes.size,
                BitmapFactory.Options().apply { inSampleSize = 4 },
            ) ?: throw ProxyFailure("invalid_response")
        bitmap.recycle()
    }
}
