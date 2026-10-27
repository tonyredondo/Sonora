package com.tonyredondo.sonora

import kotlin.math.*
import org.json.JSONObject

enum class TransitionMode(val label: String) {
    CONTINUOUS("Continua"),
    CROSSFADE("Crossfade"),
    ADAPTIVE("Mezcla automática"),
}

data class TransitionSettings(
    val mode: TransitionMode = TransitionMode.CONTINUOUS,
    val seconds: Int = 5,
) {
    fun validate() {
        require(seconds in 1..12) { "El fundido debe durar entre 1 y 12 segundos." }
    }

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("mode", mode.name)
            .put("seconds", seconds)
            .toString()
    }

    companion object {
        fun decode(text: String): TransitionSettings {
            require(text.toByteArray().size <= 4096)
            val value = JSONObject(text)
            require(value.getInt("version") == 1)
            return TransitionSettings(
                    TransitionMode.valueOf(value.getString("mode")),
                    value.getInt("seconds"),
                )
                .also { it.validate() }
        }
    }
}

data class BeatGrid(val period: Double, val anchor: Double, val confidence: Double) {
    init {
        require(
            period.isFinite() &&
                period in .2..1.5 &&
                anchor.isFinite() &&
                anchor >= 0 &&
                confidence.isFinite() &&
                confidence in 0.0..1.0,
        )
    }

    fun nextBeat(time: Double): Double =
        anchor + ceil((time - anchor) / period - .000000001) * period

    fun encode(): JSONObject =
        JSONObject().put("period", period).put("anchor", anchor).put("confidence", confidence)

    companion object {
        fun decode(value: JSONObject) =
            BeatGrid(
                value.getDouble("period"),
                value.getDouble("anchor"),
                value.getDouble("confidence"),
            )

        fun estimate(energy: List<Double>, bpm: Double?, start: Double): BeatGrid? {
            if (bpm == null || energy.size < 600 || bpm !in 40.0..300.0) return null
            val period = 60 / bpm
            val changes =
                energy.indices.map { max(0.0, energy[it] - (energy.getOrNull(it - 1) ?: 0.0)) }
            val peak = changes.maxOrNull() ?: return null
            if (peak < .00001) return null
            var real = 0.0
            var imaginary = 0.0
            var total = 0.0
            for (i in changes.indices) if (changes[i] >= peak * .1) {
                val weight = (changes[i] / peak).pow(2)
                val phase = 2 * PI * i * .01 / period
                real += weight * cos(phase)
                imaginary += weight * sin(phase)
                total += weight
            }
            val concentration = hypot(real, imaginary) / max(total, .000001)
            if (concentration < .2) return null
            val confidence = min(.7, sqrt(concentration) * .7)
            if (confidence < .35) return null
            var phase = atan2(imaginary, real) / (2 * PI) * period
            if (phase < 0) phase += period
            val first = changes.indexOfFirst { it >= peak * .25 }
            if (first < 0) return null
            return BeatGrid(
                period,
                max(0.0, start + phase + round((first * .01 - phase) / period) * period),
                confidence,
            )
        }
    }
}

data class TransitionPlan(
    val duration: Double,
    val incomingSkip: Double = 0.0,
    val aligned: Boolean = false,
    val estimated: Boolean = false,
)

object TransitionPlanner {
    fun plan(
        settings: TransitionSettings,
        outgoingDuration: Double,
        incomingDuration: Double,
        outgoingBpm: Double?,
        incomingBpm: Double?,
        outgoing: BeatGrid?,
        incoming: BeatGrid?,
    ): TransitionPlan {
        settings.validate()
        require(
            outgoingDuration.isFinite() &&
                incomingDuration.isFinite() &&
                outgoingDuration > 0 &&
                incomingDuration > 0,
        )
        val maximum = minOf(settings.seconds.toDouble(), outgoingDuration / 2, incomingDuration / 2)
        if (settings.mode != TransitionMode.ADAPTIVE) return TransitionPlan(maximum)
        if (
            outgoing != null &&
                incoming != null &&
                min(outgoing.confidence, incoming.confidence) >= .35
        ) {
            val cue = incoming.nextBeat(0.0)
            val approximate = min(outgoing.confidence, incoming.confidence) < .72
            val drift = if (approximate) min(.1, outgoing.period * .15) else .035
            val difference = abs(outgoing.period - incoming.period)
            val limit =
                minOf(
                    maximum,
                    if (difference < .000001) maximum else drift * outgoing.period / difference,
                    (incomingDuration - cue) / 2,
                )
            val start = outgoing.nextBeat(outgoingDuration - limit)
            val duration = outgoingDuration - start
            if (
                cue in 0.0..1.0 &&
                    duration >= outgoing.period * (if (approximate) 2 else 4) &&
                    duration <= limit + .000001
            )
                return TransitionPlan(duration, cue, true, approximate)
        }
        val bpm =
            listOfNotNull(outgoingBpm, incomingBpm).firstOrNull {
                it.isFinite() && it in 40.0..300.0
            }
        if (bpm != null) {
            val period = 60 / bpm
            val beats = floor(maximum / period)
            return TransitionPlan(if (beats >= 1) beats * period else maximum, estimated = true)
        }
        return TransitionPlan(maximum)
    }
}
