package com.tonyredondo.sonora

import java.util.Locale

data class NormalizationResult(
    val multiplier: Double,
    val message: String,
    val neededIds: List<String> = emptyList(),
)

fun normalizationGain(
    mode: NormalizationMode,
    song: Song?,
    albumSongs: List<Song>,
    extras: Map<String, SongExtras>,
): NormalizationResult {
    if (mode == NormalizationMode.OFF) return NormalizationResult(1.0, "Desactivada")
    if (song == null) return NormalizationResult(1.0, "Elige una canción.")
    val tagged = ReplayGain.fromMetadata(song.metadata)
    val tagGain = if (mode == NormalizationMode.TRACK) tagged.trackGainDb else tagged.albumGainDb
    if (tagGain != null)
        return NormalizationResult(
            tagged.multiplier(mode),
            "ReplayGain · ${String.format(Locale.getDefault(),"%+.1f",tagGain)} dB",
        )
    if (mode == NormalizationMode.ALBUM && song.album.isBlank())
        return NormalizationResult(1.0, "Esta canción no tiene álbum.")
    val targets =
        if (mode == NormalizationMode.TRACK) listOf(song) else albumSongs.ifEmpty { listOf(song) }
    val needed =
        targets
            .filter { s ->
                val e = extras[s.id]
                e?.audioSource != audioSourceKey(s) ||
                    e.progress[PreparationStage.AUDIO]?.state !in
                        listOf(PreparationState.READY, PreparationState.FAILED)
            }
            .map { it.id }
    if (needed.isNotEmpty())
        return NormalizationResult(
            1.0,
            "Preparando el volumen ${if(mode==NormalizationMode.ALBUM) "del álbum" else "de la canción"}…",
            needed,
        )
    val failed = targets.firstNotNullOfOrNull {
        extras[it.id]?.progress?.get(PreparationStage.AUDIO)?.takeIf { p ->
            p.state == PreparationState.FAILED
        }
    }
    if (failed != null)
        return NormalizationResult(
            1.0,
            failed.message.ifBlank { "No se pudo analizar el volumen." },
        )
    if (targets.any { extras[it.id]?.volumeSupported != true })
        return NormalizationResult(1.0, "El volumen automático admite audio mono y estéreo.")
    val meters = targets.mapNotNull { extras[it.id]?.volume }
    val meter =
        if (mode == NormalizationMode.TRACK) meters.firstOrNull()
        else VolumeMeasurement.album(meters)
    if (meter == null) return NormalizationResult(1.0, "Audio sin sonoridad medible.")
    val gain = meter.gainDb()
    val replay = ReplayGain(gain, meter.peak, gain, meter.peak)
    return NormalizationResult(
        replay.multiplier(mode),
        "Análisis · ${String.format(Locale.getDefault(),"%+.1f",gain)} dB",
    )
}
