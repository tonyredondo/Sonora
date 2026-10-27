package com.tonyredondo.sonora

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.net.URI
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

fun validLocalAudioUri(text: String): Boolean =
    try {
        val uri = URI(text)
        when (uri.scheme?.lowercase()) {
            "content" -> !uri.authority.isNullOrBlank() && !uri.path.isNullOrBlank()
            "file" -> uri.authority.isNullOrEmpty() && uri.path?.startsWith('/') == true
            else -> false
        }
    } catch (_: Exception) {
        false
    }

fun compareNatural(left: String, right: String): Int {
    var a = 0
    var b = 0
    while (a < left.length && b < right.length) {
        if (left[a] in '0'..'9' && right[b] in '0'..'9') {
            var endA = a
            var endB = b
            while (endA < left.length && left[endA] in '0'..'9') endA++
            while (endB < right.length && right[endB] in '0'..'9') endB++
            var startA = a
            var startB = b
            while (startA < endA - 1 && left[startA] == '0') startA++
            while (startB < endB - 1 && right[startB] == '0') startB++
            val size = (endA - startA).compareTo(endB - startB)
            if (size != 0) return size
            for (offset in 0 until endA - startA) {
                val digit = left[startA + offset].compareTo(right[startB + offset])
                if (digit != 0) return digit
            }
            a = endA
            b = endB
        } else {
            val char = left[a].lowercaseChar().compareTo(right[b].lowercaseChar())
            if (char != 0) return char
            a++
            b++
        }
    }
    return (left.length - a).compareTo(right.length - b)
}

class LocalAudio(private val context: Context) {
    private val extensions =
        setOf(
            "mp3",
            "wav",
            "flac",
            "m4a",
            "aac",
            "alac",
            "aif",
            "aiff",
            "ogg",
            "opus",
            "wv",
            "tta",
            "caf",
        )

    suspend fun scanTree(uri: Uri, progress: (Int) -> Unit): List<Song> {
        val root =
            DocumentFile.fromTreeUri(context, uri)
                ?: error("No se pudo acceder a la carpeta elegida.")
        require(root.canRead()) { "No hay permiso de lectura para esta carpeta." }
        val files = linkedMapOf<String, DocumentFile>()
        val pending = ArrayDeque<Pair<String, DocumentFile>>()
        pending.add("" to root)
        val seen = hashSetOf<String>()
        var examined = 0
        while (pending.isNotEmpty()) {
            coroutineContext.ensureActive()
            val (prefix, folder) = pending.removeFirst()
            if (!seen.add(folder.uri.toString())) continue
            for (file in
                folder.listFiles().sortedWith { a, b ->
                    compareNatural(a.name.orEmpty(), b.name.orEmpty())
                }) {
                coroutineContext.ensureActive()
                require(++examined <= 20_000) { "La carpeta supera el límite de 20.000 entradas." }
                val name = file.name ?: continue
                require('/' !in name && name != "." && name != "..") {
                    "La carpeta contiene un nombre inválido."
                }
                val path = if (prefix.isEmpty()) name else "$prefix/$name"
                if (file.isDirectory) pending.add(path to file)
                else if (file.isFile) files[path] = file
            }
        }
        val audioPaths =
            files.keys.filter { it.substringAfterLast('.', "").lowercase() in extensions }.toSet()
        // Resolve only against the selected tree. A CUE string cannot grant access to siblings.
        val sheets =
            files
                .filterKeys { it.endsWith(".cue", true) }
                .map { (path, file) ->
                    require(file.length() <= 2_097_152) { "El archivo CUE es demasiado grande." }
                    val bytes =
                        context.contentResolver.openInputStream(file.uri)?.use {
                            it.readBytesBounded(2_097_152)
                        } ?: error("No se pudo leer $path.")
                    Triple(file, CueSheet.parse(bytes, path, audioPaths), contentDigest(bytes))
                }
        val referenced = sheets.flatMap { it.second }.map { it.path }.toSet()
        val sources = mutableMapOf<String, Song>()
        fun source(path: String): Song =
            sources.getOrPut(path) {
                val file = files.getValue(path)
                var song =
                    read(file.uri, uri.toString(), file.name, file.lastModified(), file.length())
                val lyricPath = path.substringBeforeLast('.') + ".lrc"
                val sidecar = files.entries.firstOrNull { it.key.equals(lyricPath, true) }?.value
                if (sidecar != null && sidecar.length() <= 1_000_000) {
                    context.contentResolver.openInputStream(sidecar.uri)?.use {
                        song =
                            song.copy(
                                lyricsText =
                                    it.readBytesBounded(1_000_000)
                                        .toString(Charsets.UTF_8)
                                        .removePrefix("\uFEFF"),
                            )
                    }
                }
                song
            }
        val result = mutableListOf<Song>()
        for (path in audioPaths) if (path !in referenced) {
            coroutineContext.ensureActive()
            result.add(source(path))
            progress(result.size)
        }
        for ((sheet, tracks, revision) in sheets) for (track in tracks) {
            coroutineContext.ensureActive()
            result.add(track.song(source(track.path), sheet.uri.toString(), revision))
            progress(result.size)
        }
        return result
    }

    fun read(
        uri: Uri,
        source: String = "",
        name: String? = null,
        modified: Long = 0,
        size: Long = 0,
    ): Song {
        require(validLocalAudioUri(uri.toString())) { "Sonora abre archivos locales de audio." }
        var filename = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "Audio"
        var bytes = size
        if (uri.scheme == "content" && name == null) {
            context.contentResolver
                .query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null,
                    null,
                    null,
                )
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (column >= 0 && !cursor.isNull(column))
                            filename = cursor.getString(column)
                        val count = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (count >= 0 && !cursor.isNull(count)) bytes = cursor.getLong(count)
                    }
                }
        }
        val id = contentDigest(uri.toString())
        var song =
            Song(
                id,
                uri.toString(),
                filename.substringBeforeLast('.').ifBlank { "Audio" },
                sourceId = source,
                modified =
                    if (modified != 0L) modified
                    else if (uri.scheme == "file") File(uri.path.orEmpty()).lastModified()
                    else DocumentFile.fromSingleUri(context, uri)?.lastModified() ?: 0L,
                size =
                    if (bytes != 0L) bytes
                    else if (uri.scheme == "file") File(uri.path.orEmpty()).length() else 0L,
                format = filename.substringAfterLast('.', "Audio").uppercase(),
            )
        val reader = MediaMetadataRetriever()
        try {
            // Some playable formats lack Android's metadata extractor. Keep the file
            // reference and its name; actual decoder errors remain visible at playback.
            try {
                reader.setDataSource(context, uri)
                fun value(key: Int) = reader.extractMetadata(key)?.trim().orEmpty()
                var artwork: String? = null
                reader.embeddedPicture
                    ?.takeIf { it.size <= 10_000_000 }
                    ?.let { image ->
                        val directory = File(context.filesDir, "artwork").apply { mkdirs() }
                        val key = contentDigest(image)
                        val destination = File(directory, "$key.image")
                        if (!destination.exists()) {
                            val temp = File.createTempFile("cover-", ".tmp", directory)
                            try {
                                temp.writeBytes(image)
                                check(temp.renameTo(destination)) {
                                    "No se pudo guardar la portada."
                                }
                            } finally {
                                temp.delete()
                            }
                        }
                        artwork = destination.absolutePath
                    }
                song =
                    song.copy(
                        title =
                            value(MediaMetadataRetriever.METADATA_KEY_TITLE).ifEmpty { song.title },
                        artist = value(MediaMetadataRetriever.METADATA_KEY_ARTIST),
                        album = value(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                        durationMs =
                            value(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                .toLongOrNull()
                                ?.coerceAtLeast(0) ?: 0,
                        trackNumber =
                            value(MediaMetadataRetriever.METADATA_KEY_CD_TRACK_NUMBER)
                                .substringBefore('/')
                                .toIntOrNull() ?: 0,
                        genre = value(MediaMetadataRetriever.METADATA_KEY_GENRE),
                        artworkPath = artwork,
                    )
            } catch (error: RuntimeException) {
                if (error is SecurityException) throw error
                // Android's retriever rejects some valid WAV variants. TagLib below still
                // reads their tags; playback/decoding reports unsupported audio explicitly.
            }
        } finally {
            reader.release()
        }
        if (song.format in setOf("MP3", "WAV", "AIFF", "AIF")) {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                val information = EmbeddedLyrics.readInformation(stream)
                val metadata = org.json.JSONObject(song.metadata)
                val tags = org.json.JSONObject(information.metadata)
                tags.keys().forEach { key -> metadata.put(key, tags.get(key)) }
                song = song.copy(lyricsText = information.lyrics, metadata = metadata.toString())
            }
        }
        // Borrow a seekable SAF descriptor: no audio import/copy, and no shared seek cursor.
        try {
            context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                val info =
                    org.json.JSONObject(
                        NativeAudio.inspect(
                            descriptor.parcelFileDescriptor.fd,
                            descriptor.startOffset,
                            descriptor.declaredLength,
                            song.format.lowercase(),
                        ),
                    )
                val fields = info.getJSONObject("fields")
                fun text(key: String) = fields.optJSONArray(key)?.optString(0).orEmpty()
                val metadata =
                    org.json
                        .JSONObject(song.metadata)
                        .put("native_fields", fields)
                        .put("native_custom", info.getJSONObject("custom"))
                for (key in
                    listOf(
                        "REPLAYGAIN_TRACK_GAIN",
                        "REPLAYGAIN_TRACK_PEAK",
                        "REPLAYGAIN_ALBUM_GAIN",
                        "REPLAYGAIN_ALBUM_PEAK",
                    )) {
                    text(key).takeIf(String::isNotBlank)?.let { metadata.put(key.lowercase(), it) }
                }
                var artwork = song.artworkPath
                if (artwork == null)
                    NativeAudio.artwork(
                            descriptor.parcelFileDescriptor.fd,
                            descriptor.startOffset,
                            descriptor.declaredLength,
                            song.format.lowercase(),
                        )
                        ?.let { image ->
                            val directory = File(context.filesDir, "artwork").apply { mkdirs() }
                            val destination = File(directory, "${contentDigest(image)}.image")
                            if (!destination.exists()) {
                                val temp = File.createTempFile("cover-", ".tmp", directory)
                                try {
                                    temp.writeBytes(image)
                                    check(temp.renameTo(destination)) {
                                        "No se pudo guardar la portada."
                                    }
                                } finally {
                                    temp.delete()
                                }
                            }
                            artwork = destination.absolutePath
                        }
                song =
                    song.copy(
                        title = text("TITLE").ifBlank { song.title },
                        artist = text("ARTIST").ifBlank { song.artist },
                        album = text("ALBUM").ifBlank { song.album },
                        genre = text("GENRE").ifBlank { song.genre },
                        trackNumber =
                            text("TRACKNUMBER").substringBefore('/').toIntOrNull()
                                ?: song.trackNumber,
                        lyricsText = text("LYRICS").ifBlank { song.lyricsText },
                        artworkPath = artwork,
                        durationMs =
                            info.optLong("durationMs").takeIf { it > 0 } ?: song.durationMs,
                        metadata = metadata.toString(),
                    )
            }
        } catch (_: java.io.IOException) {
            // Pipe-only providers and formats outside TagLib keep Android's metadata reader.
        }
        return song
    }
}

fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        require(output.size() + count <= limit) { "La letra es demasiado grande." }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
