package com.tonyredondo.sonora

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.*
import org.json.JSONObject

enum class PlaylistExportFormat {
    ORIGINAL,
    MP3,
}

data class PlaylistExportResult(val files: Int, val playlistName: String)

/** Prepare privately, then publish directly into the selected folder and verify every byte. */
class PlaylistExporter(private val context: Context, private val store: LibraryStore) {
    private data class Item(val file: File, val name: String, val mime: String, val digest: String)

    suspend fun export(
        songs: List<Song>,
        name: String,
        folder: Uri,
        format: PlaylistExportFormat,
        progress: (String) -> Unit = {},
    ): PlaylistExportResult {
        val root =
            if (folder.scheme == "file") DocumentFile.fromFile(File(requireNotNull(folder.path)))
            else
                DocumentFile.fromTreeUri(context, folder)
                    ?: error("No se pudo abrir la carpeta elegida.")
        return exportToFolder(songs, name, root, format, progress)
    }

    internal suspend fun exportToFolder(
        songs: List<Song>,
        name: String,
        root: DocumentFile,
        format: PlaylistExportFormat,
        progress: (String) -> Unit = {},
    ): PlaylistExportResult =
        withContext(Dispatchers.IO) {
            require(songs.isNotEmpty() && songs.size <= 1000) {
                "La lista debe contener entre 1 y 1.000 canciones."
            }
            check(root.isDirectory && root.canWrite()) {
                "No hay permiso para guardar en esta carpeta."
            }
            val stage = File(context.cacheDir, "playlist-export-${UUID.randomUUID()}")
            check(stage.mkdir()) { "No se pudo preparar la exportación." }
            val created = mutableListOf<DocumentFile>()
            var complete = false
            try {
                val initial = root.listFiles()
                val existingUris = initial.map { it.uri }.toSet()
                val names =
                    initial.mapNotNull { it.name?.lowercase(java.util.Locale.ROOT) }.toMutableSet()
                fun unique(base: String, extension: String): String {
                    var index = 1
                    while (true) {
                        val stem = if (index == 1) base else "$base ($index)"
                        val candidate = "$stem.$extension"
                        val companions =
                            listOf(
                                candidate,
                                "$stem.lrc",
                                "$stem.txt",
                                "$stem.cover.png",
                                "$stem.cover.jpg",
                                "$stem.sonora.json",
                            )
                        if (companions.none { it.lowercase(java.util.Locale.ROOT) in names }) {
                            names += companions.map { it.lowercase(java.util.Locale.ROOT) }
                            return candidate
                        }
                        index++
                    }
                }
                val prepared = mutableListOf<Item>()
                val tracks = mutableListOf<Pair<Song, String>>()
                var totalBytes = 0L
                songs.forEachIndexed { index, song ->
                    coroutineContext.ensureActive()
                    progress("Preparando ${index+1} de ${songs.size}: ${song.title}")
                    val source = Uri.parse(song.uri)
                    require(validLocalAudioUri(song.uri)) { "La canción no es un archivo local." }
                    val extension =
                        if (format == PlaylistExportFormat.MP3) "mp3"
                        else if (song.cueSegment() != null) "wav" else song.format.lowercase()
                    require(
                        extension in
                            setOf(
                                "mp3",
                                "wav",
                                "aif",
                                "aiff",
                                "flac",
                                "m4a",
                                "alac",
                                "ogg",
                                "opus",
                                "wv",
                                "tta",
                            ),
                    ) {
                        "No se puede exportar la metadata del formato ${song.format}."
                    }
                    val filename =
                        unique(
                            "${(index+1).toString().padStart(maxOf(2,songs.size.toString().length),'0')} - ${safeName(song.title)}",
                            extension,
                        )
                    val target = File(stage, filename)
                    val before = sourceIdentity(source)
                    if (
                        format == PlaylistExportFormat.MP3 &&
                            (song.format.uppercase() != "MP3" || song.cueSegment() != null)
                    )
                        Mp3Converter(context).convert(song, target)
                    else if (song.cueSegment() != null) CueWavExporter(context).export(song, target)
                    else
                        context.contentResolver.openInputStream(source)?.use { input ->
                            target.outputStream().use { output ->
                                val buffer = ByteArray(64 * 1024)
                                var count: Int
                                var copied = 0L
                                while (input.read(buffer).also { count = it } >= 0) {
                                    coroutineContext.ensureActive()
                                    copied += count
                                    require(
                                        copied <= 2_147_483_648L &&
                                            stage.usableSpace > 16 * 1024 * 1024,
                                    ) {
                                        "No hay espacio suficiente para exportar esta lista."
                                    }
                                    output.write(buffer, 0, count)
                                }
                            }
                        } ?: error("No se pudo leer ${song.title}.")
                    check(before == sourceIdentity(source)) {
                        "El archivo ${song.title} cambió durante la exportación."
                    }
                    check(target.length() > 0) { "El archivo ${song.title} está vacío." }
                    val fields = linkedMapOf<String, Array<String>>()
                    val metadata = JSONObject(song.metadata)
                    for (kind in listOf("native_fields", "native_custom")) metadata
                        .optJSONObject(kind)
                        ?.let { all ->
                            all.keys().forEach { key ->
                                all.optJSONArray(key)?.let { values ->
                                    fields[key] = Array(values.length()) { values.getString(it) }
                                }
                            }
                        }
                    fields["TITLE"] = arrayOf(song.title)
                    fields["ARTIST"] = arrayOf(song.artist)
                    fields["ALBUM"] = arrayOf(song.album)
                    fields["GENRE"] = arrayOf(song.genre)
                    fields["LYRICS"] =
                        if (song.lyricsText.isBlank()) emptyArray() else arrayOf(song.lyricsText)
                    if (song.trackNumber > 0)
                        fields["TRACKNUMBER"] = arrayOf(song.trackNumber.toString())
                    // Retain only identity-matched interpretations, including every saved language.
                    fields.keys
                        .toList()
                        .filter {
                            it.startsWith("SONORA_SONG_ABOUT", true) ||
                                it.startsWith("SONORA_ALBUM_ABOUT", true)
                        }
                        .forEach { fields[it] = emptyArray() }
                    fields.putAll(PortableInterpretations.export(store, song))
                    var copiedPictures = 0
                    if (
                        song.cueSegment() != null ||
                            (format == PlaylistExportFormat.MP3 && song.format.uppercase() != "MP3")
                    )
                        context.contentResolver.openAssetFileDescriptor(source, "r")?.use {
                            descriptor ->
                            copiedPictures =
                                NativeAudio.copyPictures(
                                    descriptor.parcelFileDescriptor.fd,
                                    descriptor.startOffset,
                                    descriptor.declaredLength,
                                    song.format.lowercase(),
                                    target.absolutePath,
                                )
                        }
                    val cover =
                        (if (
                                copiedPictures > 0 ||
                                    (song.artworkPath != null &&
                                        (song.cueSegment() == null &&
                                            (format == PlaylistExportFormat.ORIGINAL ||
                                                song.format.uppercase() == "MP3")))
                            )
                                null
                            else song.displayArtworkPath())
                            ?.let(::File)
                            ?.takeIf { it.isFile && it.length() in 1..10_000_000 }
                            ?.readBytes()
                    NativeAudio.writeTags(
                        target.absolutePath,
                        fields.keys.toTypedArray(),
                        fields.values.toTypedArray(),
                        cover,
                    )
                    totalBytes += target.length()
                    require(
                        totalBytes <= 4L * 1024 * 1024 * 1024 &&
                            stage.usableSpace > 16 * 1024 * 1024,
                    ) {
                        "La lista es demasiado grande para el espacio disponible."
                    }
                    val mime =
                        if (extension == "mp3") "audio/mpeg"
                        else if (extension == "wav") "audio/wav" else "audio/$extension"
                    prepared += Item(target, filename, mime, digest(target.inputStream()))
                    tracks += song to filename
                }
                coroutineContext.ensureActive()
                val manifestName = unique(safeName(name), "m3u8")
                val manifest = File(stage, manifestName)
                manifest.writeText(
                    buildString {
                        append("#EXTM3U\n")
                        for ((song, filename) in tracks) {
                            append(
                                "#EXTINF:${song.durationMs/1000},${song.artist.replace(Regex("[\\r\\n]")," ")} - ${song.title.replace(Regex("[\\r\\n]")," ")}\n$filename\n",
                            )
                        }
                    },
                    Charsets.UTF_8,
                )
                prepared +=
                    Item(
                        manifest,
                        manifestName,
                        "application/vnd.apple.mpegurl",
                        digest(manifest.inputStream()),
                    )
                for ((index, item) in prepared.withIndex()) {
                    coroutineContext.ensureActive()
                    progress("Guardando ${index+1} de ${prepared.size}")
                    val document =
                        if (root.uri.scheme == "file") {
                            val file = File(requireNotNull(root.uri.path), item.name)
                            check(file.createNewFile()) {
                                "Ya existe ${item.name}. No se ha sobrescrito."
                            }
                            DocumentFile.fromFile(file)
                        } else
                            root.createFile(item.mime, item.name)
                                ?: error("No se pudo crear ${item.name}.")
                    check(
                        document.uri !in existingUris && created.none { it.uri == document.uri },
                    ) {
                        "El proveedor devolvió un archivo existente. No se ha sobrescrito."
                    }
                    created += document
                    check(document.name == item.name) {
                        "El proveedor cambió el nombre de ${item.name}. Vuelve a exportar en una carpeta distinta."
                    }
                    context.contentResolver.openOutputStream(document.uri, "wt")?.use { output ->
                        item.file.inputStream().use { input ->
                            val buffer = ByteArray(64 * 1024)
                            var count: Int
                            while (input.read(buffer).also { count = it } >= 0) {
                                coroutineContext.ensureActive()
                                output.write(buffer, 0, count)
                            }
                        }
                        output.flush()
                    } ?: error("No se pudo escribir ${item.name}.")
                    check(
                        digest(
                            context.contentResolver.openInputStream(document.uri)
                                ?: error("No se pudo verificar ${item.name}."),
                        ) == item.digest,
                    ) {
                        "La copia de ${item.name} no se pudo verificar."
                    }
                }
                complete = true
                PlaylistExportResult(songs.size, manifestName)
            } finally {
                withContext(NonCancellable + Dispatchers.IO) {
                    val failed =
                        if (!complete) created.asReversed().filter { !it.delete() } else emptyList()
                    val stageRemoved = stage.deleteRecursively()
                    if (failed.isNotEmpty())
                        throw java.io.IOException(
                            "La exportación no terminó. No se pudieron retirar ${failed.size} archivos incompletos de la carpeta elegida.",
                        )
                    if (!stageRemoved)
                        throw java.io.IOException(
                            "La copia terminó, pero no se pudo retirar la preparación temporal de la exportación.",
                        )
                }
            }
        }

    private fun sourceIdentity(uri: Uri): Pair<Long, Long> =
        if (uri.scheme == "file")
            File(requireNotNull(uri.path)).let { it.length() to it.lastModified() }
        else
            DocumentFile.fromSingleUri(context, uri)?.let { it.length() to it.lastModified() }
                ?: error("El archivo de origen ya no está disponible.")

    companion object {
        fun safeName(value: String): String {
            var clean =
                value.replace(Regex("[\\p{Cntrl}\\\\/:*?\"<>|]"), " ").trim().trim('.').ifBlank {
                    "Playlist"
                }
            while (clean.toByteArray().size > 180) clean =
                clean.dropLast(Character.charCount(clean.codePointBefore(clean.length)))
            return clean
        }

        private suspend fun digest(input: java.io.InputStream): String = input.use {
            val digest = MessageDigest.getInstance("SHA-256")
            val bytes = ByteArray(64 * 1024)
            var count: Int
            while (it.read(bytes).also { count = it } >= 0) {
                coroutineContext.ensureActive()
                digest.update(bytes, 0, count)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
