package com.tonyredondo.sonora

data class LyricLine(val id: Int, val timeMs: Long?, val text: String)

data class LyricsDocument(
    val lines: List<LyricLine>,
    val isAITranscribed: Boolean,
    val isAIRepaired: Boolean,
    val editableLines: List<LyricLine> = lines,
    val headers: List<String> = emptyList(),
) {
    val isTimed: Boolean
        get() = lines.any { it.timeMs != null }

    fun activeLine(positionMs: Long, userOffsetMs: Long = 0): Int? {
        if (!isTimed) return null
        val displayTime = positionMs.toDouble() - userOffsetMs.toDouble() + 250
        var low = 0
        var high = lines.size
        while (low < high) {
            val middle = (low + high) / 2
            if ((lines[middle].timeMs?.toDouble() ?: Double.POSITIVE_INFINITY) <= displayTime)
                low = middle + 1
            else high = middle
        }
        return if (low == 0) null else low - 1
    }

    val plainText: String
        get() = lines.joinToString("\n") { it.text }

    companion object {
        private val timestamp = Regex("\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?]")
        private val information =
            Regex("^\\[(ar|al|ti|au|by|re|ve|length|offset):.*]$", RegexOption.IGNORE_CASE)
        private val offset = Regex("\\[offset:([+-]?\\d+)]", RegexOption.IGNORE_CASE)

        internal fun offsetTag(text: String): String = offset.find(text)?.value.orEmpty()

        fun parse(text: String): LyricsDocument {
            require(text.toByteArray().size <= 1_000_000) { "La letra es demasiado grande." }
            val input = text.removePrefix("\uFEFF")
            val adjustment = offset.find(input)?.groupValues?.get(1)?.toLongOrNull() ?: 0
            val timed = mutableListOf<Pair<Long, String>>()
            val plain = mutableListOf<String>()
            val entries = mutableListOf<Pair<Long?, String>>()
            val raw = input.lineSequence().map(String::trim).toList()
            for (line in raw) {
                if (line.isEmpty() || information.matches(line)) continue
                val matches = timestamp.findAll(line).toList()
                val times = matches.mapNotNull { match ->
                    val minutes = match.groupValues[1].toLong()
                    val seconds = match.groupValues[2].toLong()
                    if (seconds >= 60) null
                    else {
                        val fraction = match.groupValues[3].padEnd(3, '0').toLongOrNull() ?: 0
                        (minutes * 60_000 + seconds * 1000 + fraction - adjustment).coerceAtLeast(0)
                    }
                }
                if (times.isEmpty()) {
                    plain.add(line)
                    entries.add(null to line)
                } else {
                    val content = timestamp.replace(line, "").trim()
                    times.forEach {
                        timed.add(it to content)
                        entries.add(it to content)
                    }
                }
            }
            val lines =
                if (timed.isEmpty()) plain.mapIndexed { id, line -> LyricLine(id, null, line) }
                else
                    timed
                        .sortedBy { it.first }
                        .mapIndexed { id, (time, content) -> LyricLine(id, time, content) }
            return LyricsDocument(
                lines,
                raw.any { it == "[by:Sonora AI transcription - ElevenLabs]" },
                raw.any { it == "[by:Sonora AI repair - ElevenLabs]" },
                if (plain.isNotEmpty() && timed.isNotEmpty())
                    entries.mapIndexed { index, (time, value) -> LyricLine(index, time, value) }
                else lines,
                raw.filter { information.matches(it) && !offset.containsMatchIn(it) },
            )
        }
    }
}
