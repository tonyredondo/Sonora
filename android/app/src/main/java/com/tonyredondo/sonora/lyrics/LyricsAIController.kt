package com.tonyredondo.sonora

import java.util.Locale
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

internal enum class LyricsAIMode(val label: String) {
    ALIGN("Sincronizar"),
    TRANSCRIBE("Transcribir"),
    REPAIR("Reparar"),
}

internal data class RepairEditDraft(val text: String, val time: String)

internal data class LyricsAIState(
    val source: Song,
    val draft: String,
    val mode: LyricsAIMode,
    val loading: Boolean = false,
    val phase: String = "",
    val issue: String? = null,
    val cached: Boolean = false,
    val warning: String? = null,
    val review: LyricsRepair? = null,
    val edits: Map<Int, RepairEditDraft> = emptyMap(),
    val onlyCompletions: Boolean = false,
    val candidate: String? = null,
    val preview: Boolean = false,
    val problemIds: List<Int> = emptyList(),
)

/**
 * ViewModel-owned review survives rotation. Only the explicit Use action changes the editor draft.
 */
internal class LyricsAIController(
    private val graph: AppGraph,
    private val scope: CoroutineScope,
    private val apply: (Song, String, String) -> Boolean,
    private val stopPreview: () -> Unit,
) {
    val state = MutableStateFlow<LyricsAIState?>(null)
    private var operation: Job? = null
    @Volatile private var generation = 0

    fun open(source: Song, draft: String, mode: LyricsAIMode) {
        close()
        state.value = LyricsAIState(source, draft, mode)
    }

    fun close() {
        generation++
        operation?.cancel()
        operation = null
        state.value = null
        stopPreview()
    }

    fun cancelAnalysis() {
        generation++
        operation?.cancel()
        operation = null
        state.update { it?.copy(loading = false, phase = "Análisis cancelado") }
    }

    fun analyze() {
        val before = state.value ?: return
        if (before.loading) return
        val ticket = ++generation
        state.value =
            before.copy(
                loading = true,
                issue = null,
                phase = "Preparando análisis…",
                problemIds = emptyList(),
            )
        operation = scope.launch {
            try {
                if (before.mode == LyricsAIMode.REPAIR)
                    withContext(Dispatchers.Default) {
                        LyricsRepair.validateOriginal(
                            before.draft,
                            before.source.durationMs / 1000.0,
                        )
                    }
                val client =
                    LyricsAnalysisClient(graph.application, graph.store, graph.online) { phase ->
                        state.update { if (generation == ticket) it?.copy(phase = phase) else it }
                    }
                val after =
                    when (before.mode) {
                        LyricsAIMode.ALIGN ->
                            client.align(before.source, before.draft).let {
                                before.copy(
                                    candidate = it.text,
                                    preview = true,
                                    cached = it.cached,
                                    warning = it.warning,
                                )
                            }
                        LyricsAIMode.TRANSCRIBE,
                        LyricsAIMode.REPAIR -> {
                            val result = client.transcribe(before.source)
                            val transcript = result.transcript
                            if (transcript == null)
                                before.copy(
                                    issue =
                                        if (result.warning == null)
                                            "No se han encontrado palabras en el audio. El resultado queda guardado para evitar repetir el análisis."
                                        else
                                            "No se han encontrado palabras en el audio. No se pudo guardar este resultado.",
                                    cached = result.cached,
                                    warning = result.warning,
                                )
                            else if (before.mode == LyricsAIMode.TRANSCRIBE)
                                before.copy(
                                    candidate = transcriptionMarker + "\n" + transcript.syncedText,
                                    preview = true,
                                    cached = result.cached,
                                    warning = result.warning,
                                )
                            else {
                                state.update {
                                    it?.copy(phase = "Comparando palabras y fragmentos…")
                                }
                                val review =
                                    withContext(Dispatchers.Default) {
                                        LyricsRepair(before.draft, transcript)
                                    }
                                before.copy(
                                    review = review,
                                    cached = result.cached,
                                    warning = result.warning,
                                )
                            }
                        }
                    }
                if (generation == ticket)
                    state.value =
                        after.copy(
                            phase = if (after.cached) "Análisis guardado" else "Revisión preparada",
                        )
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (generation == ticket)
                    state.update {
                        it?.copy(
                            loading = false,
                            issue = error.userMessage(),
                            phase = "No se pudo preparar la revisión",
                        )
                    }
            } finally {
                if (generation == ticket) {
                    state.update { it?.copy(loading = false) }
                    operation = null
                }
            }
        }
    }

    fun select(id: Int, selected: Boolean) {
        state.update { old ->
            val proposal = old?.review?.proposals?.getOrNull(id) ?: return@update old
            old.copy(
                edits =
                    if (selected)
                        old.edits +
                            (id to
                                RepairEditDraft(
                                    proposal.suggested,
                                    proposal.start
                                        ?.let { "%.2f".format(Locale.ROOT, it) }
                                        .orEmpty(),
                                ))
                    else old.edits - id,
                candidate = null,
                preview = false,
                issue = null,
                problemIds = emptyList(),
            )
        }
    }

    fun edit(id: Int, text: String, time: String) {
        if (text.toByteArray().size > 65536 || time.length > 32) return
        state.update { old ->
            if (old == null || id !in old.edits) old
            else {
                val edits = old.edits + (id to RepairEditDraft(text, time))
                if (edits.values.sumOf { it.text.toByteArray().size } > 131072)
                    old.copy(issue = "La selección supera el tamaño de una letra.")
                else
                    old.copy(
                        edits = edits,
                        candidate = null,
                        preview = false,
                        issue = null,
                        problemIds = emptyList(),
                    )
            }
        }
    }

    fun selectAll() {
        val value = state.value ?: return
        value.review
            ?.proposals
            ?.filter {
                it.kind != LyricsRepair.Kind.UNRECOGNIZED &&
                    (!value.onlyCompletions || it.kind == LyricsRepair.Kind.COMPLETION)
            }
            ?.forEach { select(it.id, true) }
    }

    fun completionsOnly(value: Boolean) {
        state.update {
            it?.copy(onlyCompletions = value, candidate = null, preview = false, issue = null)
        }
    }

    fun reviewPreview() {
        val value = state.value ?: return
        try {
            val review = value.review ?: return
            val edits =
                value.edits.mapValues { (id, edit) ->
                    val proposal = review.proposals[id]
                    val time =
                        if (proposal.kind == LyricsRepair.Kind.TIMING || proposal.insertsLines) {
                            edit.time.replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() }
                                ?: throw IllegalArgumentException(
                                    "Revisa el tiempo del fragmento seleccionado.",
                                )
                        } else null
                    LyricsRepair.Edit(edit.text, time)
                }
            val text = review.applying(edits, value.onlyCompletions)
            require(text != value.draft) { "Selecciona los cambios que quieres aplicar." }
            state.value =
                value.copy(candidate = text, preview = true, issue = null, problemIds = emptyList())
        } catch (error: Exception) {
            state.value =
                value.copy(
                    issue = error.userMessage(),
                    problemIds = (error as? LyricsRepair.TimingIssue)?.proposalIds.orEmpty(),
                )
        }
    }

    fun showReview() {
        state.update { it?.copy(preview = false) }
        stopPreview()
    }

    fun useInEditor() {
        val value = state.value ?: return
        val text = value.candidate ?: return
        if (apply(value.source, value.draft, text)) close()
        else
            state.value =
                value.copy(
                    issue =
                        "La letra del editor ha cambiado. Cierra esta revisión y vuelve a analizar el borrador actual.",
                )
    }
}
