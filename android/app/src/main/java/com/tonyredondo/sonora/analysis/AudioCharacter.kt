package com.tonyredondo.sonora

import org.json.JSONObject

data class CharacterStyle(val label: String, val score: Double)

data class AudioCharacter(
    val silent: Boolean,
    val styles: List<CharacterStyle>,
    val moods: Map<String, Double>,
) {
    val prominentMoods: List<String>
        get() {
            val strongest =
                moods
                    .filterValues { it >= .6 }
                    .entries
                    .sortedByDescending { it.value }
                    .take(2)
                    .map { it.key }
                    .toSet()
            return listOf("happy", "sad", "relaxed", "aggressive").filter { it in strongest }
        }

    companion object {
        const val VERSION = "essentia-discogs-v1"

        fun parse(value: JSONObject): AudioCharacter {
            try {
                require(value.getString("version") == VERSION)
                val array = value.getJSONArray("styles")
                require(array.length() <= 8)
                val styles =
                    (0 until array.length()).map { index ->
                        val item = array.getJSONObject(index)
                        val label = item.getString("label")
                        require(
                            label.isNotBlank() &&
                                label.toByteArray().size <= 200 &&
                                label.none { it.isISOControl() },
                        )
                        CharacterStyle(
                            label,
                            item.getDouble("score").also {
                                require(it.isFinite() && it in 0.0..1.0)
                            },
                        )
                    }
                require(styles.map { it.label }.distinct().size == styles.size)
                val silent = value.getBoolean("silent")
                require(silent == styles.isEmpty())
                val raw = value.getJSONObject("moods")
                val names = listOf("happy", "sad", "relaxed", "aggressive")
                require(raw.keys().asSequence().toSet() == names.toSet())
                val moods = names.associateWith {
                    raw.getDouble(it).also { score ->
                        require(score.isFinite() && score in 0.0..1.0)
                    }
                }
                return AudioCharacter(silent, styles, moods)
            } catch (failure: Exception) {
                throw ProxyFailure("audio_character_invalid_response")
            }
        }
    }
}

fun styleLabel(label: String): String =
    when (val name = label.substringAfterLast("---")) {
        "Alternative Rock" -> "Rock alternativo"
        "Electronic" -> "Electrónica"
        "Classical" -> "Clásica"
        else -> name
    }

fun moodLabel(label: String): String =
    when (label) {
        "happy" -> "Alegre"
        "sad" -> "Triste"
        "relaxed" -> "Relajada"
        "aggressive" -> "Agresiva"
        else -> label
    }
