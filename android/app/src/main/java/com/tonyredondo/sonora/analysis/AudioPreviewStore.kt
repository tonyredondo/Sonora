package com.tonyredondo.sonora

import android.content.Context
import android.util.AtomicFile
import java.io.File

fun audioSourceKey(song: Song): String =
    contentDigest(
        "${song.uri}|${song.modified}|${song.size}|${song.durationMs}${song.cueSourceSuffix()}",
    )

class AudioPreviewStore(context: Context) {
    private val root = File(context.filesDir, "audio-previews-v1")

    fun read(song: Song): ByteArray? {
        return try {
            AtomicFile(File(root, "${audioSourceKey(song)}.wav")).openRead().use { stream ->
                val bytes = stream.readBytes()
                if (bytes.size in 32044..2_880_044) bytes else null
            }
        } catch (_: java.io.FileNotFoundException) {
            null
        }
    }

    fun write(song: Song, bytes: ByteArray) {
        if (bytes.size !in 32044..2_880_044) return
        check(root.isDirectory || root.mkdirs()) { "No se pudo guardar la muestra de audio." }
        val file = AtomicFile(File(root, "${audioSourceKey(song)}.wav"))
        val output = file.startWrite()
        try {
            output.write(bytes)
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }
}
