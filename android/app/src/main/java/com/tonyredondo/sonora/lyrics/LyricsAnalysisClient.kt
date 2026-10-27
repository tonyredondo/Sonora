package com.tonyredondo.sonora

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

internal data class TranscriptResult(
    val transcript: LyricsTranscript?,
    val cached: Boolean,
    val warning: String? = null,
)

internal data class AlignmentResult(
    val text: String,
    val cached: Boolean,
    val warning: String? = null,
)

/**
 * Source receipts avoid decoding again offline; immutable results are also deduplicated by PCM SHA.
 * No automatic paid retry follows a missing/corrupt retained result or an ambiguous network
 * failure.
 */
internal class LyricsAnalysisClient(
    private val context: Context,
    private val store: LibraryStore,
    private val settings: StateFlow<OnlineSettings>,
    private val phase: (String) -> Unit = {},
) {
    private data class Result(
        val data: JSONObject,
        val hash: String,
        val duration: Double,
        val cached: Boolean,
        val warning: String? = null,
    )

    suspend fun transcribe(song: Song): TranscriptResult {
        val result =
            load(song, null) { data, hash, duration ->
                LyricsTranscript.decode(data, hash, duration)
            }
        return TranscriptResult(
            LyricsTranscript.decode(result.data, result.hash, result.duration),
            result.cached,
            result.warning,
        )
    }

    suspend fun align(song: Song, text: String): AlignmentResult {
        val document = LyricsDocument.parse(text)
        val plain =
            text
                .lineSequence()
                .flatMap { raw ->
                    if (raw.isBlank()) sequenceOf("")
                    else LyricsDocument.parse(raw).editableLines.asSequence().map { it.text }
                }
                .joinToString("\n")
        require(
            plain.toByteArray().size <= 65536 &&
                plain.isNotBlank() &&
                '\u0000' !in plain &&
                plain.lineSequence().all { it.isBlank() || lyricKey(it).isNotEmpty() },
        ) {
            "Añade una letra válida antes de sincronizarla."
        }
        val result =
            load(song, plain) { data, hash, duration ->
                decodeAlignment(data, hash, plain, duration)
            }
        val aligned = decodeAlignment(result.data, result.hash, plain, result.duration)
        return AlignmentResult(
            (document.headers + aligned).joinToString("\n"),
            result.cached,
            result.warning,
        )
    }

    private fun decodeAlignment(
        data: JSONObject,
        hash: String,
        text: String,
        duration: Double,
    ): String {
        require(
            listOf("audio_sha256", "text_sha256", "plain_lyrics", "synced_lyrics").all {
                data.opt(it) is String
            } && data.opt("duration") is Number,
        )
        require(
            data.getString("audio_sha256") == hash &&
                data.getString("text_sha256") == contentDigest(text) &&
                data.getString("plain_lyrics") == text &&
                data.getDouble("duration").isFinite() &&
                kotlin.math.abs(data.getDouble("duration") - duration) <= .1,
        ) {
            "Los tiempos recibidos corresponden a otra letra o a otro audio."
        }
        return alignedLyrics(data.getString("synced_lyrics"), text, duration)
    }

    private suspend fun load(
        song: Song,
        text: String?,
        validate: (JSONObject, String, Double) -> Unit,
    ): Result {
        phase("Buscando análisis guardado…")
        val kind =
            if (text == null) "transcription-scribe-v2" else "alignment-v1:${contentDigest(text)}"
        val prefix = "lyrics-analysis-v1:$kind:"
        val receiptKey = prefix + "source:" + audioSourceKey(song)
        suspend fun retained(hash: String, duration: Double): Result? {
            require(
                hash.matches(Regex("[a-f0-9]{64}")) &&
                    duration.isFinite() &&
                    duration in 1.0..600.0,
            )
            val raw = withContext(Dispatchers.IO) { store.state(prefix + hash) } ?: return null
            require(raw.toByteArray().size <= 8_000_000)
            val data = JSONObject(raw)
            validate(data, hash, duration)
            return Result(data, hash, duration, true)
        }
        val receipt = withContext(Dispatchers.IO) { store.state(receiptKey) }
        if (receipt != null) {
            val value = JSONObject(receipt)
            require(value.getInt("version") == 1)
            return retained(value.getString("sha256"), value.getDouble("duration"))
                ?: error("El análisis guardado está incompleto. No se ha enviado otra solicitud.")
        }
        val connection = settings.value
        if (!connection.enabled) throw ProxyFailure("disabled")
        if (connection.baseUrl() == null) throw ProxyFailure("not_configured")
        connection.validate()
        return withContext(Dispatchers.IO) {
            phase("Preparando audio…")
            LyricsAudioPreparation(context).prepare(song).use { audio ->
                val prior = retained(audio.sha256, audio.duration)
                if (prior == null)
                    phase(
                        if (text == null) "Transcribiendo el audio…" else "Sincronizando la letra…",
                    )
                val result =
                    prior
                        ?: ProxyClient(connection, transportState = settings)
                            .lyricsAudio(
                                if (text == null) "v1/lyrics/transcribe" else "v1/lyrics/align",
                                audio.file,
                                text,
                            )
                            .let { envelope ->
                                val data = envelope.getJSONObject("data")
                                validate(data, audio.sha256, audio.duration)
                                Result(data, audio.sha256, audio.duration, false)
                            }
                try {
                    if (prior == null) store.putState(prefix + audio.sha256, result.data.toString())
                    store.putState(
                        receiptKey,
                        JSONObject()
                            .put("version", 1)
                            .put("sha256", audio.sha256)
                            .put("duration", audio.duration)
                            .toString(),
                    )
                    result
                } catch (error: Exception) {
                    if (error is CancellationException) throw error
                    result.copy(
                        warning =
                            "No se pudo guardar el análisis sin conexión. Volver a analizar puede consumir uso del servicio.",
                    )
                }
            }
        }
    }
}
