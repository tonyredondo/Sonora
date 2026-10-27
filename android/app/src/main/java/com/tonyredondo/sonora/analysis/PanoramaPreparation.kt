package com.tonyredondo.sonora

import android.graphics.BitmapFactory
import android.util.AtomicFile
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import org.json.JSONObject

/**
 * Durable local receipts are written before polling; a server result is acknowledged only after
 * fsync.
 */
class PanoramaPreparation(
    private val graph: AppGraph,
    private val scope: CoroutineScope = graph.scope,
    private val pollMillis: Long = 2000,
) {
    private data class Work(
        val key: String,
        val sourcePath: String,
        val sourceSha: String,
        val aspect: String,
        val settings: OnlineSettings,
        val targets: MutableSet<String>,
    )

    private var aspect: String? = null
    private val desired = mutableMapOf<String, String>()
    private val pending = mutableMapOf<String, Work>()
    private val queue = Channel<Work>(8)
    private val admission = kotlinx.coroutines.sync.Mutex()
    private val directory = File(graph.application.filesDir, "panoramas-v1")

    init {
        repeat(4) {
            scope.launch {
                for (work in queue) try {
                    for (attempt in 0..2) {
                        try {
                            process(work)
                            break
                        } catch (failure: ProxyFailure) {
                            if (!failure.transient || attempt == 2) throw failure
                            publish(
                                work,
                                PreparationState.WAITING,
                                "Esperando conexión para recuperar la portada…",
                            )
                            delay(if (attempt == 0) 2000 else 8000)
                        }
                    }
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    val offline = error is ProxyFailure && error.code == "offline"
                    publish(
                        work,
                        if (offline) PreparationState.OFFLINE else PreparationState.FAILED,
                        error.userMessage(),
                    )
                } finally {
                    pending.remove(work.key)
                    if (!graph.online.value.sameTransport(work.settings))
                        prepare(work.targets.toList())
                }
            }
        }
    }

    fun setViewport(width: Int, height: Int) {
        if (width <= height || height <= 0) return
        val ratio = width.toDouble() / height
        setAspect(
            when {
                ratio <= 16.0 / 9 -> "16:9"
                ratio <= 2 -> "2:1"
                ratio <= 2.25 -> "9:4"
                ratio <= 8.0 / 3 -> "8:3"
                else -> "3:1"
            },
        )
    }

    fun setAspect(value: String) {
        require(value in listOf("16:9", "2:1", "9:4", "8:3", "3:1"))
        if (aspect == value) return
        aspect = value
        desired.clear()
        graph.extras.value =
            graph.extras.value.mapValues { (_, extra) -> extra.copy(panorama = null) }
        prepare(graph.queuedSongIds())
    }

    fun prepare(ids: List<String>) {
        val targetAspect = aspect ?: return
        val settings = graph.online.value
        scope.launch {
            admission.lock()
            try {
                for (id in ids.distinct()) {
                    try {
                        val input =
                            withContext(Dispatchers.IO) {
                                val song = graph.store.song(id) ?: return@withContext null
                                val path =
                                    song.displayArtworkPath()
                                        ?: graph.extras.value[id]?.generatedArtwork
                                        ?: return@withContext null
                                val file = File(path)
                                require(file.length() in 1..10_000_000) {
                                    "La portada no tiene un tamaño válido para ampliarla."
                                }
                                val bytes = file.readBytes()
                                val bounds =
                                    BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                                require(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048) {
                                    "La portada tiene una resolución no admitida para ampliarla."
                                }
                                path to contentDigest(bytes)
                            } ?: continue
                        if (aspect != targetAspect || graph.online.value !== settings) return@launch
                        val key =
                            withContext(Dispatchers.IO) {
                                contentDigest(
                                    "panorama-v1\n${settings.endpoint.trimEnd('/')}\n$targetAspect\n${input.second}",
                                )
                            }
                        desired[id] = key
                        val shared = pending[key]
                        if (shared != null) {
                            shared.targets.add(id)
                            continue
                        }
                        val work =
                            Work(
                                key,
                                input.first,
                                input.second,
                                targetAspect,
                                settings,
                                mutableSetOf(id),
                            )
                        pending[key] = work
                        publish(work, PreparationState.WAITING, "Portada panorámica pendiente…")
                        queue.send(work)
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                        graph.extras.value =
                            graph.extras.value.toMutableMap().apply {
                                val old = get(id) ?: SongExtras()
                                put(
                                    id,
                                    old.copy(
                                        progress =
                                            old.progress +
                                                (PreparationStage.PANORAMA to
                                                    PreparationProgress(
                                                        PreparationState.FAILED,
                                                        error.userMessage(),
                                                    )),
                                    ),
                                )
                            }
                    }
                }
            } finally {
                admission.unlock()
            }
        }
    }

    private fun publish(
        work: Work,
        state: PreparationState,
        message: String = "",
        path: String? = null,
    ) {
        graph.extras.value =
            graph.extras.value.toMutableMap().apply {
                work.targets
                    .filter { desired[it] == work.key }
                    .forEach { id ->
                        val old = get(id) ?: SongExtras()
                        put(
                            id,
                            old.copy(
                                panorama = path ?: old.panorama,
                                progress =
                                    old.progress +
                                        (PreparationStage.PANORAMA to
                                            PreparationProgress(state, message)),
                            ),
                        )
                    }
            }
    }

    private suspend fun process(work: Work, recoverMissing: Boolean = true) {
        val receipt = withContext(Dispatchers.IO) { readReceipt(work.key) }
        val image = File(directory, "${work.key}.png")
        val digest = receipt.optString("sha256")
        if (
            digest.isNotEmpty() &&
                withContext(Dispatchers.IO) {
                    image.isFile && contentDigest(image.readBytes()) == digest
                }
        ) {
            publish(work, PreparationState.READY, path = image.path)
            if (
                !receipt.optBoolean("acknowledged") &&
                    work.settings.enabled &&
                    work.settings.baseUrl() != null
            ) {
                try {
                    acknowledge(
                        ProxyClient(work.settings, transportState = graph.online),
                        work,
                        receipt,
                    )
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                }
            }
            return
        }
        if (!work.settings.enabled || work.settings.baseUrl() == null) {
            publish(
                work,
                PreparationState.NEEDS_CONNECTION,
                if (work.settings.enabled) "Configura el servidor para ampliar las portadas."
                else "La ampliación automática está desactivada.",
            )
            return
        }
        val client = ProxyClient(work.settings, transportState = graph.online)
        var id = receipt.optString("id")
        if (id.isNotEmpty() && !id.matches(Regex("[a-f0-9]{64}")))
            throw ProxyFailure("invalid_response")
        if (id.isEmpty()) {
            publish(work, PreparationState.RUNNING, "Enviando portada para ampliar…")
            val job =
                try {
                    client.expandArtwork(File(work.sourcePath), work.sourceSha, work.aspect)
                } catch (failure: ProxyFailure) {
                    if (failure.status == 404) throw ProxyFailure("artwork_server_update")
                    throw failure
                }
            id = job.optString("id")
            if (!id.matches(Regex("[a-f0-9]{64}"))) throw ProxyFailure("invalid_response")
            receipt.put("id", id)
            withContext(Dispatchers.IO) { writeReceipt(work.key, receipt) }
        }
        val path = "v1/artwork/expansions/jobs/$id"
        val deadline = android.os.SystemClock.elapsedRealtime() + 12 * 60 * 1000
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            val job =
                try {
                    client.get(path, emptyMap())
                } catch (failure: ProxyFailure) {
                    if (
                        recoverMissing &&
                            failure.code == "artwork_expansion_not_found" &&
                            failure.status == 404
                    ) {
                        receipt.remove("id")
                        receipt.remove("sha256")
                        receipt.remove("acknowledged")
                        withContext(Dispatchers.IO) { writeReceipt(work.key, receipt) }
                        process(work, recoverMissing = false)
                        return
                    }
                    throw failure
                }
            if (job.optString("error") == "codex_disabled") throw ProxyFailure("codex_disabled")
            if (job.optString("id") != id) throw ProxyFailure("invalid_response")
            when (job.optString("state")) {
                "completed" -> {
                    publish(work, PreparationState.RUNNING, "Descargando portada panorámica…")
                    val response = client.image("$path/image")
                    withContext(Dispatchers.IO) {
                        validate(response.bytes)
                        atomic(image, response.bytes)
                        receipt.put("sha256", response.sha256).put("acknowledged", false)
                        writeReceipt(work.key, receipt)
                    }
                    publish(work, PreparationState.READY, path = image.path)
                    try {
                        acknowledge(client, work, receipt)
                    } catch (error: Exception) {
                        if (error is CancellationException) throw error
                    }
                    return
                }
                "queued" ->
                    publish(
                        work,
                        PreparationState.WAITING,
                        "Portada panorámica en espera en el servidor…",
                    )
                "running" -> publish(work, PreparationState.RUNNING, "Ampliando portada…")
                "failed" -> throw ProxyFailure(job.optString("error", "codex_unavailable"))
                else -> throw ProxyFailure("invalid_response")
            }
            delay(pollMillis)
        }
        publish(
            work,
            PreparationState.WAITING,
            "La ampliación sigue en el servidor. Se recuperará al volver a la app.",
        )
    }

    private suspend fun acknowledge(client: ProxyClient, work: Work, receipt: JSONObject) {
        client.acknowledge(
            "v1/artwork/expansions/jobs/${receipt.getString("id")}/ack",
            receipt.getString("sha256"),
        )
        receipt.put("acknowledged", true)
        withContext(Dispatchers.IO) { writeReceipt(work.key, receipt) }
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
        if (
            bounds.outWidth <= bounds.outHeight ||
                bounds.outWidth > 4096 ||
                bounds.outHeight !in 1..2048
        )
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

    private fun readReceipt(key: String): JSONObject {
        val file = File(directory, "$key.json")
        val atomic = AtomicFile(file)
        return try {
            atomic.openRead().use { input ->
                val bytes = input.readBytes()
                check(bytes.size <= 4096)
                JSONObject(String(bytes, Charsets.UTF_8))
            }
        } catch (error: java.io.FileNotFoundException) {
            JSONObject()
        }
    }

    private fun writeReceipt(key: String, receipt: JSONObject) =
        atomic(File(directory, "$key.json"), receipt.toString().toByteArray())

    private fun atomic(file: File, bytes: ByteArray) {
        check(directory.isDirectory || directory.mkdirs()) {
            "No se pudo guardar la portada en el dispositivo."
        }
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            stream.write(bytes)
            atomic.finishWrite(stream)
        } catch (error: Exception) {
            atomic.failWrite(stream)
            throw error
        }
    }
}
