package com.tonyredondo.sonora

enum class PreparationStage {
    LYRICS,
    AUDIO,
    TAGS,
    TRANSLATION,
    MEANING,
    ALBUM,
    ARTWORK,
    PANORAMA,
}

enum class PreparationState {
    WAITING,
    RUNNING,
    READY,
    FAILED,
    OFFLINE,
    NEEDS_CONNECTION,
    UNAVAILABLE,
}

data class PreparationProgress(val state: PreparationState, val message: String = "")

data class SongExtras(
    val character: AudioCharacter? = null,
    val bpm: Double? = null,
    val headBeat: BeatGrid? = null,
    val tailBeat: BeatGrid? = null,
    val volume: VolumeMeasurement? = null,
    val volumeSupported: Boolean = false,
    val audioSource: String? = null,
    val waveform: List<Float> = emptyList(),
    val translation: Map<Int, String> = emptyMap(),
    val meaning: String? = null,
    val albumMeaning: String? = null,
    val styles: List<String> = emptyList(),
    val moods: List<String> = emptyList(),
    val generatedArtwork: String? = null,
    val panorama: String? = null,
    val progress: Map<PreparationStage, PreparationProgress> = emptyMap(),
)
