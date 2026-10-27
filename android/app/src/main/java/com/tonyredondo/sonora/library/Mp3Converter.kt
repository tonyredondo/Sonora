package com.tonyredondo.sonora

import android.content.Context
import java.io.File

/** Decodes bounded, range-aware blocks; LAME finalizes only a completely encoded track. */
class Mp3Converter(private val context: Context) {
    suspend fun convert(song: Song, destination: File) {
        var handle = 0L
        var frames = 0L
        var format: PcmFormat? = null
        var complete = false
        try {
            PcmAudioReader(context)
                .read(
                    song,
                    600,
                    { value ->
                        require(value.channels in 1..2) {
                            "La conversión a MP3 admite audio mono o estéreo."
                        }
                        format = value
                        handle =
                            NativeAudio.encoderOpen(
                                destination.absolutePath,
                                value.rate,
                                value.channels,
                            )
                    },
                    { pcm ->
                        val count = pcm.size / requireNotNull(format).channels
                        NativeAudio.encoderWrite(handle, pcm, count)
                        frames += count
                    },
                )
            require(handle != 0L && frames > 0) { "La canción no contiene audio." }
            NativeAudio.encoderFinish(handle)
            handle = 0
            check(destination.length() > 0) { "No se pudo crear el MP3." }
            complete = true
        } finally {
            if (handle != 0L) NativeAudio.encoderAbort(handle)
            if (!complete) destination.delete()
        }
    }
}
