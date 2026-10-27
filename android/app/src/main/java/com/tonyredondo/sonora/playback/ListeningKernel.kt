package com.tonyredondo.sonora

import kotlin.math.*

/** Interleaved PCM DSP. One render thread owns coefficients and filter history. */
class ListeningKernel(private val rate: Int, private val channels: Int) {
    private class Band(channels: Int, last: DoubleArray, previous: DoubleArray) {
        private val coefficients = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 0.0)
        private var target = coefficients.copyOf()
        private val x1 = last.copyOf(channels)
        private val x2 = previous.copyOf(channels)
        private val y1 = last.copyOf(channels)
        private val y2 = previous.copyOf(channels)

        fun target(value: DoubleArray, immediate: Boolean) {
            target = value
            if (immediate) value.copyInto(coefficients)
        }

        fun advance(remaining: Int) {
            for (i in coefficients.indices) coefficients[i] +=
                (target[i] - coefficients[i]) / remaining
        }

        fun sample(x: Double, c: Int): Double {
            val y =
                coefficients[0] * x + coefficients[1] * x1[c] + coefficients[2] * x2[c] -
                    coefficients[3] * y1[c] -
                    coefficients[4] * y2[c]
            x2[c] = x1[c]
            x1[c] = x
            y2[c] = y1[c]
            y1[c] = y
            return y
        }
    }

    private var settings = ListeningSettings()
    private var normalization = 1.0
    private var bands = emptyList<Band>()
    private val lastInput = DoubleArray(channels)
    private val previousInput = DoubleArray(channels)
    private var initialized = false
    private var coefficientRamp = 0
    private var clearAfterRamp = false
    private var currentLeft = 1.0
    private var currentRight = 1.0
    private var currentOther = 1.0
    private var targetLeft = 1.0
    private var targetRight = 1.0
    private var targetOther = 1.0
    private var ramp = 0

    init {
        require(rate in 8000..384000 && channels in 1..8)
    }

    fun update(value: ListeningSettings, multiplier: Double) {
        value.validate()
        require(multiplier.isFinite() && multiplier in 0.0..100.0)
        if (value == settings && multiplier == normalization) return
        if (
            value.equalizer.enabled != settings.equalizer.enabled ||
                value.equalizer.gains != settings.equalizer.gains
        ) {
            val targets =
                EqualizerSettings.frequencies.mapIndexed { i, f ->
                    val gain = value.equalizer.gains[i].toDouble()
                    if (!value.equalizer.enabled || f >= rate * .49 || gain == 0.0)
                        doubleArrayOf(1.0, 0.0, 0.0, 0.0, 0.0)
                    else {
                        val a = 10.0.pow(gain / 40)
                        val w = 2 * PI * f / rate
                        val alpha = sin(w) / (2 * sqrt(2.0))
                        val d = 1 + alpha / a
                        doubleArrayOf(
                            (1 + alpha * a) / d,
                            -2 * cos(w) / d,
                            (1 - alpha * a) / d,
                            -2 * cos(w) / d,
                            (1 - alpha / a) / d,
                        )
                    }
                }
            clearAfterRamp = targets.all { it[0] == 1.0 && it.drop(1).all { x -> x == 0.0 } }
            if (bands.isEmpty() && !clearAfterRamp)
                bands = List(10) { Band(channels, lastInput, previousInput) }
            bands.forEachIndexed { i, band -> band.target(targets[i], !initialized) }
            coefficientRamp = if (initialized && bands.isNotEmpty()) max(1, rate / 100) else 0
            if (!initialized && clearAfterRamp) bands = emptyList()
        }
        settings = value
        normalization = multiplier
        val gain =
            multiplier *
                if (value.equalizer.enabled) 10.0.pow(value.equalizer.preamp / 20.0) else 1.0
        targetOther = gain
        targetLeft = gain * if (channels >= 2 && value.balance > 0) 1.0 - value.balance else 1.0
        targetRight = gain * if (channels >= 2 && value.balance < 0) 1.0 + value.balance else 1.0
        if (!initialized) {
            currentLeft = targetLeft
            currentRight = targetRight
            currentOther = targetOther
        } else ramp = max(1, rate / 100)
    }

    fun render(input: FloatArray): FloatArray {
        require(input.size % channels == 0)
        return FloatArray(input.size).also { output ->
            var p = 0
            while (p < input.size) {
                beginFrame()
                repeat(channels) { c ->
                    output[p] = sample(input[p].toDouble(), c).toFloat()
                    p++
                }
            }
        }
    }

    fun beginFrame() {
        initialized = true
        if (coefficientRamp > 0) {
            bands.forEach { it.advance(coefficientRamp) }
            coefficientRamp--
            if (coefficientRamp == 0 && clearAfterRamp) bands = emptyList()
        }
        if (ramp > 0) {
            currentLeft += (targetLeft - currentLeft) / ramp
            currentRight += (targetRight - currentRight) / ramp
            currentOther += (targetOther - currentOther) / ramp
            ramp--
        }
    }

    fun sample(input: Double, channel: Int): Double {
        val original = if (input.isFinite()) input else 0.0
        var value = original
        for (band in bands) value = band.sample(value, channel)
        previousInput[channel] = lastInput[channel]
        lastInput[channel] = original
        value *= if (channel == 0) currentLeft else if (channel == 1) currentRight else currentOther
        return if (value.isFinite()) value.coerceIn(-1.0, 1.0) else 0.0
    }
}
