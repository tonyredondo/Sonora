package com.tonyredondo.sonora

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class ProxyFailure(val code: String, val status: Int = 0) :
    IOException(
        when (code) {
            "unauthorized" -> "El servidor ha rechazado el token. Revísalo en Ajustes."
            "offline" -> "No hay conexión con el servidor. Comprueba la red y Tailscale."
            "connection_changed" ->
                "La conexión ha cambiado. Se recuperará este contenido con el servidor actual."
            "not_configured" -> "Configura el servidor en Ajustes para preparar este contenido."
            "disabled" -> "La preparación online está desactivada."
            "codex_busy" -> "El servidor está ocupado. Se volverá a intentar automáticamente."
            "codex_limit" -> "Se ha alcanzado el límite de Codex. Inténtalo más tarde."
            "codex_timeout" -> "Codex ha tardado demasiado en responder."
            "codex_disabled" -> "Codex está desactivado en el servidor."
            "codex_unavailable" -> "Codex no está disponible en el servidor."
            "invalid_response" -> "El servidor devolvió un resultado incompleto o no válido."
            "artwork_server_update" -> "Actualiza el servidor para ampliar las portadas."
            "artwork_expansion_storage_full" ->
                "El servidor no tiene espacio para más portadas pendientes. Se volverá a intentar."
            "audio_character_disabled",
            "audio_character_unavailable" ->
                "Activa el análisis de estilo y ambiente en el servidor de Sonora."
            "audio_character_busy" ->
                "El servidor está analizando otras canciones. Se volverá a intentar."
            "audio_character_timeout" -> "El análisis de estilo ha tardado demasiado."
            "audio_character_invalid_response" ->
                "El servidor devolvió etiquetas de audio no válidas."
            "too_large" -> "La respuesta del servidor es demasiado grande."
            else -> "El servidor no pudo preparar este contenido. Comprueba su configuración."
        },
    ) {
    val transient: Boolean
        get() =
            code !in
                setOf(
                    "unauthorized",
                    "disabled",
                    "codex_disabled",
                    "codex_limit",
                    "audio_character_disabled",
                    "audio_character_unavailable",
                ) &&
                (code in
                    setOf(
                        "offline",
                        "codex_busy",
                        "codex_timeout",
                        "codex_unavailable",
                        "audio_character_busy",
                        "audio_character_timeout",
                        "artwork_job_not_ready",
                        "artwork_expansion_not_ready",
                    ) || status in setOf(429, 502, 503, 504))
}

class ProxyClient(
    private val settings: OnlineSettings,
    private val http: OkHttpClient = sharedHttp,
    private val transportState: kotlinx.coroutines.flow.StateFlow<OnlineSettings>? = null,
) {
    companion object {
        private val sharedHttp =
            OkHttpClient.Builder()
                .connectTimeout(12, TimeUnit.SECONDS)
                .readTimeout(230, TimeUnit.SECONDS)
                .callTimeout(240, TimeUnit.SECONDS)
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
    }

    suspend fun check() {
        val status = request("v1/status", null, 262144)
        if (
            status.optJSONObject("providers") == null ||
                status.optInt("metadata_archive_version") != 1
        )
            throw ProxyFailure("invalid_response")
    }

    suspend fun get(path: String, parameters: Map<String, String>): JSONObject =
        request(path, null, 524288, parameters)

    suspend fun post(path: String, body: JSONObject, limit: Int = 524288): JSONObject =
        request(path, body, limit)

    data class ImageResponse(val bytes: ByteArray, val sha256: String)

    suspend fun image(path: String, requireDigest: Boolean = true): ImageResponse {
        val result = exchange(path, null, 10_000_000, accept = "image/png")
        val digest =
            result.second
                ?: if (requireDigest) throw ProxyFailure("invalid_response")
                else contentDigest(result.first)
        if (!digest.matches(Regex("[a-f0-9]{64}")) || contentDigest(result.first) != digest)
            throw ProxyFailure("invalid_response")
        return ImageResponse(result.first, digest)
    }

    suspend fun acknowledge(path: String, sha256: String) {
        exchange(path, JSONObject().put("sha256", sha256), 4096, allowEmpty = true)
    }

    suspend fun expandArtwork(source: java.io.File, sha256: String, aspect: String): JSONObject {
        require(aspect in listOf("16:9", "2:1", "9:4", "8:3", "3:1"))
        val body =
            object : RequestBody() {
                override fun contentType(): MediaType = "application/json".toMediaType()

                override fun isOneShot(): Boolean = true

                override fun writeTo(sink: okio.BufferedSink) {
                    sink.writeUtf8("{\"image\":\"")
                    val digest = java.security.MessageDigest.getInstance("SHA-256")
                    val encoded =
                        android.util.Base64OutputStream(
                            sink.outputStream(),
                            android.util.Base64.NO_WRAP or android.util.Base64.NO_CLOSE,
                        )
                    var count = 0L
                    source.inputStream().use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val size = input.read(buffer)
                            if (size < 0) break
                            count += size
                            if (count > 10_000_000) throw IOException("Artwork changed")
                            digest.update(buffer, 0, size)
                            encoded.write(buffer, 0, size)
                        }
                    }
                    encoded.close()
                    val actual = digest.digest().joinToString("") { "%02x".format(it) }
                    if (actual != sha256) throw IOException("Artwork changed")
                    sink.writeUtf8("\",\"aspect\":\"$aspect\"}")
                }
            }
        val raw = exchange("v1/artwork/expansions/jobs", null, 524288, encodedBody = body)
        return try {
            JSONObject(String(raw.first, Charsets.UTF_8))
        } catch (_: Exception) {
            throw ProxyFailure("invalid_response")
        }
    }

    suspend fun audioCharacter(audio: ByteArray, refresh: Boolean = false): JSONObject {
        require(audio.size in 32044..2_880_044)
        val raw =
            exchange(
                "v1/audio/character",
                null,
                32768,
                parameters = if (refresh) mapOf("refresh" to "true") else emptyMap(),
                upload = audio,
            )
        return try {
            JSONObject(String(raw.first, Charsets.UTF_8))
        } catch (_: Exception) {
            throw ProxyFailure("audio_character_invalid_response")
        }
    }

    internal suspend fun lyricsAudio(
        path: String,
        audio: java.io.File,
        text: String? = null,
    ): JSONObject {
        require(
            path in setOf("v1/lyrics/align", "v1/lyrics/transcribe") &&
                audio.isFile &&
                audio.length() in 32044..19_200_044,
        )
        val body =
            MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .apply {
                    if (text != null) addFormDataPart("text", text)
                    addFormDataPart(
                        "file",
                        "audio.wav",
                        audio.asRequestBody("audio/wav".toMediaType()),
                    )
                }
                .build()
        return try {
            JSONObject(
                String(exchange(path, null, 8_000_000, encodedBody = body).first, Charsets.UTF_8),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: ProxyFailure) {
            throw error
        } catch (_: Exception) {
            throw ProxyFailure("invalid_response")
        }
    }

    private suspend fun request(
        path: String,
        body: JSONObject?,
        limit: Int,
        parameters: Map<String, String> = emptyMap(),
    ): JSONObject =
        try {
            JSONObject(String(exchange(path, body, limit, parameters).first, Charsets.UTF_8))
        } catch (failure: ProxyFailure) {
            throw failure
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw ProxyFailure("invalid_response")
        }

    private suspend fun exchange(
        path: String,
        body: JSONObject?,
        limit: Int,
        parameters: Map<String, String> = emptyMap(),
        accept: String = "application/json",
        allowEmpty: Boolean = false,
        upload: ByteArray? = null,
        encodedBody: RequestBody? = null,
    ): Pair<ByteArray, String?> {
        settings.validate()
        val base = settings.baseUrl() ?: throw ProxyFailure("not_configured")
        require(path.startsWith("v1/") && ".." !in path)
        val url =
            requireNotNull(base.resolve(path))
                .newBuilder()
                .apply { parameters.forEach { (key, value) -> addQueryParameter(key, value) } }
                .build()
        val request =
            withContext(Dispatchers.IO) {
                Request.Builder()
                    .url(url)
                    .apply {
                        if (settings.token.isNotBlank())
                            header("Authorization", "Bearer ${settings.token}")
                        header("Accept", accept)
                        if (encodedBody != null) post(encodedBody)
                        else if (upload != null)
                            post(upload.toRequestBody("audio/wav".toMediaType()))
                        else if (body != null)
                            post(
                                body
                                    .toString()
                                    .toRequestBody("application/json; charset=utf-8".toMediaType()),
                            )
                    }
                    .build()
            }
        val state = transportState
        return if (state == null) send(request, limit, allowEmpty)
        else withCurrentTransport(state, settings) { send(request, limit, allowEmpty) }
    }

    private suspend fun send(
        request: Request,
        limit: Int,
        allowEmpty: Boolean,
    ): Pair<ByteArray, String?> = suspendCancellableCoroutine { continuation ->
        val call = http.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(
            object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    if (continuation.isActive)
                        continuation.resumeWithException(ProxyFailure("offline"))
                }

                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            if (it.code in setOf(401, 403))
                                throw ProxyFailure("unauthorized", it.code)
                            val bytes =
                                it.body?.byteStream()?.use { stream ->
                                    val out = java.io.ByteArrayOutputStream()
                                    val buffer = ByteArray(8192)
                                    while (true) {
                                        val count = stream.read(buffer)
                                        if (count < 0) break
                                        if (out.size() + count > limit)
                                            throw ProxyFailure("too_large")
                                        out.write(buffer, 0, count)
                                    }
                                    out.toByteArray()
                                } ?: throw ProxyFailure("invalid_response")
                            if (!it.isSuccessful) {
                                val code =
                                    try {
                                        JSONObject(String(bytes, Charsets.UTF_8))
                                            .optString("error", "unavailable")
                                    } catch (_: Exception) {
                                        "invalid_response"
                                    }
                                throw ProxyFailure(code, it.code)
                            }
                            if (bytes.isEmpty() && !allowEmpty)
                                throw ProxyFailure("invalid_response")
                            if (continuation.isActive)
                                continuation.resume(bytes to it.header("x-content-sha256"))
                        }
                    } catch (error: Exception) {
                        val failure =
                            when (error) {
                                is ProxyFailure -> error
                                is IOException -> ProxyFailure("offline")
                                else -> ProxyFailure("invalid_response")
                            }
                        if (continuation.isActive) continuation.resumeWithException(failure)
                    }
                }
            },
        )
    }
}

object ProxyContent {
    fun translationInput(document: LyricsDocument, language: String): JSONObject {
        val lines = document.lines.filter { it.text.isNotBlank() }
        require(
            lines.isNotEmpty() &&
                lines.size <= 2000 &&
                lines.sumOf { it.text.toByteArray().size } <= 100000,
        )
        return JSONObject()
            .put(
                "lines",
                JSONArray(lines.map { JSONObject().put("id", it.id).put("text", it.text) }),
            )
            .put("source_language", "auto")
            .put("target_language", language)
    }

    fun translation(value: JSONObject, document: LyricsDocument): Map<Int, String> =
        try {
            if (value.optString("model") != "gpt-6.1-sol" || value.optString("effort") != "medium")
                throw ProxyFailure("invalid_response")
            val source = document.lines.filter { it.text.isNotBlank() }
            val result = value.getJSONArray("lines")
            if (result.length() != source.size) throw ProxyFailure("invalid_response")
            var bytes = 0
            source.indices.associate { index ->
                val line = result.getJSONObject(index)
                val text =
                    (line.opt("text") as? String)?.trim() ?: throw ProxyFailure("invalid_response")
                bytes += text.toByteArray().size
                val id = line.opt("id")
                if (
                    (id !is Int && id !is Long) ||
                        (id as Number).toLong() != source[index].id.toLong() ||
                        text.isBlank() ||
                        text.toByteArray().size > 10000 ||
                        bytes > 200000 ||
                        text.any { it.isISOControl() && it != '\t' }
                )
                    throw ProxyFailure("invalid_response")
                source[index].id to text
            }
        } catch (error: ProxyFailure) {
            throw error
        } catch (_: Exception) {
            throw ProxyFailure("invalid_response")
        }

    fun context(song: Song, extras: SongExtras) =
        JSONObject()
            .put("title", song.title)
            .put("artist", song.artist)
            .put("album", song.album)
            .put("styles", JSONArray(extras.styles.take(2)))
            .put("moods", JSONArray(extras.moods.take(2)))

    fun lyrics(song: Song): String =
        LyricsDocument.parse(song.lyricsText).lines.joinToString("\n") { it.text }

    fun meaningInput(song: Song, extras: SongExtras, language: String): JSONObject =
        JSONObject()
            .put("lyrics", lyrics(song))
            .put("language", language)
            .put("effort", "medium")
            .put("context", context(song, extras))

    fun interpretation(value: JSONObject): String {
        val text =
            (value.opt("explanation") as? String)?.trim() ?: throw ProxyFailure("invalid_response")
        if (
            value.optString("model") != "gpt-6-astra" ||
                value.optString("effort") != "medium" ||
                text.isBlank() ||
                text.toByteArray().size > 32768
        )
            throw ProxyFailure("invalid_response")
        return text
    }
}
