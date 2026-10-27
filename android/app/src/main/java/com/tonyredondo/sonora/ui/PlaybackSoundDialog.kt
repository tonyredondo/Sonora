package com.tonyredondo.sonora

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.*
import kotlinx.coroutines.delay

private enum class SoundPage(val label: String) {
    SPEED("Velocidad"),
    EQUALIZER("Ecualizador"),
    LISTENING("Escucha"),
    TRANSITIONS("Mezcla"),
    TIMER("Temporizador"),
}

@Composable
fun PlaybackSoundDialog(model: PlayerModel, onTools: () -> Unit, dismiss: () -> Unit) {
    val sound by model.graph.sound.collectAsStateWithLifecycle()
    val listening by model.graph.listening.collectAsStateWithLifecycle()
    val timer by model.graph.sleepTimer.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val normalization by model.graph.normalizationInfo.collectAsStateWithLifecycle()
    val transitions by model.graph.transitions.collectAsStateWithLifecycle()
    val transitionInfo by model.graph.transitionInfo.collectAsStateWithLifecycle()
    var selected by rememberSaveable { mutableStateOf(SoundPage.SPEED) }
    val list = remember(selected) { LazyListState() }
    Dialog(
        dismiss,
        properties =
            DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.systemBarsPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = dismiss) { Text("Listo") }
                    Text("Sonido", style = MaterialTheme.typography.titleMedium)
                }
                LazyRow(
                    Modifier.fillMaxWidth().testTag("soundTabs"),
                    contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(SoundPage.entries) { page ->
                        FilterChip(
                            selected == page,
                            { selected = page },
                            label = { Text(page.label) },
                        )
                    }
                }
                LazyColumn(
                    Modifier.fillMaxWidth().weight(1f).testTag("soundBody"),
                    state = list,
                    contentPadding = PaddingValues(20.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    when (selected) {
                        SoundPage.TRANSITIONS -> {
                            item {
                                Text(
                                    "Entre canciones",
                                    style = MaterialTheme.typography.titleMedium,
                                )
                            }
                            item {
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    TransitionMode.entries.forEach { mode ->
                                        FilterChip(
                                            transitions.mode == mode,
                                            {
                                                model.graph.setTransitions(
                                                    transitions.copy(mode = mode),
                                                )
                                            },
                                            label = { Text(mode.label) },
                                            modifier = Modifier.heightIn(min = 48.dp),
                                            colors =
                                                FilterChipDefaults.filterChipColors(
                                                    selectedContainerColor =
                                                        MaterialTheme.colorScheme.primary,
                                                    selectedLabelColor =
                                                        MaterialTheme.colorScheme.onPrimary,
                                                ),
                                        )
                                    }
                                }
                            }
                            if (transitions.mode != TransitionMode.CONTINUOUS) {
                                item {
                                    Text("Fundido máximo · ${transitions.seconds} s")
                                    Slider(
                                        transitions.seconds.toFloat(),
                                        {
                                            model.graph.setTransitions(
                                                transitions.copy(seconds = it.roundToInt()),
                                            )
                                        },
                                        valueRange = 1f..12f,
                                        steps = 10,
                                        modifier =
                                            Modifier.semantics {
                                                contentDescription = "Duración del fundido"
                                            },
                                    )
                                }
                                item {
                                    Text(
                                        if (transitions.mode == TransitionMode.ADAPTIVE)
                                            "Alinea los golpes cuando hay un pulso disponible y ajusta el fundido al BPM estimado. Si la siguiente canción no está lista, continúa sin mezcla."
                                        else
                                            "La siguiente canción empieza durante el fundido. Pausar o reanudar conserva ambas posiciones.",
                                    )
                                }
                            }
                            if (transitionInfo.isNotBlank())
                                item {
                                    Text(
                                        transitionInfo,
                                        modifier = Modifier.testTag("transitionStatus"),
                                    )
                                }
                        }
                        SoundPage.SPEED -> {
                            item { TextButton(onClick = onTools) { Text("BPM y marcadores") } }
                            item {
                                Text("Velocidad · ${"%.2f".format(sound.speed)}×")
                                Slider(
                                    sound.speed,
                                    {
                                        model.graph.setSound(
                                            sound.copy(speed = (it * 20).roundToInt() / 20f),
                                        )
                                    },
                                    valueRange = .5f..2f,
                                    steps = 29,
                                    modifier =
                                        Modifier.semantics { contentDescription = "Velocidad" },
                                )
                            }
                            item {
                                val semitones =
                                    (12 * ln(sound.pitch.toDouble()) / ln(2.0))
                                        .roundToInt()
                                        .toFloat()
                                Text("Tonalidad · ${semitones.toInt()} semitonos")
                                Slider(
                                    semitones,
                                    {
                                        model.graph.setSound(
                                            sound.copy(
                                                pitch = 2.0.pow(it.roundToInt() / 12.0).toFloat(),
                                            ),
                                        )
                                    },
                                    valueRange = -12f..12f,
                                    steps = 23,
                                    modifier =
                                        Modifier.semantics { contentDescription = "Tonalidad" },
                                )
                            }
                            item {
                                TextButton(onClick = { model.graph.setSound(SoundSettings()) }) {
                                    Text("Restablecer velocidad y tono")
                                }
                            }
                        }
                        SoundPage.EQUALIZER -> {
                            item {
                                Row(
                                    Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        "Curva de diez bandas",
                                        Modifier.weight(1f),
                                        style = MaterialTheme.typography.titleMedium,
                                    )
                                    Switch(
                                        listening.equalizer.enabled,
                                        {
                                            model.graph.setListening(
                                                listening.copy(
                                                    equalizer =
                                                        listening.equalizer.copy(enabled = it),
                                                ),
                                            )
                                        },
                                        modifier =
                                            Modifier.semantics {
                                                contentDescription = "Activar ecualizador"
                                            },
                                    )
                                }
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    items(EqualizerPreset.entries) { preset ->
                                        val value = preset.settings()
                                        FilterChip(
                                            listening.equalizer.gains == value.gains &&
                                                listening.equalizer.preamp == value.preamp,
                                            {
                                                model.graph.setListening(
                                                    listening.copy(equalizer = value),
                                                )
                                            },
                                            label = { Text(preset.label) },
                                        )
                                    }
                                }
                            }
                            item {
                                Text(
                                    "Preamplificación · ${"%+.1f".format(listening.equalizer.preamp)} dB",
                                )
                                Slider(
                                    listening.equalizer.preamp,
                                    {
                                        model.graph.setListening(
                                            listening.copy(
                                                equalizer =
                                                    listening.equalizer.copy(
                                                        preamp = (it * 2).roundToInt() / 2f,
                                                    ),
                                            ),
                                        )
                                    },
                                    enabled = listening.equalizer.enabled,
                                    valueRange = -24f..12f,
                                    steps = 71,
                                    modifier =
                                        Modifier.semantics {
                                            contentDescription = "Preamplificación"
                                        },
                                )
                            }
                            items(
                                EqualizerSettings.frequencies.indices.toList(),
                                key = { "band-$it" },
                            ) { i ->
                                val frequency = EqualizerSettings.frequencies[i].toInt()
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        if (frequency >= 1000) "${frequency/1000} kHz"
                                        else "$frequency Hz",
                                        Modifier.width(60.dp),
                                    )
                                    Slider(
                                        listening.equalizer.gains[i],
                                        { gain ->
                                            model.graph.setListening(
                                                listening.copy(
                                                    equalizer =
                                                        listening.equalizer.copy(
                                                            gains =
                                                                listening.equalizer.gains
                                                                    .mapIndexed { index, old ->
                                                                        if (index == i)
                                                                            (gain * 2)
                                                                                .roundToInt() / 2f
                                                                        else old
                                                                    },
                                                        ),
                                                ),
                                            )
                                        },
                                        enabled = listening.equalizer.enabled,
                                        valueRange = -12f..12f,
                                        steps = 47,
                                        modifier =
                                            Modifier.weight(1f).semantics {
                                                contentDescription = "Ganancia $frequency Hz"
                                            },
                                    )
                                    Text(
                                        "%+.1f".format(listening.equalizer.gains[i]),
                                        Modifier.width(46.dp),
                                    )
                                }
                            }
                        }
                        SoundPage.LISTENING -> {
                            item {
                                Text(
                                    "Balance estéreo",
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                Slider(
                                    listening.balance,
                                    {
                                        model.graph.setListening(
                                            listening.copy(balance = (it * 20).roundToInt() / 20f),
                                        )
                                    },
                                    valueRange = -1f..1f,
                                    steps = 39,
                                    modifier =
                                        Modifier.semantics {
                                            contentDescription = "Balance estéreo"
                                        },
                                )
                                Row(
                                    Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text("Izquierda")
                                    TextButton(
                                        onClick = {
                                            model.graph.setListening(listening.copy(balance = 0f))
                                        },
                                    ) {
                                        Text("Centrar")
                                    }
                                    Text("Derecha")
                                }
                            }
                            item {
                                Text(
                                    "Normalización de volumen",
                                    style = MaterialTheme.typography.titleMedium,
                                )
                                Column {
                                    listOf(
                                            NormalizationMode.OFF to "Desactivada",
                                            NormalizationMode.TRACK to "Por canción",
                                            NormalizationMode.ALBUM to "Por álbum",
                                        )
                                        .forEach { (mode, label) ->
                                            FilterChip(
                                                listening.normalization == mode,
                                                {
                                                    model.graph.setListening(
                                                        listening.copy(normalization = mode),
                                                    )
                                                },
                                                label = { Text(label) },
                                            )
                                        }
                                }
                                Text(
                                    normalization,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        SoundPage.TIMER -> {
                            item {
                                val remaining by
                                    produceState(0L, timer) {
                                        do {
                                            value =
                                                ((timer?.deadlineMs ?: 0) -
                                                        System.currentTimeMillis())
                                                    .coerceAtLeast(0)
                                            delay(1000)
                                        } while (timer?.deadlineMs != null)
                                    }
                                Text(
                                    when {
                                        timer?.deadlineMs != null ->
                                            "Se pausará en ${playbackTime(remaining)}"
                                        timer?.songId != null -> "Al terminar esta canción"
                                        else -> "Sin temporizador"
                                    },
                                    style = MaterialTheme.typography.titleMedium,
                                )
                            }
                            items(listOf(15, 30, 60, 90)) { minutes ->
                                OutlinedButton(
                                    onClick = {
                                        model.graph.setSleepTimer(
                                            SleepTimer.deadline(
                                                System.currentTimeMillis() + minutes * 60_000L,
                                            ),
                                        )
                                    },
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text("$minutes min")
                                }
                            }
                            item {
                                OutlinedButton(
                                    onClick = {
                                        playback.currentId?.let {
                                            model.graph.setSleepTimer(
                                                SleepTimer.endOfTrack(it, playback.currentIndex),
                                            )
                                        }
                                    },
                                    enabled =
                                        playback.currentId != null && playback.currentIndex >= 0,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text("Al terminar la canción")
                                }
                            }
                            if (timer != null)
                                item {
                                    TextButton(onClick = { model.graph.setSleepTimer(null) }) {
                                        Text("Cancelar temporizador")
                                    }
                                }
                        }
                    }
                }
            }
        }
    }
}
