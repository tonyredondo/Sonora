package com.tonyredondo.sonora

import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

class LoudnessMeterTest {
    @Test
    fun monoAndStereoSineFollowTheIndependentLoudnessReferenceAcrossRates() {
        for (rate in listOf(8000, 16000, 44100, 48000)) {
            val meter = LoudnessMeter(rate, 1)
            repeat(rate * 3) { meter.add(.1 * sin(2 * PI * 1000 * it / rate), 0) }
            assertEquals(-23.0, meter.finish()!!.lufs(), .15)
        }
        for ((frequency, reference) in listOf(50 to -27.6, 8000 to -19.7)) {
            val meter = LoudnessMeter(48000, 1)
            repeat(144000) { meter.add(.1 * sin(2 * PI * frequency * it / 48000), 0) }
            assertEquals(reference, meter.finish()!!.lufs(), .15)
        }
        val stereo = LoudnessMeter(48000, 2)
        repeat(144000) {
            val v = .1 * sin(2 * PI * 1000 * it / 48000)
            stereo.add(v, 0)
            stereo.add(v, 1)
        }
        assertEquals(-20.0, stereo.finish()!!.lufs(), .15)
    }

    @Test
    fun silenceDoesNotInventGainAndGatingExcludesQuietSections() {
        val silent = LoudnessMeter(48000, 1)
        repeat(48000) { silent.add(0.0, 0) }
        assertNull(silent.finish())
        val meter = LoudnessMeter(48000, 1)
        repeat(480000) {
            meter.add((if (it < 240000) .1 else .00001) * sin(2 * PI * 1000 * it / 48000), 0)
        }
        val measured = meter.finish()!!
        assertEquals(-23.0, measured.lufs(), .25)
        assertEquals(.1, measured.peak, 1e-6)
        assertEquals(measured, VolumeMeasurement.decode(measured.encode()))
        val album = VolumeMeasurement.album(listOf(measured, measured))!!
        assertEquals(measured.lufs(), album.lufs(), 1e-8)
    }
}
