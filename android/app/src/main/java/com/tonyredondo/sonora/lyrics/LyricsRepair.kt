package com.tonyredondo.sonora

import java.util.Locale
import kotlin.math.*

/**
 * Immutable word comparison, matching the iPhone review contract. Unrecognized source words stay
 * unless explicitly edited. UTF-16 anchors apply to the original snapshot, never a prior draft.
 */
class LyricsRepair(val original: String, transcript: LyricsTranscript) {
    enum class Kind {
        CORRECTION,
        COMPLETION,
        TIMING,
        UNRECOGNIZED,
    }

    data class Edit(val text: String, val startTime: Double? = null)

    internal data class Anchor(
        val first: Int,
        val start: Int,
        val last: Int,
        val end: Int,
        val insert: Boolean = false,
        val separate: Boolean = false,
    )

    class Proposal
    internal constructor(
        val id: Int,
        val kind: Kind,
        val original: String,
        val suggested: String,
        val context: String,
        val start: Double?,
        val originalStart: Double?,
        val end: Double?,
        val insertsLines: Boolean,
        internal val anchor: Anchor,
        internal val times: List<Double>,
    )

    class TimingIssue(
        val proposalIds: List<Int>,
        val fragment: String,
        val start: Double?,
        val minimum: Double,
        val maximum: Double,
    ) :
        IllegalArgumentException(
            "El fragmento «${fragment.take(120)}» debe empezar entre ${"%.2f".format(minimum)} y ${"%.2f".format(maximum)} segundos.",
        )

    private data class Line(val text: String, val time: Double?, val timingSource: Int? = null)

    private data class Original(
        val lines: List<Line>,
        val headers: List<String>,
        val timed: Boolean,
    )

    private data class Token(
        val text: String,
        val key: String,
        val line: Int,
        val start: Int,
        val end: Int,
        var time: Double?,
        var finish: Double?,
    )

    val proposals: List<Proposal>
    val usesPhraseTiming = transcript.words == null
    val isTimed: Boolean
    private val lines: List<Line>
    private val headers: List<String>
    private val duration = transcript.duration

    init {
        transcript.validate()
        val state = parseOriginal(original, duration)
        lines = state.lines
        headers = state.headers
        isTimed = state.timed
        val parsed = lines
        val sourceLines =
            LyricsDocument.parse(transcript.syncedText).lines.map {
                Line(it.text, it.timeMs!! / 1000.0)
            }
        val base = tokens(parsed)
        val source = tokens(sourceLines)
        require(base.size + source.size <= 12000) {
            "La revisión admite hasta 12.000 palabras entre ambos textos."
        }
        transcript.words?.let { words ->
            var wordIndex = 0
            var wordOffset = 0
            var position = 0
            val lengths = words.map {
                lyricKey(it.text).codePointCount(0, lyricKey(it.text).length)
            }
            for (token in source) {
                while (wordIndex + 1 < words.size && wordOffset + lengths[wordIndex] <= position) {
                    wordOffset += lengths[wordIndex]
                    wordIndex++
                }
                val end = position + token.key.codePointCount(0, token.key.length)
                var last = wordIndex
                var endOffset = wordOffset + lengths[wordIndex]
                while (last + 1 < words.size && endOffset < end) {
                    last++
                    endOffset += lengths[last]
                }
                token.time = words[wordIndex].start
                token.finish = words[last].end
                position = end
            }
        }
        val useClock = isTimed && transcript.words != null
        val timedLines = parsed.mapIndexedNotNull { index, line -> line.time?.let { index to it } }
        fun owner(token: Token) =
            timedLines.lastOrNull { it.second <= (token.time ?: 0.0) + .03 }?.first ?: -1
        val shared =
            if (isTimed && transcript.words == null)
                timedLines
                    .map { (it.second * 1000).roundToLong() }
                    .intersect(
                        sourceLines
                            .mapNotNull { it.time?.let { time -> (time * 1000).roundToLong() } }
                            .toSet(),
                    )
                    .sorted()
            else emptyList()
        fun window(token: Token) = shared.indexOfLast {
            it <= ((token.time ?: 0.0) * 1000).roundToLong()
        }
        fun compare(token: Token) = token.text.replace('’', '\'').lowercase(Locale.ROOT)
        val aKeys = base.map {
            compare(it) + (if (isTimed) "\u0000${if(useClock) it.line else window(it)}" else "")
        }
        val bKeys = source.map {
            compare(it) + (if (isTimed) "\u0000${if(useClock) owner(it) else window(it)}" else "")
        }
        val matches = matches(aKeys, bKeys)
        val sourceOwners = mutableMapOf<Int, MutableSet<Int>>()
        val matchedLines = mutableSetOf<Int>()
        val sourceCounts = source.groupingBy { it.line }.eachCount()
        for ((a, b) in matches) {
            sourceOwners.getOrPut(source[b].line) { mutableSetOf() }.add(base[a].line)
            matchedLines.add(base[a].line)
        }
        val result = mutableListOf<Proposal>()
        fun add(
            kind: Kind,
            anchor: Anchor,
            text: String,
            suggested: String,
            targets: List<Int>,
            startOverride: Double? = null,
        ) {
            if (kind == Kind.CORRECTION && text.trim() == suggested.trim()) return
            val first = targets.firstOrNull()?.let(source::get)
            val last = targets.lastOrNull()?.let(source::get)
            val context =
                if (anchor.first < parsed.size)
                    parsed.subList(anchor.first, minOf(anchor.last + 1, parsed.size)).joinToString(
                        "\n",
                    ) {
                        it.text
                    }
                else "Final de la letra"
            val times = targets.map { source[it] }.distinctBy { it.line }.mapNotNull { it.time }
            val end =
                if (kind == Kind.UNRECOGNIZED && isTimed)
                    parsed.drop(anchor.last + 1).firstOrNull { it.time != null }?.time ?: duration
                else last?.finish ?: first?.time?.let { min(duration, it + 4) }
            result.add(
                Proposal(
                    result.size,
                    kind,
                    text,
                    suggested,
                    context,
                    startOverride ?: first?.time ?: parsed.getOrNull(anchor.first)?.time,
                    parsed.getOrNull(anchor.first)?.time,
                    end,
                    anchor.separate,
                    anchor,
                    times,
                ),
            )
        }
        val boundaries = listOf(-1 to -1) + matches + listOf(base.size to source.size)
        for ((previous, next) in boundaries.zipWithNext()) {
            val a = (previous.first + 1 until next.first).toList()
            val b = (previous.second + 1 until next.second).toList()
            if (a.isEmpty() && b.isEmpty()) continue
            val affected = a.map { base[it].line }.toSet()
            val rest = b.toMutableList()
            val previousLine = base.getOrNull(previous.first)?.line
            val nextLine = base.getOrNull(next.first)?.line
            val sameNeighbor = previousLine != null && previousLine == nextLine
            if (a.isEmpty()) {
                for (lineIndex in b.map { source[it].line }.distinct().sorted()) {
                    val group = b.filter { source[it].line == lineIndex }
                    val owners = sourceOwners[lineIndex].orEmpty()
                    if (
                        !sameNeighbor && owners.isEmpty() && group.size == sourceCounts[lineIndex]
                    ) {
                        val before = nextLine ?: parsed.size
                        add(
                            Kind.COMPLETION,
                            Anchor(before, 0, before, 0, true, true),
                            "",
                            sourceLines[lineIndex].text,
                            group,
                        )
                    } else {
                        val line =
                            (nextLine?.takeIf { it in owners }
                                ?: previousLine?.takeIf { it in owners })
                                ?: nextLine
                                ?: previousLine
                                ?: 0
                        val offset =
                            if (line == nextLine) base[next.first].start
                            else parsed[line].text.length
                        add(
                            Kind.COMPLETION,
                            Anchor(line, offset, line, offset, true),
                            "",
                            fragment(source, group, sourceLines),
                            group,
                        )
                    }
                }
                continue
            }
            val separate = !sameNeighbor && affected.size == 1 && matchedLines.containsAll(affected)
            if (separate)
                for (lineIndex in rest.map { source[it].line }.distinct().sorted()) {
                    val owners = sourceOwners[lineIndex].orEmpty()
                    val line = owners.singleOrNull() ?: continue
                    if (line in affected || (line != previousLine && line != nextLine)) continue
                    val group = rest.filter { source[it].line == lineIndex }
                    val offset =
                        if (line == nextLine) base[next.first].start else parsed[line].text.length
                    add(
                        Kind.COMPLETION,
                        Anchor(line, offset, line, offset, true),
                        "",
                        fragment(source, group, sourceLines),
                        group,
                    )
                    rest.removeAll { source[it].line == lineIndex }
                }
            val within = rest.all { affected.containsAll(sourceOwners[source[it].line].orEmpty()) }
            if (separate && within)
                for (lineIndex in rest.map { source[it].line }.distinct().sorted()) {
                    if (sourceOwners[lineIndex].orEmpty().isNotEmpty()) continue
                    val group = rest.filter { source[it].line == lineIndex }
                    if (group.size != sourceCounts[lineIndex]) continue
                    val before =
                        matches
                            .firstOrNull { it.second > (group.lastOrNull() ?: -1) }
                            ?.let { base[it.first].line } ?: parsed.size
                    add(
                        Kind.COMPLETION,
                        Anchor(before, 0, before, 0, true, true),
                        "",
                        sourceLines[lineIndex].text,
                        group,
                    )
                    rest.removeAll { source[it].line == lineIndex }
                }
            if (
                isTimed &&
                    affected.size > 1 &&
                    matchedLines.containsAll(affected) &&
                    a.size == rest.size
            ) {
                var offset = 0
                for (line in affected.sorted()) {
                    val group = a.filter { base[it].line == line }
                    val targets = rest.subList(offset, offset + group.size).toList()
                    val first = base[group.first()]
                    val last = base[group.last()]
                    add(
                        Kind.CORRECTION,
                        Anchor(line, first.start, line, last.end),
                        fragment(base, group, parsed),
                        fragment(source, targets, sourceLines).replace('\n', ' '),
                        targets,
                    )
                    offset += group.size
                }
                continue
            }
            val originalRest = a.toMutableList()
            val anchored = affected.intersect(matchedLines)
            if (
                anchored.size == 1 &&
                    rest.isNotEmpty() &&
                    rest.all { sourceOwners[source[it].line].orEmpty() == anchored }
            ) {
                val line = anchored.single()
                for (omitted in
                    listOf(affected.filter { it < line }, affected.filter { it > line })) if (
                    omitted.isNotEmpty()
                ) {
                    val first = omitted.min()
                    val last = omitted.max()
                    val text = parsed.subList(first, last + 1).joinToString("\n") { it.text }
                    add(
                        Kind.UNRECOGNIZED,
                        Anchor(first, 0, last, parsed[last].text.length),
                        text,
                        text,
                        emptyList(),
                    )
                }
                originalRest.removeAll { base[it].line != line }
            }
            if (originalRest.isNotEmpty()) {
                val first = base[originalRest.first()]
                val last = base[originalRest.last()]
                val text = fragment(base, originalRest, parsed)
                add(
                    if (rest.isEmpty()) Kind.UNRECOGNIZED else Kind.CORRECTION,
                    Anchor(first.line, first.start, last.line, last.end),
                    text,
                    if (rest.isEmpty()) text else fragment(source, rest, sourceLines),
                    rest,
                )
            }
        }
        if (isTimed && transcript.words != null) {
            val wordKeys = source.map(::compare)
            val groups = base.indices.groupBy { base[it].line }
            val matchedSource = matches.toMap()
            val matchedOwner = matches.associate { it.second to base[it.first].line }
            val originalKeys = groups.mapValues { (_, indices) ->
                indices.map { compare(base[it]) }
            }
            val occurrences =
                originalKeys.values.groupingBy { it.joinToString("\u0000") }.eachCount()
            for ((lineIndex, indices) in groups.toSortedMap()) {
                val keys = originalKeys.getValue(lineIndex)
                val originalTime = parsed[lineIndex].time ?: continue
                if (
                    result.any {
                        it.kind in setOf(Kind.CORRECTION, Kind.COMPLETION) &&
                            !it.anchor.separate &&
                            it.anchor.first <= lineIndex &&
                            it.anchor.last >= lineIndex &&
                            (it.anchor.first < lineIndex || it.anchor.start == 0)
                    }
                )
                    continue
                val anchors = indices.mapIndexedNotNull { offset, index ->
                    matchedSource[index]?.let { offset to it }
                }
                val candidates =
                    source.indices.filter { start ->
                        start + keys.size <= source.size &&
                            wordKeys.subList(start, start + keys.size) == keys &&
                            anchors.all { start + it.first == it.second } &&
                            (start until start + keys.size).all {
                                matchedOwner[it] == null || matchedOwner[it] == lineIndex
                            }
                    }
                val start = candidates.singleOrNull() ?: continue
                if (anchors.isEmpty() && occurrences[keys.joinToString("\u0000")] != 1) continue
                val wordTime = source[start].time ?: continue
                val scaled = wordTime * 100
                val nearest = scaled.roundToLong().toDouble()
                val proposed =
                    (if (abs(scaled - nearest) <= Math.ulp(scaled) * 2) nearest
                    else floor(scaled)) / 100
                if ((originalTime * 100).roundToLong() == (proposed * 100).roundToLong()) continue
                val line = parsed[lineIndex]
                add(
                    Kind.TIMING,
                    Anchor(lineIndex, 0, lineIndex, line.text.length),
                    line.text,
                    line.text,
                    (start until start + keys.size).toList(),
                    proposed,
                )
            }
        }
        proposals = result.toList()
    }

    fun applying(edits: Map<Int, Edit>, onlyCompletions: Boolean = false): String {
        require(edits.keys.all { it in proposals.indices }) {
            "La selección ya no corresponde a esta revisión."
        }
        var output = lines.toMutableList()
        var changed = false
        val selected =
            proposals
                .filter { it.id in edits && (!onlyCompletions || it.kind == Kind.COMPLETION) }
                .sortedWith(
                    compareByDescending<Proposal> { it.anchor.first }
                        .thenByDescending { it.anchor.start }
                        .thenBy { it.anchor.separate }
                        .thenByDescending { it.id },
                )
        for (proposal in selected) {
            val edit = edits.getValue(proposal.id)
            val anchor = proposal.anchor
            val text = edit.text.trim()
            require(
                text.toByteArray().size <= 65536 &&
                    '\u0000' !in text &&
                    !lyricControls.containsMatchIn(text),
            ) {
                "El cambio contiene controles LRC o texto no válido."
            }
            if (proposal.kind == Kind.TIMING) {
                require(text == proposal.original.trim())
                val start = edit.startTime ?: proposal.start
                if (start == null || !start.isFinite() || start !in 0.0..duration)
                    throw TimingIssue(listOf(proposal.id), text, start, 0.0, duration)
                if (
                    output[anchor.first].time?.let { (it * 100).roundToLong() } ==
                        (start * 100).roundToLong()
                )
                    continue
                output[anchor.first] =
                    output[anchor.first].copy(time = start, timingSource = proposal.id)
                changed = true
                continue
            }
            if (text == proposal.original.trim()) continue
            if (anchor.separate) {
                if (text.isEmpty()) continue
                val start = edit.startTime ?: proposal.start
                if (isTimed && (start == null || !start.isFinite() || start !in 0.0..duration))
                    throw TimingIssue(listOf(proposal.id), text, start, 0.0, duration)
                val delta = (start ?: 0.0) - (proposal.start ?: 0.0)
                output.addAll(
                    anchor.first,
                    editedLines(text, start, proposal.times.map { it + delta }).map {
                        it.copy(timingSource = proposal.id)
                    },
                )
            } else {
                val first = output[anchor.first]
                val last = output[anchor.last]
                val originalRange = output.subList(anchor.first, anchor.last + 1).toList()
                val prefix = first.text.take(anchor.start)
                val suffix = last.text.substring(anchor.end)
                var replacement = text
                if (anchor.insert && replacement.isNotEmpty()) {
                    if (prefix.lastOrNull()?.isWhitespace() == false) replacement = " $replacement"
                    if (suffix.firstOrNull()?.isWhitespace() == false) replacement += " "
                }
                val times =
                    if (proposal.kind == Kind.UNRECOGNIZED)
                        originalRange.filter { it.text.isNotBlank() }.mapNotNull { it.time }
                    else proposal.times
                val added =
                    editedLines(prefix + replacement + suffix, first.time, times)
                        .mapIndexed { index, line ->
                            line.copy(
                                timingSource = if (index == 0) first.timingSource else proposal.id,
                            )
                        }
                        .toMutableList()
                for (pause in originalRange.filter { it.text.isEmpty() && it.time != null }) {
                    val index =
                        added.indices.drop(1).firstOrNull {
                            (added[it].time ?: Double.POSITIVE_INFINITY) >= pause.time!!
                        } ?: added.size
                    added.add(index, pause)
                }
                output.subList(anchor.first, anchor.last + 1).clear()
                output.addAll(anchor.first, added)
            }
            changed = true
        }
        if (!changed) return original
        if (isTimed) {
            val cues =
                output
                    .withIndex()
                    .filter {
                        it.value.time?.isFinite() == true && wordPattern.find(it.value.text) == null
                    }
                    .sortedWith(compareBy<IndexedValue<Line>> { it.value.time }.thenBy { it.index })
            val indices = cues.map { it.index }.toSet()
            val ordered = mutableListOf<Line>()
            var next = 0
            for ((index, line) in output.withIndex()) if (index !in indices) {
                line.time?.let { time ->
                    while (
                        next < cues.size &&
                            (cues[next].value.time!! < time ||
                                (cues[next].value.time == time && cues[next].index < index))
                    ) {
                        ordered.add(cues[next++].value)
                    }
                }
                ordered.add(line)
            }
            ordered.addAll(cues.drop(next).map { it.value })
            output = ordered
            val timed = output.filter { it.time != null || it.text.isNotBlank() }
            for ((index, line) in timed.withIndex()) {
                val time = line.time
                if (time == null || !time.isFinite() || time !in 0.0..duration)
                    throw TimingIssue(
                        listOfNotNull(line.timingSource),
                        line.text,
                        time,
                        0.0,
                        duration,
                    )
                if (index > 0 && time < timed[index - 1].time!!) {
                    val prior = timed[index - 1]
                    val minimum = timed.getOrNull(index - 2)?.time ?: 0.0
                    val usePrior =
                        prior.timingSource != null && (line.timingSource == null || minimum <= time)
                    val culprit = if (usePrior) prior else line
                    throw TimingIssue(
                        listOfNotNull(
                                culprit.timingSource,
                                if (usePrior) line.timingSource else prior.timingSource,
                            )
                            .distinct(),
                        culprit.text,
                        culprit.time,
                        if (usePrior) minimum else prior.time!!,
                        if (usePrior) time else timed.getOrNull(index + 1)?.time ?: duration,
                    )
                }
            }
        }
        val rendered = output.map { line ->
            if (isTimed && line.time != null) {
                val ticks = (line.time * 100).roundToLong()
                "[%02d:%02d.%02d]"
                    .format(Locale.ROOT, ticks / 6000, ticks / 100 % 60, ticks % 100) + line.text
            } else line.text
        }
        val text = (listOf(repairMarker) + headers + rendered).joinToString("\n")
        require(text.toByteArray().size <= 65536)
        val visible = LyricsDocument.parse(text).lines
        val expected = output.filter { it.time != null || it.text.isNotBlank() }
        require(
            visible.size == expected.size &&
                visible.zip(expected).all { (a, b) ->
                    a.text == b.text.trim() &&
                        a.timeMs ==
                            (if (isTimed) b.time?.let { (it * 100).roundToLong() * 10 } else null)
                },
        ) {
            "El cambio formaría controles LRC con el texto de alrededor."
        }
        return text
    }

    private fun editedLines(text: String, firstTime: Double?, times: List<Double>): List<Line> {
        var index = 0
        var previous = firstTime
        val result =
            text
                .split('\n')
                .map { line ->
                    if (line.isBlank()) Line(line, null)
                    else {
                        val time =
                            if (isTimed)
                                (if (index == 0) firstTime else times.getOrNull(index) ?: previous)
                            else null
                        index++
                        previous = time
                        Line(line, time)
                    }
                }
                .toMutableList()
        if (isTimed && index == 0) result[0] = result[0].copy(time = firstTime)
        return result
    }

    companion object {
        private val wordPattern = Regex("[\\p{L}\\p{M}\\p{N}]+(?:['’][\\p{L}\\p{M}\\p{N}]+)*")
        private val information =
            Regex(
                "^(?:\\[(?:ar|al|ti|au|by|re|ve|length|offset):[^]]*])+\\s*$",
                RegexOption.IGNORE_CASE,
            )
        private val offset = Regex("\\[offset:[^]]*]", RegexOption.IGNORE_CASE)

        fun validateOriginal(text: String, duration: Double) {
            val parsed = parseOriginal(text, duration)
            require(tokens(parsed.lines).size <= 12000)
        }

        private fun parseOriginal(text: String, duration: Double): Original {
            require(
                duration.isFinite() &&
                    duration in 1.0..600.0 &&
                    text.toByteArray().size <= 65536 &&
                    '\u0000' !in text,
            ) {
                "La revisión admite una letra de hasta 65 KB y audio de uno a diez minutos."
            }
            val raw = text.split('\n')
            val metadata = raw.filter { information.matches(it.trim()) }
            val offsetTag = LyricsDocument.offsetTag(text)
            var expanded = false
            var parsed = mutableListOf<Line>()
            for (line in raw) {
                if (line in metadata) continue
                if (line.isBlank()) {
                    parsed.add(Line(line, null))
                    continue
                }
                val values = LyricsDocument.parse("$offsetTag\n$line").lines
                expanded = expanded || values.size > 1
                parsed.addAll(values.map { Line(it.text, it.timeMs?.div(1000.0)) })
            }
            val content = parsed.filter { it.text.isNotBlank() }
            require(content.isNotEmpty()) { "Añade una letra antes de repararla." }
            val timed = parsed.any { it.time != null }
            require(!timed || content.all { it.time != null }) {
                "La letra mezcla frases con tiempos y sin tiempos. Unifica su formato en Editar letra."
            }
            if (timed) {
                val times = parsed.mapNotNull { it.time }
                require(times.all { it.isFinite() && it in 0.0..duration }) {
                    "La letra contiene tiempos fuera del audio."
                }
                if (expanded || times.zipWithNext().any { it.first > it.second })
                    parsed =
                        parsed
                            .withIndex()
                            .sortedWith(
                                compareBy<IndexedValue<Line>> {
                                        it.value.time ?: Double.POSITIVE_INFINITY
                                    }
                                    .thenBy { it.index },
                            )
                            .map { it.value }
                            .toMutableList()
            }
            val headers =
                metadata
                    .map { offset.replace(it, "").trim() }
                    .filter { it.isNotEmpty() && it != repairMarker && information.matches(it) }
            return Original(parsed, headers, timed)
        }

        private fun tokens(lines: List<Line>): List<Token> = lines.flatMapIndexed { index, line ->
            wordPattern
                .findAll(line.text)
                .map { match ->
                    Token(
                        match.value,
                        lyricKey(match.value),
                        index,
                        match.range.first,
                        match.range.last + 1,
                        line.time,
                        lines.getOrNull(index + 1)?.time,
                    )
                }
                .toList()
        }

        private fun fragment(tokens: List<Token>, indices: List<Int>, lines: List<Line>): String {
            if (indices.isEmpty()) return ""
            val first = tokens[indices.first()]
            val last = tokens[indices.last()]
            if (first.line == last.line)
                return lines[first.line].text.substring(first.start, last.end)
            return (listOf(lines[first.line].text.substring(first.start)) +
                    lines.subList(first.line + 1, last.line).map { it.text } +
                    lines[last.line].text.take(last.end))
                .joinToString("\n")
        }

        /** Hirschberg LCS keeps memory linear for the bounded 12k-word comparison. */
        private fun matches(a: List<String>, b: List<String>): List<Pair<Int, Int>> {
            val result = mutableListOf<Pair<Int, Int>>()
            val deadline = System.nanoTime() + 10_000_000_000L
            fun scores(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int, reverse: Boolean): IntArray {
                val width = bEnd - bStart
                var previous = IntArray(width + 1)
                var row = IntArray(width + 1)
                for (i in 0 until aEnd - aStart) {
                    if (i % 64 == 0)
                        check(System.nanoTime() < deadline) {
                            "La comparación tardó demasiado. Revisa una letra más corta."
                        }
                    val x = a[if (reverse) aEnd - 1 - i else aStart + i]
                    for (j in 1..width) row[j] =
                        if (x == b[if (reverse) bEnd - j else bStart + j - 1]) previous[j - 1] + 1
                        else max(previous[j], row[j - 1])
                    val swap = previous
                    previous = row
                    row = swap
                    row.fill(0)
                }
                return previous
            }
            fun recurse(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int) {
                if (aStart == aEnd || bStart == bEnd) return
                if (aEnd - aStart == 1) {
                    val index = (bStart until bEnd).firstOrNull { b[it] == a[aStart] }
                    if (index != null) result.add(aStart to index)
                    return
                }
                val middle = (aStart + aEnd) / 2
                fun split(): Int {
                    val left = scores(aStart, middle, bStart, bEnd, false)
                    val right = scores(middle, aEnd, bStart, bEnd, true)
                    val width = bEnd - bStart
                    return (0..width).maxBy { left[it] + right[width - it] }
                }
                val pivot = bStart + split()
                recurse(aStart, middle, bStart, pivot)
                recurse(middle, aEnd, pivot, bEnd)
            }
            recurse(0, a.size, 0, b.size)
            return result
        }
    }
}
