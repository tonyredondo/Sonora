package com.tonyredondo.sonora

import org.json.JSONObject

data class MetadataDraft(
    val title: String,
    val artist: String,
    val album: String,
    val genre: String,
    val trackNumber: Int,
) {
    fun validate() {
        require(title.isNotBlank()) { "Escribe un título." }
        require(
            listOf(title, artist, album, genre).all {
                it.toByteArray().size <= 4096 && it.none(Char::isISOControl)
            },
        ) {
            "Los campos no pueden contener saltos de línea ni superar 4 KB."
        }
        require(trackNumber in 0..9999) { "El número de pista debe estar entre 0 y 9999." }
    }

    fun apply(song: Song): Song {
        validate()
        return song.copy(
            title = title.trim(),
            artist = artist.trim(),
            album = album.trim(),
            genre = genre.trim(),
            trackNumber = trackNumber,
        )
    }

    fun encode(): JSONObject =
        JSONObject()
            .put("title", title.trim())
            .put("artist", artist.trim())
            .put("album", album.trim())
            .put("genre", genre.trim())
            .put("trackNumber", trackNumber)

    companion object {
        fun from(song: Song) =
            MetadataDraft(song.title, song.artist, song.album, song.genre, song.trackNumber)

        fun decode(value: JSONObject) =
            MetadataDraft(
                    value.getString("title"),
                    value.getString("artist"),
                    value.getString("album"),
                    value.getString("genre"),
                    value.getInt("trackNumber"),
                )
                .also { it.validate() }
    }
}
