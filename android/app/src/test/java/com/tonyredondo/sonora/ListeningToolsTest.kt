package com.tonyredondo.sonora

import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

class ListeningToolsTest {
    @Test
    fun bypassIsExactAndBalanceNeverBleedsBetweenChannels() {
        val input = FloatArray(4800) { (sin(it * .1) * .8).toFloat() }
        assertArrayEquals(input, ListeningKernel(48000, 2).render(input), 0f)
        val monoLeft = FloatArray(4800) { if (it % 2 == 0) .25f else -.5f }
        val kernel = ListeningKernel(48000, 2)
        kernel.update(ListeningSettings(balance = 1f), 1.0)
        val output = kernel.render(monoLeft)
        assertTrue(output.indices.filter { it % 2 == 0 }.all { output[it] == 0f })
        assertTrue(output.indices.filter { it % 2 == 1 }.all { output[it] == -.5f })
    }

    @Test
    fun equalizerChangesTheRequestedBandAndPreampLeavesHeadroom() {
        val gains = List(10) { if (it == 5) 6f else 0f }
        val input = FloatArray(96000) { (sin(2 * PI * 1000 * it / 48000) * .05).toFloat() }
        fun rms(a: FloatArray) = sqrt(a.drop(4800).sumOf { it.toDouble().pow(2) } / (a.size - 4800))
        val kernel = ListeningKernel(48000, 1)
        kernel.update(ListeningSettings(equalizer = EqualizerSettings(true, gains, -3f)), 1.0)
        val gainDb = 20 * log10(rms(kernel.render(input)) / rms(input))
        assertEquals(3.0, gainDb, .12)
        val lowRate = ListeningKernel(8000, 1)
        lowRate.update(ListeningSettings(equalizer = EqualizerPreset.ROCK.settings()), 1.0)
        assertTrue(
            lowRate.render(input.take(8000).toFloatArray()).all { it.isFinite() && abs(it) <= 1f },
        )
    }

    @Test
    fun replayGainUsesAlbumOrTrackAndHonorsDigitalPeak() {
        val gains =
            ReplayGain(trackGainDb = 12.0, trackPeak = .8, albumGainDb = -6.0, albumPeak = .5)
        assertEquals(1.0, gains.multiplier(NormalizationMode.OFF), 0.0)
        assertEquals(1.25, gains.multiplier(NormalizationMode.TRACK), 1e-8)
        assertEquals(10.0.pow(-6.0 / 20), gains.multiplier(NormalizationMode.ALBUM), 1e-8)
        assertEquals(1.0, ReplayGain().multiplier(NormalizationMode.TRACK), 0.0)
        assertEquals(gains, ReplayGain.fromMetadata(gains.toMetadata()))
    }

    @Test
    fun listeningStateRoundTripsAndInvalidSettingsCannotReachTheAudioThread() {
        val value =
            ListeningSettings(EqualizerPreset.ROCK.settings(), -.25f, NormalizationMode.ALBUM)
        assertEquals(value, ListeningSettings.decode(value.encode()))
        assertThrows(IllegalArgumentException::class.java) {
            ListeningSettings(balance = Float.NaN).validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            EqualizerSettings(gains = listOf(0f)).validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            EqualizerSettings(preamp = 13f).validate()
        }
    }

    @Test
    fun changingAnEqBandDuringAudioDoesNotResetFilterHistoryOrClickOnDc() {
        val kernel = ListeningKernel(48000, 1)
        kernel.render(FloatArray(48000) { .2f })
        for (gain in listOf(12f, -12f, 6f, 0f)) {
            kernel.update(
                ListeningSettings(
                    equalizer = EqualizerSettings(true, List(10) { if (it == 5) gain else 0f }),
                ),
                1.0,
            )
            val output = kernel.render(FloatArray(2000) { .2f })
            assertTrue(
                "A live filter change must preserve constant input without a transient",
                output.all { abs(it - .2f) < .0001f },
            )
        }
    }
}
