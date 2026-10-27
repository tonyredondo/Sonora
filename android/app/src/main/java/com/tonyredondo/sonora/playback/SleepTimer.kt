package com.tonyredondo.sonora

import org.json.JSONObject

data class SleepTimer(val deadlineMs: Long?, val songId: String?, val occurrenceIndex: Int?) {
    init {
        validate()
    }

    fun validate() {
        require(
            (deadlineMs != null && deadlineMs > 0 && songId == null && occurrenceIndex == null) ||
                (deadlineMs == null &&
                    !songId.isNullOrBlank() &&
                    songId.length <= 4096 &&
                    occurrenceIndex != null &&
                    occurrenceIndex >= 0),
        ) {
            "El temporizador guardado no es válido."
        }
    }

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("deadline", deadlineMs ?: JSONObject.NULL)
            .put("song", songId ?: JSONObject.NULL)
            .put("index", occurrenceIndex ?: JSONObject.NULL)
            .toString()
    }

    companion object {
        fun deadline(epochMs: Long) = SleepTimer(epochMs, null, null).also { it.validate() }

        fun endOfTrack(songId: String, index: Int) =
            SleepTimer(null, songId, index).also { it.validate() }

        fun decode(text: String): SleepTimer {
            require(text.toByteArray().size <= 8192)
            val v = JSONObject(text)
            require(v.getInt("version") == 1)
            return SleepTimer(
                    if (v.isNull("deadline")) null else v.getLong("deadline"),
                    if (v.isNull("song")) null else v.getString("song"),
                    if (v.isNull("index")) null else v.getInt("index"),
                )
                .also { it.validate() }
        }
    }
}
