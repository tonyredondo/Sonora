package com.tonyredondo.sonora

import org.json.JSONObject

data class SoundSettings(val speed: Float = 1f, val pitch: Float = 1f) {
    fun validate() {
        require(speed.isFinite() && speed in .5f..2f && pitch.isFinite() && pitch in .5f..2f) {
            "La velocidad y la tonalidad guardadas no son válidas."
        }
    }

    fun encode(): String {
        validate()
        return JSONObject()
            .put("version", 1)
            .put("speed", speed.toDouble())
            .put("pitch", pitch.toDouble())
            .toString()
    }

    companion object {
        fun decode(text: String): SoundSettings {
            require(text.toByteArray().size <= 4096)
            val value = JSONObject(text)
            require(value.getInt("version") == 1) {
                "Esta versión de los ajustes de sonido no es compatible."
            }
            return SoundSettings(
                    value.getDouble("speed").toFloat(),
                    value.getDouble("pitch").toFloat(),
                )
                .also { it.validate() }
        }
    }
}
