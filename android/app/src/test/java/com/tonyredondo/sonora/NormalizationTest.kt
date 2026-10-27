package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class NormalizationTest {
    private val song =
        Song("one", "content://qa/one", "One", "Artist", "Album", size = 10, modified = 100)
    private val next = song.copy(id = "two", uri = "content://qa/two")
    private val measured = VolumeMeasurement(listOf(.01, .01), .5)

    private fun extra(s: Song, volume: VolumeMeasurement? = measured) =
        SongExtras(
            volume = volume,
            volumeSupported = true,
            audioSource = audioSourceKey(s),
            progress = mapOf(PreparationStage.AUDIO to PreparationProgress(PreparationState.READY)),
        )

    @Test
    fun explicitReplayGainTakesPriorityAndMissingMeasurementsAreRequestedWithoutInventingGain() {
        val tagged =
            song.copy(metadata = ReplayGain(trackGainDb = 12.0, trackPeak = .8).toMetadata())
        assertEquals(
            1.25,
            normalizationGain(NormalizationMode.TRACK, tagged, listOf(tagged), emptyMap())
                .multiplier,
            1e-8,
        )
        val missing =
            normalizationGain(
                NormalizationMode.ALBUM,
                song,
                listOf(song, next),
                mapOf(song.id to extra(song)),
            )
        assertEquals(listOf(next.id), missing.neededIds)
        assertEquals(1.0, missing.multiplier, 0.0)
        val silence =
            normalizationGain(
                NormalizationMode.ALBUM,
                song,
                listOf(song, next),
                mapOf(song.id to extra(song), next.id to extra(next, null)),
            )
        assertEquals(
            ReplayGain(albumGainDb = measured.gainDb(), albumPeak = .5)
                .multiplier(NormalizationMode.ALBUM),
            silence.multiplier,
            1e-8,
        )
    }

    @Test
    fun staleOrFailedMeasurementsCannotBeUsedOrRetriedInAnEndlessLoop() {
        val stale =
            normalizationGain(
                NormalizationMode.TRACK,
                song,
                listOf(song),
                mapOf(song.id to extra(song).copy(audioSource = "old")),
            )
        assertEquals(listOf(song.id), stale.neededIds)
        val failed =
            extra(song)
                .copy(
                    volume = null,
                    volumeSupported = false,
                    progress =
                        mapOf(
                            PreparationStage.AUDIO to
                                PreparationProgress(PreparationState.FAILED, "No se pudo leer"),
                        ),
                )
        val result =
            normalizationGain(NormalizationMode.TRACK, song, listOf(song), mapOf(song.id to failed))
        assertTrue(result.neededIds.isEmpty())
        assertEquals(1.0, result.multiplier, 0.0)
        assertTrue(result.message.contains("No se pudo leer"))
    }
}
