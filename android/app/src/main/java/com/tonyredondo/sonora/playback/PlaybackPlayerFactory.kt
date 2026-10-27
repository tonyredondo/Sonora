package com.tonyredondo.sonora

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioOutputProvider

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal object PlaybackPlayerFactory {
    fun create(
        context: Context,
        processor: ListeningAudioProcessor,
        handleFocus: Boolean,
        output: AudioOutputProvider? = null,
    ): ExoPlayer {
        return ExoPlayer.Builder(
                context,
                object : androidx.media3.exoplayer.DefaultRenderersFactory(context) {
                    override fun buildAudioSink(
                        context: android.content.Context,
                        enableFloatOutput: Boolean,
                        enableAudioOutputPlaybackParams: Boolean,
                    ): androidx.media3.exoplayer.audio.AudioSink {
                        val builder =
                            androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(context)
                                .setAudioProcessors(arrayOf(processor))
                                .setEnableFloatOutput(false)
                                .setEnableAudioOutputPlaybackParameters(false)

                        val sink =
                            (if (output != null) builder.setAudioOutputProvider(output)
                                else builder)
                                .build()
                        // Compressed passthrough/offload would skip the PCM effects and Sonic
                        // chain.
                        return object : androidx.media3.exoplayer.audio.ForwardingAudioSink(sink) {
                            override fun getFormatOffloadSupport(
                                format: androidx.media3.common.Format,
                            ): androidx.media3.exoplayer.audio.AudioOffloadSupport =
                                androidx.media3.exoplayer.audio.AudioOffloadSupport
                                    .DEFAULT_UNSUPPORTED

                            override fun supportsFormat(
                                format: androidx.media3.common.Format,
                            ): Boolean =
                                format.sampleMimeType == "audio/raw" && super.supportsFormat(format)

                            override fun getFormatSupport(
                                format: androidx.media3.common.Format,
                            ): Int =
                                if (format.sampleMimeType == "audio/raw")
                                    super.getFormatSupport(format)
                                else
                                    androidx.media3.exoplayer.audio.AudioSink
                                        .SINK_FORMAT_UNSUPPORTED
                        }
                    }
                },
            )
            .build()
            .apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                        .build(),
                    handleFocus,
                )
                setHandleAudioBecomingNoisy(true)
                setWakeMode(C.WAKE_MODE_LOCAL)
            }
    }
}
