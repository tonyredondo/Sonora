package com.tonyredondo.sonora

import org.junit.Assert.*
import org.junit.Test

class SoundSettingsTest {
    @Test
    fun independentSpeedAndPitchRoundTripAndRejectInvalidValues() {
        val settings = SoundSettings(.8f, 1.5f)
        assertEquals(settings, SoundSettings.decode(settings.encode()))
        assertThrows(IllegalArgumentException::class.java) {
            SoundSettings(Float.NaN, 1f).validate()
        }
        assertThrows(IllegalArgumentException::class.java) { SoundSettings(1f, 0f).validate() }
        assertThrows(IllegalArgumentException::class.java) {
            SoundSettings.decode("{\"version\":2,\"speed\":1,\"pitch\":1}")
        }
    }
}
