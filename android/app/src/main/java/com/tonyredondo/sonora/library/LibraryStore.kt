package com.tonyredondo.sonora

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.UUID

/**
 * App-owned references and state only. Removing a row never removes source audio. Call on an IO
 * dispatcher.
 */
class LibraryStore(context: Context, name: String = "sonora.db") : AutoCloseable {
    private val helper =
        object : SQLiteOpenHelper(context.applicationContext, name, null, 1) {
                override fun onConfigure(db: SQLiteDatabase) {
                    db.setForeignKeyConstraintsEnabled(true)
                }

                override fun onCreate(db: SQLiteDatabase) {
                    db.execSQL(
                        """CREATE TABLE songs(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL,
                artist TEXT NOT NULL, album TEXT NOT NULL, duration INTEGER NOT NULL, track INTEGER NOT NULL,
                genre TEXT NOT NULL, artwork TEXT, lyrics TEXT NOT NULL, source TEXT NOT NULL,
                modified INTEGER NOT NULL, size INTEGER NOT NULL, favorite INTEGER NOT NULL DEFAULT 0,
                format TEXT NOT NULL, metadata TEXT NOT NULL, visible INTEGER NOT NULL)""",
                    )
                    db.execSQL("CREATE INDEX songs_album ON songs(artist,album,track)")
                    db.execSQL("CREATE TABLE playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL)")
                    db.execSQL(
                        """CREATE TABLE playlist_items(playlist TEXT REFERENCES playlists(id) ON DELETE CASCADE,
                position INTEGER NOT NULL, song TEXT NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
                PRIMARY KEY(playlist,position))""",
                    )
                    db.execSQL("CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                }

                override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
                    error("No se reconoce la versión de la biblioteca. Se conserva sin modificar.")
                }
            }
            .apply { setWriteAheadLoggingEnabled(true) }
    private val database: SQLiteDatabase
        get() = helper.writableDatabase

    private inline fun <T> transaction(action: (SQLiteDatabase) -> T): T {
        val db = database
        db.beginTransaction()
        try {
            val result = action(db)
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }

    fun saveSongs(songs: List<Song>, inLibrary: Boolean = true) = transaction { db ->
        songs.forEach { song ->
            require(song.id.isNotBlank() && song.uri.isNotBlank() && song.title.isNotBlank())
            require(song.lyricsText.toByteArray().size <= 1_000_000) {
                "La letra de ${song.title} es demasiado grande."
            }
            val old = this.song(song.id)
            val metadata = org.json.JSONObject(song.metadata)
            var effective = song
            val sameSource = old != null && lyricSourceRevision(old) == lyricSourceRevision(song)
            if (sameSource) {
                val prior = org.json.JSONObject(old!!.metadata)
                if (prior.optString("metadata_override_source") == lyricSourceRevision(song)) {
                    val draft = MetadataDraft.decode(prior.getJSONObject("metadata_override"))
                    effective = draft.apply(song)
                    metadata
                        .put("metadata_override_source", lyricSourceRevision(song))
                        .put("metadata_override", draft.encode())
                }
                val keys = mutableListOf("lyrics_override_source")
                if (
                    listOf(old.title, old.artist, old.album, old.genre) ==
                        listOf(effective.title, effective.artist, effective.album, effective.genre)
                )
                    keys += listOf("generated_artwork_path", "generated_artwork_key")
                keys.forEach { key -> if (prior.has(key)) metadata.put(key, prior.get(key)) }
            }
            val retainedLyrics =
                if (sameSource && old!!.hasLyricsOverride()) old.lyricsText else song.lyricsText
            val values =
                ContentValues().apply {
                    put("id", song.id)
                    put("uri", song.uri)
                    put("title", effective.title)
                    put("artist", effective.artist)
                    put("album", effective.album)
                    put("duration", song.durationMs)
                    put("track", effective.trackNumber)
                    put("genre", effective.genre)
                    put("artwork", song.artworkPath)
                    put("lyrics", retainedLyrics)
                    put("source", song.sourceId)
                    put("modified", song.modified)
                    put("size", song.size)
                    put("favorite", old?.favorite ?: song.favorite)
                    put("format", song.format)
                    put("metadata", metadata.toString())
                }
            // UPDATE preserves playlist foreign-key relationships; REPLACE would delete their rows.
            if (old != null) {
                if (inLibrary) values.put("visible", true)
                db.update("songs", values, "id=?", arrayOf(song.id))
            } else {
                values.put("visible", inLibrary)
                db.insertOrThrow("songs", null, values)
            }
        }
    }

    fun updateMetadata(source: Song, draft: MetadataDraft) = transaction { db ->
        draft.validate()
        val current = song(source.id) ?: error("La canción ya no está disponible.")
        check(
            lyricSourceRevision(current) == lyricSourceRevision(source) &&
                MetadataDraft.from(current) == MetadataDraft.from(source),
        ) {
            "La información cambió mientras la editabas. Vuelve a abrirla antes de guardar."
        }
        val edited = draft.apply(current)
        val metadata =
            org.json
                .JSONObject(current.metadata)
                .put("metadata_override_source", lyricSourceRevision(current))
                .put("metadata_override", draft.encode())
        if (
            listOf(edited.title, edited.artist, edited.album, edited.genre) !=
                listOf(current.title, current.artist, current.album, current.genre)
        ) {
            metadata.remove("generated_artwork_key")
            metadata.remove("generated_artwork_path")
        }
        val values =
            ContentValues().apply {
                put("title", edited.title)
                put("artist", edited.artist)
                put("album", edited.album)
                put("genre", edited.genre)
                put("track", edited.trackNumber)
                put("metadata", metadata.toString())
            }
        check(db.update("songs", values, "id=?", arrayOf(source.id)) == 1)
    }

    fun updateLyrics(source: Song, text: String) = transaction { db ->
        val id = source.id
        val expected = source.lyricsText
        require(text.toByteArray().size <= 1_000_000) { "La letra es demasiado grande." }
        val song = this.song(id) ?: error("La canción ya no está disponible.")
        check(lyricSourceRevision(song) == lyricSourceRevision(source)) {
            "El archivo de audio ha cambiado. Vuelve a abrir la letra antes de guardar."
        }
        check(song.lyricsText == expected) {
            "La letra ha cambiado mientras la editabas. Vuelve a abrirla antes de guardar."
        }
        val metadata =
            org.json
                .JSONObject(song.metadata)
                .put("lyrics_override_source", lyricSourceRevision(song))
        val values =
            ContentValues().apply {
                put("lyrics", text)
                put("metadata", metadata.toString())
            }
        check(db.update("songs", values, "id=? AND lyrics=?", arrayOf(id, expected)) == 1)
    }

    fun setGeneratedArtwork(id: String, path: String, key: String) = transaction { db ->
        val song = this.song(id) ?: error("La canción ya no está disponible.")
        val metadata =
            org.json
                .JSONObject(song.metadata)
                .put("generated_artwork_path", path)
                .put("generated_artwork_key", key)
        db.update(
            "songs",
            ContentValues().apply { put("metadata", metadata.toString()) },
            "id=?",
            arrayOf(id),
        )
    }

    fun songs(): List<Song> =
        database
            .rawQuery(
                "SELECT * FROM songs WHERE visible=1 ORDER BY artist COLLATE NOCASE,album COLLATE NOCASE,track,title COLLATE NOCASE",
                null,
            )
            .use { cursor ->
                buildList { while (cursor.moveToNext()) add(cursor.song()) }
            }

    fun albumSongs(artist: String, album: String): List<Song> =
        database
            .rawQuery(
                "SELECT * FROM songs WHERE artist=? COLLATE NOCASE AND album=? COLLATE NOCASE ORDER BY track,title COLLATE NOCASE",
                arrayOf(artist, album),
            )
            .use { cursor ->
                buildList { while (cursor.moveToNext()) add(cursor.song()) }
            }

    fun song(id: String): Song? =
        database.rawQuery("SELECT * FROM songs WHERE id=?", arrayOf(id)).use {
            if (it.moveToFirst()) it.song() else null
        }

    fun removeSongs(ids: List<String>) = transaction { db ->
        ids.forEach { db.delete("songs", "id=?", arrayOf(it)) }
        Unit
    }

    fun setFavorite(id: String, favorite: Boolean) {
        val values =
            ContentValues().apply {
                put("favorite", favorite)
                if (favorite) put("visible", true)
            }
        require(database.update("songs", values, "id=?", arrayOf(id)) == 1)
    }

    fun createPlaylist(name: String): String {
        val clean = name.trim()
        require(clean.isNotEmpty() && clean.length <= 200)
        val id = UUID.randomUUID().toString()
        database.insertOrThrow(
            "playlists",
            null,
            ContentValues().apply {
                put("id", id)
                put("name", clean)
            },
        )
        return id
    }

    fun renamePlaylist(id: String, name: String) {
        val clean = name.trim()
        require(clean.isNotEmpty() && clean.length <= 200)
        require(
            database.update(
                "playlists",
                ContentValues().apply { put("name", clean) },
                "id=?",
                arrayOf(id),
            ) == 1,
        )
    }

    fun removePlaylist(id: String) {
        database.delete("playlists", "id=?", arrayOf(id))
    }

    fun setPlaylistSongs(id: String, ids: List<String>) = transaction { db ->
        require(ids.size <= 20_000)
        require(
            db.rawQuery("SELECT id FROM playlists WHERE id=?", arrayOf(id)).use {
                it.moveToFirst()
            },
        )
        val unique = ids.distinct()
        val found =
            unique.chunked(800).sumOf { chunk ->
                db.rawQuery(
                        "SELECT COUNT(*) FROM songs WHERE id IN (${chunk.joinToString(",") { "?" }})",
                        chunk.toTypedArray(),
                    )
                    .use {
                        it.moveToFirst()
                        it.getInt(0)
                    }
            }
        require(found == unique.size) {
            "La lista contiene canciones que ya no están en la biblioteca."
        }
        db.delete("playlist_items", "playlist=?", arrayOf(id))
        ids.forEachIndexed { index, song ->
            db.insertOrThrow(
                "playlist_items",
                null,
                ContentValues().apply {
                    put("playlist", id)
                    put("position", index)
                    put("song", song)
                },
            )
        }
    }

    fun playlists(): List<MusicPlaylist> =
        database.rawQuery("SELECT id,name FROM playlists ORDER BY name COLLATE NOCASE", null).use {
            cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val ids =
                        database
                            .rawQuery(
                                "SELECT song FROM playlist_items WHERE playlist=? ORDER BY position",
                                arrayOf(id),
                            )
                            .use { entries ->
                                buildList { while (entries.moveToNext()) add(entries.getString(0)) }
                            }
                    add(MusicPlaylist(id, cursor.getString(1), ids))
                }
            }
        }

    fun saveSnapshot(snapshot: PlaybackSnapshot) = putState("playback", snapshot.encode())

    fun snapshot(): PlaybackSnapshot? = state("playback")?.let(PlaybackSnapshot::decode)

    fun state(key: String): String? =
        database.rawQuery("SELECT value FROM state WHERE key=?", arrayOf(key)).use {
            if (it.moveToFirst()) it.getString(0) else null
        }

    fun putState(key: String, value: String) {
        database.insertWithOnConflict(
            "state",
            null,
            ContentValues().apply {
                put("key", key)
                put("value", value)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    override fun close() = helper.close()

    private fun Cursor.song(): Song {
        fun string(key: String) = getString(getColumnIndexOrThrow(key))
        fun number(key: String) = getLong(getColumnIndexOrThrow(key))
        return Song(
            string("id"),
            string("uri"),
            string("title"),
            string("artist"),
            string("album"),
            number("duration"),
            number("track").toInt(),
            string("genre"),
            getColumnIndexOrThrow("artwork").let { if (isNull(it)) null else getString(it) },
            string("lyrics"),
            string("source"),
            number("modified"),
            number("size"),
            number("favorite") != 0L,
            string("format"),
            string("metadata"),
        )
    }
}
