package com.tonyredondo.sonora

import kotlin.math.*
import org.json.JSONArray
import org.json.JSONObject

/** Gated K-weighted mono/stereo loudness, ITU-R BS.1770-5 Annex 1. Digital sample peak. */
class LoudnessMeter(private val rate: Int, private val channels: Int) {
    private class Filter(coefficients: DoubleArray, rate: Int, channels: Int) {
        private val b: DoubleArray
        private val a: DoubleArray
        private val x1 = DoubleArray(channels)
        private val x2 = DoubleArray(channels)
        private val y1 = DoubleArray(channels)
        private val y2 = DoubleArray(channels)

        init {
            // Inverse then forward bilinear transform of the standard's 48 kHz biquad.
            val r = rate / 48000.0
            val u = 1 - r
            val v = 1 + r
            fun transform(c0: Double, c1: Double, c2: Double) =
                doubleArrayOf(
                    c0 * v * v + c1 * u * v + c2 * u * u,
                    2 * u * v * (c0 + c2) + c1 * (u * u + v * v),
                    c0 * u * u + c1 * u * v + c2 * v * v,
                )
            val rawA = transform(1.0, coefficients[3], coefficients[4])
            val rawB = transform(coefficients[0], coefficients[1], coefficients[2])
            a = DoubleArray(3) { rawA[it] / rawA[0] }
            b = DoubleArray(3) { rawB[it] / rawA[0] }
        }

        fun sample(x: Double, c: Int): Double {
            val y = b[0] * x + b[1] * x1[c] + b[2] * x2[c] - a[1] * y1[c] - a[2] * y2[c]
            x2[c] = x1[c]
            x1[c] = x
            y2[c] = y1[c]
            y1[c] = y
            return y
        }
    }

    private val shelf =
        Filter(
            doubleArrayOf(
                1.53512485958697,
                -2.69169618940638,
                1.19839281085285,
                -1.69065929318241,
                .73248077421585,
            ),
            rate,
            channels,
        )
    private val highpass =
        Filter(doubleArrayOf(1.0, -2.0, 1.0, -1.99004745483398, .99007225036621), rate, channels)
    private val window = DoubleArray((rate * .4).roundToInt())
    private val hop = (rate * .1).roundToInt()
    private val blocks = ArrayList<Double>()
    private var frames = 0L
    private var sum = 0.0
    private var framePower = 0.0
    private var peak = 0.0
    private var expectedChannel = 0

    init {
        require(rate in 8000..384000 && channels in 1..2)
    }

    fun add(value: Double, channel: Int) {
        require(channel == expectedChannel)
        val x = if (value.isFinite()) value else 0.0
        peak = max(peak, abs(x))
        val y = highpass.sample(shelf.sample(x, channel), channel)
        framePower += y * y
        expectedChannel++
        if (expectedChannel == channels) {
            expectedChannel = 0
            val index = (frames % window.size).toInt()
            sum -= window[index]
            window[index] = framePower
            sum += framePower
            framePower = 0.0
            frames++
            if (frames >= window.size && (frames - window.size) % hop == 0L) {
                val power = (sum / window.size).coerceAtLeast(0.0)
                if (power > VolumeMeasurement.absoluteGate) {
                    check(blocks.size < 72000) { "El análisis de volumen supera las dos horas." }
                    blocks.add(power)
                }
            }
        }
    }

    fun finish(): VolumeMeasurement? =
        if (blocks.isEmpty() || peak == 0.0) null
        else VolumeMeasurement(blocks.toList(), peak).also { it.validate() }
}

data class VolumeMeasurement(val blocks: List<Double>, val peak: Double) {
    fun validate() {
        require(
            blocks.isNotEmpty() &&
                blocks.size <= 2_000_000 &&
                blocks.all { it.isFinite() && it > absoluteGate && it <= 1e8 } &&
                peak.isFinite() &&
                peak > 0 &&
                peak <= 1000,
        )
    }

    fun lufs(): Double {
        validate()
        val threshold = blocks.average() * .1
        val accepted = blocks.filter { it > threshold }
        return -.691 + 10 * log10(accepted.average())
    }

    fun gainDb(): Double = -18.0 - lufs()

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("blocks", JSONArray(blocks))
            .put("peak", peak)
            .toString()
    }

    companion object {
        val absoluteGate = 10.0.pow((-70 + .691) / 10)

        fun decode(text: String): VolumeMeasurement {
            require(text.toByteArray().size <= 4_000_000)
            val v = JSONObject(text)
            require(v.getInt("version") == 1)
            val b = v.getJSONArray("blocks")
            require(b.length() in 1..72000)
            return VolumeMeasurement(List(b.length()) { b.getDouble(it) }, v.getDouble("peak"))
                .also { it.validate() }
        }

        fun album(values: List<VolumeMeasurement>): VolumeMeasurement? {
            if (values.isEmpty()) return null
            values.forEach { it.validate() }
            require(values.sumOf { it.blocks.size } <= 2_000_000) {
                "El álbum es demasiado grande para analizar su volumen."
            }
            return VolumeMeasurement(values.flatMap { it.blocks }, values.maxOf { it.peak })
        }
    }
}
