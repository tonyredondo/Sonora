package com.tonyredondo.sonora

import kotlin.math.*
import org.junit.Assert.*
import org.junit.Test

class TempoDetectorTest {
    @Test
    fun estimatesMeasuredPulseAndUsesHalfTimeAbove170() {
        for (bpm in listOf(90.0, 120.0, 180.0)) {
            val energy =
                List(3000) { i ->
                    val phase = (i * .01) % (60 / bpm)
                    if (phase < .04) .7 * (1 - phase / .04) else .03
                }
            assertEquals(
                TempoDetector.preferred(bpm),
                requireNotNull(TempoDetector.estimate(energy)),
                2.0,
            )
        }
    }

    @Test
    fun silenceAndInvalidInputNeverInventTempo() {
        assertNull(TempoDetector.estimate(List(1000) { 0.0 }))
        assertNull(TempoDetector.estimate(List(1000) { Double.NaN }))
        assertNull(TempoDetector.estimate(List(20) { .5 }))
    }
}
