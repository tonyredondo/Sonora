package com.tonyredondo.sonora

import org.json.JSONArray
import org.json.JSONObject

enum class PlayerPage {
    ARTWORK,
    LYRICS,
    TRANSLATION,
    MEANING,
    ALBUM,
}

enum class RepeatMode {
    OFF,
    ALL,
    ONE,
}

/** Restoration is always paused. The index disambiguates repeated songs in a queue. */
data class PlaybackSnapshot(
    val ids: List<String> = emptyList(),
    val currentId: String? = null,
    val positionMs: Long = 0,
    val shuffle: Boolean = false,
    val repeat: RepeatMode = RepeatMode.OFF,
    val page: PlayerPage = PlayerPage.LYRICS,
    val currentIndex: Int = ids.indexOf(currentId),
) {
    val shouldAutoplay: Boolean
        get() = false

    fun encode(): String =
        JSONObject()
            .apply {
                put("version", 1)
                put("ids", JSONArray(ids))
                put("current", currentId ?: JSONObject.NULL)
                put("index", currentIndex)
                put("position", positionMs.coerceAtLeast(0))
                put("shuffle", shuffle)
                put("repeat", repeat.name)
                put("page", page.name)
            }
            .toString()

    companion object {
        fun decode(text: String): PlaybackSnapshot {
            try {
                require(text.toByteArray().size <= 4_000_000) {
                    "La cola guardada es demasiado grande."
                }
                val json = JSONObject(text)
                require(json.optInt("version", 1) == 1) {
                    "La cola guardada usa una versión incompatible."
                }
                val array = json.getJSONArray("ids")
                require(array.length() <= 20_000)
                val ids =
                    List(array.length()) { index ->
                        (array.get(index) as? String)?.also {
                            require(it.isNotBlank() && it.length <= 4096)
                        } ?: throw IllegalArgumentException("Una canción guardada no es válida.")
                    }
                val current = if (json.isNull("current")) null else json.getString("current")
                val index = json.optInt("index", ids.indexOf(current))
                require(
                    if (ids.isEmpty()) current == null && index == -1
                    else index in ids.indices && ids[index] == current,
                )
                return PlaybackSnapshot(
                    ids,
                    current,
                    json.optLong("position", 0).coerceAtLeast(0),
                    json.optBoolean("shuffle", false),
                    RepeatMode.valueOf(json.optString("repeat", "OFF")),
                    PlayerPage.valueOf(json.optString("page", "LYRICS")),
                    index,
                )
            } catch (error: Exception) {
                throw IllegalArgumentException("No se pudo recuperar la cola guardada.", error)
            }
        }
    }
}
