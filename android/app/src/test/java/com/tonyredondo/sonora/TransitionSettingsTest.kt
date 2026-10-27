package com.tonyredondo.sonora

import kotlin.math.abs
import org.junit.Assert.*
import org.junit.Test

class TransitionSettingsTest {
    @Test
    fun settingsAreBoundedAndRoundtrip() {
        for (mode in TransitionMode.entries) {
            val value = TransitionSettings(mode, 5)
            assertEquals(value, TransitionSettings.decode(value.encode()))
        }
        for (seconds in listOf(0, 13, Int.MAX_VALUE)) try {
            TransitionSettings(TransitionMode.CROSSFADE, seconds).validate()
            fail()
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun estimatedTempoStillShapesTheOverlapAndDoesNotTrimAnUnknownIntro() {
        val plan =
            TransitionPlanner.plan(
                TransitionSettings(TransitionMode.ADAPTIVE, 5),
                20.0,
                30.0,
                121.0,
                null,
                null,
                null,
            )
        assertEquals(0.0, plan.incomingSkip, 0.0)
        assertTrue(plan.duration in 4.4..5.0)
        assertEquals(
            0.0,
            plan.duration / (60.0 / 121) -
                kotlin.math.floor(plan.duration / (60.0 / 121) + .00000001),
            .0000001,
        )
        assertTrue(plan.estimated)
    }

    @Test
    fun beatAlignmentAcceptsEstimatedPhasesAndBoundsTempoDrift() {
        val outgoing = BeatGrid(.5, .12, .6)
        val incoming = BeatGrid(.501, .22, .5)
        val plan =
            TransitionPlanner.plan(
                TransitionSettings(TransitionMode.ADAPTIVE, 5),
                30.0,
                30.0,
                120.0,
                119.76,
                outgoing,
                incoming,
            )
        assertEquals(.22, plan.incomingSkip, .000001)
        assertTrue(plan.duration <= 5)
        assertEquals(
            0.0,
            abs(
                ((30 - plan.duration) - .12) / .5 -
                    kotlin.math.round(((30 - plan.duration) - .12) / .5),
            ),
            .000001,
        )
        assertTrue(plan.estimated)
        val shortened =
            TransitionPlanner.plan(
                TransitionSettings(TransitionMode.ADAPTIVE, 12),
                40.0,
                40.0,
                120.0,
                117.65,
                BeatGrid(.5, 0.0, .5),
                BeatGrid(.51, 0.0, .5),
            )
        assertTrue(shortened.duration <= 3.75)
    }

    @Test
    fun sourceDurationCapsOverlapAndUnsuitableBeatGridUsesCrossfade() {
        val plan =
            TransitionPlanner.plan(
                TransitionSettings(TransitionMode.CROSSFADE, 12),
                4.0,
                3.0,
                null,
                null,
                null,
                null,
            )
        assertEquals(1.5, plan.duration, 0.0)
        val fallback =
            TransitionPlanner.plan(
                TransitionSettings(TransitionMode.ADAPTIVE, 5),
                20.0,
                20.0,
                null,
                null,
                null,
                null,
            )
        assertEquals(5.0, fallback.duration, 0.0)
        assertFalse(fallback.aligned)
    }
}
