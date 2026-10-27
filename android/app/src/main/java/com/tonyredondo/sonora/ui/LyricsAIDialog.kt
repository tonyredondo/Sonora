package com.tonyredondo.sonora

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
internal fun LyricsAIDialog(model: PlayerModel, state: LyricsAIState) {
    val editor = model.lyricsAI
    Dialog(
        editor::close,
        properties =
            DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val bounds = remember { mutableStateMapOf<String, Rect>() }
        var origin by remember { mutableStateOf(Offset.Zero) }
        fun dismissKeyboard() {
            focus.clearFocus(force = true)
            keyboard?.hide()
        }
        val list = rememberLazyListState()
        val visible =
            state.review
                ?.proposals
                ?.filter { !state.onlyCompletions || it.kind == LyricsRepair.Kind.COMPLETION }
                .orEmpty()
        LaunchedEffect(state.problemIds, state.preview) {
            if (!state.preview && state.problemIds.isNotEmpty()) {
                val index = visible.indexOfFirst { it.id in state.problemIds }
                if (index >= 0) list.animateScrollToItem(index + 1)
            }
        }
        Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier.systemBarsPadding()
                    .imePadding()
                    .onGloballyPositioned { origin = it.boundsInRoot().topLeft }
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val down =
                                awaitFirstDown(
                                    requireUnconsumed = false,
                                    pass = PointerEventPass.Initial,
                                )
                            if (bounds.values.none { it.contains(down.position + origin) })
                                dismissKeyboard()
                        }
                    },
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = editor::close) { Text("Cancelar") }
                    Text(
                        state.mode.label + " letra",
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    TextButton(
                        onClick = {
                            dismissKeyboard()
                            editor.useInEditor()
                        },
                        enabled = state.preview && state.candidate != null && !state.loading,
                    ) {
                        Text("Usar en el editor")
                    }
                }
                Text(
                    state.source.title,
                    Modifier.padding(horizontal = 20.dp),
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 2,
                )
                if (state.loading) {
                    LinearProgressIndicator(Modifier.fillMaxWidth().padding(20.dp))
                    Text(state.phase, Modifier.padding(horizontal = 20.dp).testTag("lyricsAIPhase"))
                    TextButton(onClick = editor::cancelAnalysis) { Text("Cancelar análisis") }
                }
                state.issue?.let {
                    Text(
                        it,
                        Modifier.padding(horizontal = 20.dp).testTag("lyricsAIIssue"),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                state.warning?.let {
                    Text(
                        it,
                        Modifier.padding(horizontal = 20.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f).testTag("lyricsAIContent"),
                    state = list,
                    contentPadding = PaddingValues(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    item {
                        if (state.preview)
                            TextButton(onClick = editor::showReview) {
                                Text(
                                    if (state.review != null) "Volver a los cambios"
                                    else "Volver al análisis",
                                )
                            }
                        else if (state.review == null && !state.loading) {
                            Text(
                                when (state.mode) {
                                    LyricsAIMode.ALIGN ->
                                        "Coloca las palabras de tu letra en los tiempos del audio."
                                    LyricsAIMode.TRANSCRIBE ->
                                        "Obtiene la letra y sus tiempos a partir del audio."
                                    LyricsAIMode.REPAIR ->
                                        "Compara la letra con una transcripción del audio. Los fragmentos que no se reconozcan se conservarán."
                                },
                            )
                            Spacer(Modifier.height(12.dp))
                            Text(
                                "Utiliza el servicio de análisis de tu servidor. El resultado se guarda para reutilizarlo sin conexión.",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Button(
                                onClick = editor::analyze,
                                modifier = Modifier.padding(top = 16.dp),
                            ) {
                                Text("Analizar")
                            }
                        } else if (state.review != null && !state.preview) {
                            if (state.cached)
                                Text(
                                    "Análisis guardado",
                                    style = MaterialTheme.typography.labelMedium,
                                )
                            if (state.review.usesPhraseTiming)
                                Text(
                                    "La revisión usa tiempos por frase.",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            if (state.review.proposals.isEmpty())
                                Text(
                                    "No se han encontrado cambios. Puedes conservar la letra actual.",
                                )
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Switch(state.onlyCompletions, editor::completionsOnly)
                                Text("Solo completar", Modifier.padding(start = 12.dp))
                            }
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                TextButton(onClick = editor::selectAll) {
                                    Text("Seleccionar sugerencias")
                                }
                                Button(
                                    onClick = {
                                        dismissKeyboard()
                                        editor.reviewPreview()
                                    },
                                    enabled = state.edits.isNotEmpty(),
                                ) {
                                    Text("Vista previa")
                                }
                            }
                        }
                    }
                    if (state.preview) {
                        val document = LyricsDocument.parse(state.candidate.orEmpty())
                        items(document.lines, key = { "preview-${it.id}" }) { line ->
                            Column(Modifier.fillMaxWidth().testTag("lyricsAIPreview-${line.id}")) {
                                line.timeMs?.let {
                                    Text(
                                        "%d:%02d".format(it / 60000, it / 1000 % 60),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                Text(
                                    line.text.ifEmpty { "Pausa" },
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                            }
                        }
                    } else
                        items(visible, key = { it.id }) { proposal ->
                            val edit = state.edits[proposal.id]
                            val problem = proposal.id in state.problemIds
                            OutlinedCard(
                                Modifier.fillMaxWidth().testTag("repairProposal-${proposal.id}"),
                                border =
                                    BorderStroke(
                                        1.dp,
                                        if (problem) MaterialTheme.colorScheme.error
                                        else MaterialTheme.colorScheme.outlineVariant,
                                    ),
                            ) {
                                Column(
                                    Modifier.padding(16.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Checkbox(
                                            edit != null,
                                            { editor.select(proposal.id, it) },
                                            modifier =
                                                Modifier.testTag("repairSelect-${proposal.id}"),
                                        )
                                        Text(
                                            when (proposal.kind) {
                                                LyricsRepair.Kind.CORRECTION -> "Corrección"
                                                LyricsRepair.Kind.COMPLETION -> "Frase nueva"
                                                LyricsRepair.Kind.TIMING -> "Tiempo de la frase"
                                                LyricsRepair.Kind.UNRECOGNIZED ->
                                                    "Texto no reconocido"
                                            },
                                            style = MaterialTheme.typography.titleSmall,
                                        )
                                    }
                                    if (proposal.original.isNotEmpty())
                                        Text(
                                            proposal.original,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    if (
                                        proposal.kind == LyricsRepair.Kind.UNRECOGNIZED &&
                                            edit == null
                                    )
                                        Text(
                                            "Se conservará. Selecciona este fragmento si quieres editarlo manualmente.",
                                        )
                                    else {
                                        val field = "text-${proposal.id}"
                                        DisposableEffect(field) {
                                            onDispose { bounds.remove(field) }
                                        }
                                        OutlinedTextField(
                                            edit?.text ?: proposal.suggested,
                                            { editor.edit(proposal.id, it, edit?.time.orEmpty()) },
                                            enabled =
                                                edit != null &&
                                                    proposal.kind != LyricsRepair.Kind.TIMING,
                                            label = { Text("Propuesta") },
                                            modifier =
                                                Modifier.fillMaxWidth()
                                                    .onGloballyPositioned {
                                                        bounds[field] = it.boundsInRoot()
                                                    }
                                                    .testTag("repairText-${proposal.id}"),
                                        )
                                        if (
                                            edit != null &&
                                                (proposal.kind == LyricsRepair.Kind.TIMING ||
                                                    proposal.insertsLines)
                                        ) {
                                            val timeField = "time-${proposal.id}"
                                            DisposableEffect(timeField) {
                                                onDispose { bounds.remove(timeField) }
                                            }
                                            OutlinedTextField(
                                                edit.time,
                                                { editor.edit(proposal.id, edit.text, it) },
                                                label = { Text("Inicio en segundos") },
                                                keyboardOptions =
                                                    KeyboardOptions(
                                                        keyboardType = KeyboardType.Decimal,
                                                    ),
                                                modifier =
                                                    Modifier.widthIn(max = 260.dp)
                                                        .onGloballyPositioned {
                                                            bounds[timeField] = it.boundsInRoot()
                                                        }
                                                        .testTag("repairTime-${proposal.id}"),
                                            )
                                        }
                                    }
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                        if (proposal.start != null)
                                            TextButton(
                                                onClick = {
                                                    dismissKeyboard()
                                                    model.listenToAIFragment(
                                                        state.source,
                                                        proposal.start,
                                                        proposal.end,
                                                    )
                                                },
                                            ) {
                                                Text("Escuchar fragmento")
                                            }
                                        if (
                                            proposal.kind == LyricsRepair.Kind.TIMING &&
                                                proposal.originalStart != null
                                        )
                                            TextButton(
                                                onClick = {
                                                    dismissKeyboard()
                                                    model.listenToAIFragment(
                                                        state.source,
                                                        proposal.originalStart,
                                                        proposal.originalStart + 4,
                                                    )
                                                },
                                            ) {
                                                Text("Escuchar tiempo actual")
                                            }
                                    }
                                }
                            }
                        }
                    item { Spacer(Modifier.height(32.dp)) }
                }
            }
        }
    }
}
