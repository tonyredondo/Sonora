package com.tonyredondo.sonora

import android.content.Context
import kotlin.math.*

data class AudioAnalysis(
    val bpm: Double?,
    val waveform: List<Float>,
    val characterWav: ByteArray? = null,
    val volume: VolumeMeasurement? = null,
    val volumeSupported: Boolean = false,
    val headBeat: BeatGrid? = null,
    val tailBeat: BeatGrid? = null,
)

/** Ten-millisecond RMS envelopes retain the song's dynamics and tolerate human timing. */
object TempoDetector {
    fun preferred(value: Double): Double = if (value > 170 && value <= 300) value / 2 else value

    fun estimate(energy: List<Double>, hop: Double = .01): Double? {
        if (
            energy.size !in 600..4000 ||
                hop !in 0.005..0.02 ||
                energy.any { !it.isFinite() || it < 0 }
        )
            return null
        val changes =
            energy.indices.map { max(0.0, energy[it] - if (it == 0) 0.0 else energy[it - 1]) }
        val peak = changes.maxOrNull() ?: return null
        if (peak < .00001 || changes.count { it > peak * .1 } < 6) return null
        val radius = (0.03 / hop).roundToInt().coerceAtLeast(1)
        val onset =
            DoubleArray(changes.size) { i ->
                (max(0, i - radius)..min(changes.lastIndex, i + radius)).sumOf { j ->
                    changes[j] / peak * (radius + 1 - abs(j - i))
                }
            }
        val threshold = onset.max() * .55
        val peaks =
            (1 until onset.lastIndex).filter {
                onset[it] >= threshold && onset[it] > onset[it - 1] && onset[it] >= onset[it + 1]
            }
        val intervals = peaks.zipWithNext { a, b -> (b - a) * hop }.filter { it in .2..1.5 }
        val mean = onset.average()
        onset.indices.forEach { onset[it] -= mean }
        fun score(lag: Int): Double {
            var cross = 0.0
            var a = 0.0
            var b = 0.0
            for (i in lag until onset.size) {
                val x = onset[i]
                val y = onset[i - lag]
                cross += x * y
                a += x * x
                b += y * y
            }
            return if (a * b > 0) cross / sqrt(a * b) else 0.0
        }
        val lower = max(1, floor(60 / 300.0 / hop).toInt())
        val upper = ceil(60 / 40.0 / hop).toInt()
        val scores = DoubleArray(upper + 2) { if (it > 0) score(it) else 0.0 }
        var best = Double.NEGATIVE_INFINITY
        var result: Double? = null
        for (lag in lower..upper) {
            val strength = scores[lag]
            val before = scores[lag - 1]
            val after = scores[lag + 1]
            if (strength < .12 || strength < before || strength < after) continue
            val denominator = before - 2 * strength + after
            val correction =
                if (abs(denominator) > .00001)
                    (.5 * (before - after) / denominator).coerceIn(-.5, .5)
                else 0.0
            val period = (lag + correction) * hop
            val matching = intervals.filter { abs(it / period - 1) < .2 }
            val support = matching.size.toDouble() / max(1, intervals.size)
            val rank =
                (if (intervals.size >= 6) .5 * strength + .5 * support else strength) -
                    .03 * abs(log2(60 / period / 120))
            if (rank > best) {
                best = rank
                result =
                    preferred(
                        (60 / if (matching.size >= 6) matching.average() else period).coerceIn(
                            40.0,
                            300.0,
                        ),
                    )
            }
        }
        return result
    }
}

/** Streaming PCM decoding is isolated from playback and bounded in duration, memory and time. */
class LocalAudioAnalyzer(private val context: Context) {
    suspend fun analyze(song: Song): AudioAnalysis {
        var duration = 0.0
        lateinit var sampler: CharacterSampler
        var rate = 0
        var channels = 0
        var meter: LoudnessMeter? = null
        var volumeSupported = false
        var frames = 0L
        var hopFrames = 0
        var hopEnergy = 0.0
        val energy = ArrayList<Double>()
        val bins = DoubleArray(512)
        val counts = LongArray(512)
        PcmAudioReader(context)
            .read(
                song,
                90,
                { value ->
                    rate = value.rate
                    channels = value.channels
                    duration = value.durationSeconds
                    sampler = CharacterSampler(duration)
                    volumeSupported = channels in 1..2
                    meter = if (volumeSupported) LoudnessMeter(rate, channels) else null
                },
                { pcm ->
                    var index = 0
                    while (index < pcm.size) {
                        var square = 0.0
                        var mono = 0.0
                        repeat(channels) { channel ->
                            val sample = pcm[index++].toDouble()
                            require(sample.isFinite()) { "El audio contiene muestras inválidas." }
                            meter?.add(sample, channel)
                            square += sample * sample
                            mono += sample
                        }
                        square /= channels
                        sampler.add(frames.toDouble() / rate, rate, mono / channels)
                        val bin =
                            ((frames.toDouble() / rate / duration) * bins.size)
                                .toInt()
                                .coerceIn(0, bins.lastIndex)
                        bins[bin] += square
                        counts[bin]++
                        frames++
                        hopEnergy += square
                        hopFrames++
                        if (hopFrames >= rate / 100) {
                            energy.add(sqrt(hopEnergy / hopFrames))
                            hopFrames = 0
                            hopEnergy = 0.0
                        }
                    }
                },
            )
        val raw = bins.indices.map { if (counts[it] > 0) sqrt(bins[it] / counts[it]) else 0.0 }
        val reference = max(.05, raw.max())
        val windows =
            listOf(0, (energy.size - 3200) / 2, energy.size - 3200)
                .map { it.coerceAtLeast(0) }
                .distinct()
                .mapNotNull { start ->
                    TempoDetector.estimate(
                        energy.subList(start, min(start + 3200, energy.size)),
                    )
                }
        val bpm = if (windows.isEmpty()) null else windows.sorted()[windows.size / 2]
        return AudioAnalysis(
            bpm,
            raw.map { (it / reference).coerceIn(0.0, 1.0).toFloat() },
            sampler.finish(),
            meter?.finish(),
            volumeSupported,
            BeatGrid.estimate(energy.take(3200), bpm, 0.0),
            BeatGrid.estimate(energy.takeLast(3200), bpm, max(0, energy.size - 3200) * .01),
        )
    }
}
