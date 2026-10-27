package com.tonyredondo.sonora

import kotlin.math.min
import kotlin.math.pow
import org.json.JSONArray
import org.json.JSONObject

enum class NormalizationMode {
    OFF,
    TRACK,
    ALBUM,
}

data class EqualizerSettings(
    val enabled: Boolean = false,
    val gains: List<Float> = List(10) { 0f },
    val preamp: Float = 0f,
) {
    fun validate() {
        require(
            gains.size == 10 &&
                gains.all { it.isFinite() && it in -12f..12f } &&
                preamp.isFinite() &&
                preamp in -24f..12f,
        ) {
            "El ecualizador guardado no es válido."
        }
    }

    companion object {
        val frequencies =
            listOf(31.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
    }
}

enum class EqualizerPreset(val label: String, private val gains: List<Float>) {
    FLAT("Plano", List(10) { 0f }),
    BASS("Graves", listOf(6f, 5f, 3f, 1f, 0f, 0f, 0f, -1f, -1f, -1f)),
    VOCALS("Voces", listOf(-3f, -2f, -1f, 0f, 2f, 4f, 4f, 2f, 0f, -1f)),
    ROCK("Rock", listOf(4f, 3f, 1f, -1f, -2f, 1f, 3f, 4f, 4f, 3f)),
    JAZZ("Jazz", listOf(3f, 2f, 1f, 0f, -1f, 1f, 2f, 3f, 3f, 2f)),
    CLASSICAL("Clásica", listOf(3f, 2f, 1f, 0f, -1f, 0f, 1f, 2f, 3f, 3f));

    fun settings() =
        EqualizerSettings(true, gains, if (this == FLAT) 0f else -(gains.maxOrNull() ?: 0f) - 2f)
}

data class ListeningSettings(
    val equalizer: EqualizerSettings = EqualizerSettings(),
    val balance: Float = 0f,
    val normalization: NormalizationMode = NormalizationMode.OFF,
) {
    fun validate() {
        equalizer.validate()
        require(balance.isFinite() && balance in -1f..1f) { "El balance guardado no es válido." }
    }

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("eq", equalizer.enabled)
            .put("gains", JSONArray(equalizer.gains))
            .put("preamp", equalizer.preamp.toDouble())
            .put("balance", balance.toDouble())
            .put("normalization", normalization.name)
            .toString()
    }

    companion object {
        fun decode(text: String): ListeningSettings {
            require(text.toByteArray().size <= 4096)
            val value = JSONObject(text)
            require(value.getInt("version") == 1)
            val gains = value.getJSONArray("gains")
            require(gains.length() == 10)
            return ListeningSettings(
                    EqualizerSettings(
                        value.getBoolean("eq"),
                        List(10) { gains.getDouble(it).toFloat() },
                        value.getDouble("preamp").toFloat(),
                    ),
                    value.getDouble("balance").toFloat(),
                    NormalizationMode.valueOf(value.getString("normalization")),
                )
                .also { it.validate() }
        }
    }
}

data class ReplayGain(
    val trackGainDb: Double? = null,
    val trackPeak: Double? = null,
    val albumGainDb: Double? = null,
    val albumPeak: Double? = null,
) {
    fun multiplier(mode: NormalizationMode): Double {
        if (mode == NormalizationMode.OFF) return 1.0
        val gain = if (mode == NormalizationMode.ALBUM) albumGainDb else trackGainDb
        val peak = if (mode == NormalizationMode.ALBUM) albumPeak else trackPeak
        if (gain == null || !gain.isFinite()) return 1.0
        val value = 10.0.pow(gain.coerceIn(-60.0, 20.0) / 20)
        return if (peak != null && peak.isFinite() && peak > 0) min(value, 1 / peak) else value
    }

    fun toMetadata(): String =
        JSONObject()
            .apply {
                trackGainDb?.let { put("replaygain_track_gain", it) }
                trackPeak?.let { put("replaygain_track_peak", it) }
                albumGainDb?.let { put("replaygain_album_gain", it) }
                albumPeak?.let { put("replaygain_album_peak", it) }
            }
            .toString()

    companion object {
        fun fromMetadata(text: String): ReplayGain {
            val value = JSONObject(text)
            fun number(key: String): Double? =
                value
                    .opt(key)
                    ?.toString()
                    ?.trim()
                    ?.removeSuffix("dB")
                    ?.trim()
                    ?.toDoubleOrNull()
                    ?.takeIf { it.isFinite() }
            return ReplayGain(
                number("replaygain_track_gain"),
                number("replaygain_track_peak"),
                number("replaygain_album_gain"),
                number("replaygain_album_peak"),
            )
        }
    }
}
