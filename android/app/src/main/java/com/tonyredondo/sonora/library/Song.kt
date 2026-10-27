package com.tonyredondo.sonora

import java.security.MessageDigest
import org.json.JSONObject

data class Song(
    val id: String,
    val uri: String,
    val title: String,
    val artist: String = "",
    val album: String = "",
    val durationMs: Long = 0,
    val trackNumber: Int = 0,
    val genre: String = "",
    val artworkPath: String? = null,
    val lyricsText: String = "",
    val sourceId: String = "",
    val modified: Long = 0,
    val size: Long = 0,
    val favorite: Boolean = false,
    val format: String = "",
    val metadata: String = "{}",
) {
    private val generatedArtworkPath: String? =
        try {
            JSONObject(metadata).optString("generated_artwork_path").takeIf(String::isNotBlank)
        } catch (_: Exception) {
            null
        }

    fun displayArtworkPath(): String? = artworkPath ?: generatedArtworkPath

    fun hasLyricsOverride(): Boolean =
        try {
            JSONObject(metadata).optString("lyrics_override_source") == lyricSourceRevision(this)
        } catch (_: Exception) {
            false
        }
}

data class MusicPlaylist(val id: String, val name: String, val songIds: List<String>)

fun contentDigest(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

fun contentDigest(text: String): String = contentDigest(text.toByteArray(Charsets.UTF_8))

internal fun JSONObject.nullableString(key: String): String? =
    if (isNull(key)) null else getString(key)

fun lyricSourceRevision(song: Song): String =
    contentDigest(
        "${song.uri}|${song.modified}|${song.size}${song.cueSourceSuffix()}${song.cueSegment()?.let { "|sheet:${it.sheetRevision}" }.orEmpty()}",
    )
