package com.tonyredondo.sonora

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.Player
import java.util.Locale

@Composable
fun GlassAction(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    primary: Boolean = false,
    enabled: Boolean = true,
    active: Boolean = false,
) {
    val tint = MaterialTheme.colorScheme.primary
    IconButton(
        onClick,
        modifier
            .size(if (primary) 80.dp else 56.dp)
            .background(if (primary) tint else Color.White.copy(alpha = .12f), CircleShape)
            .border(.7.dp, Color.White.copy(alpha = .16f), CircleShape),
        enabled = enabled,
    ) {
        Icon(
            icon,
            label,
            modifier = Modifier.size(if (primary) 40.dp else 26.dp),
            tint =
                if (!enabled) Color.Gray
                else if (primary) Color.Black else if (active) tint else Color.White,
        )
    }
}

fun playbackTime(ms: Long): String {
    val seconds = ms.coerceAtLeast(0) / 1000
    return String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)
}

@Composable
fun WaveformTimeline(
    model: PlayerModel,
    playback: PlaybackViewState,
    values: List<Float>,
    modifier: Modifier = Modifier,
) {
    var scrub by remember { mutableStateOf<Float?>(null) }
    val duration = playback.durationMs.coerceAtLeast(1)
    val fraction = scrub ?: (playback.positionMs.toFloat() / duration).coerceIn(0f, 1f)
    val accent = MaterialTheme.colorScheme.primary
    val position = if (scrub != null) (fraction * duration).toLong() else playback.positionMs
    Column(modifier) {
        Canvas(
            Modifier.fillMaxWidth()
                .height(44.dp)
                .testTag("waveformTimeline")
                .semantics {
                    contentDescription = "Posición de reproducción"
                    stateDescription = playbackTime(position)
                    progressBarRangeInfo = ProgressBarRangeInfo(fraction, 0f..1f)
                    setProgress { value ->
                        model.seek((value.coerceIn(0f, 1f) * duration).toLong())
                        true
                    }
                }
                .pointerInput(duration) {
                    detectTapGestures { point ->
                        model.seek((point.x / size.width * duration).toLong())
                    }
                }
                .pointerInput(duration) {
                    detectHorizontalDragGestures(
                        onDragEnd = {
                            scrub?.let { model.seek((it * duration).toLong()) }
                            scrub = null
                        },
                        onDragCancel = { scrub = null },
                    ) { change, _ ->
                        change.consume()
                        scrub = (change.position.x / size.width).coerceIn(0f, 1f)
                    }
                },
        ) {
            val count = minOf(180, values.size)
            if (count == 0) {
                drawLine(
                    Color.White.copy(alpha = .22f),
                    Offset(0f, size.height / 2),
                    Offset(size.width, size.height / 2),
                    strokeWidth = 3.dp.toPx(),
                    cap = StrokeCap.Round,
                )
                drawLine(
                    accent,
                    Offset(0f, size.height / 2),
                    Offset(size.width * fraction, size.height / 2),
                    strokeWidth = 3.dp.toPx(),
                    cap = StrokeCap.Round,
                )
            } else
                repeat(count) { index ->
                    val x = (index + .5f) * size.width / count
                    val value =
                        values[(index * values.size / count).coerceAtMost(values.lastIndex)]
                            .coerceIn(0f, 1f)
                    val height = (size.height * value).coerceAtLeast(2.dp.toPx())
                    drawLine(
                        if (index.toFloat() / count <= fraction) accent
                        else Color.White.copy(alpha = .24f),
                        Offset(x, (size.height - height) / 2),
                        Offset(x, (size.height + height) / 2),
                        strokeWidth = (size.width / count * .55f).coerceAtLeast(1f),
                        cap = StrokeCap.Round,
                    )
                }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(playbackTime(position), color = Color.Gray, fontSize = 13.sp)
            Text(playbackTime(playback.durationMs), color = Color.Gray, fontSize = 13.sp)
        }
    }
}

@Composable
private fun Transport(model: PlayerModel, state: PlaybackViewState) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GlassAction(Icons.Rounded.Shuffle, "Aleatorio", model::shuffle, active = state.shuffle)
        GlassAction(Icons.Rounded.SkipPrevious, "Anterior", model::previous)
        GlassAction(
            if (state.showsPause) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
            if (state.showsPause) "Pausa" else "Reproducir",
            model::togglePlayback,
            primary = true,
            enabled = state.currentId != null,
        )
        GlassAction(Icons.Rounded.SkipNext, "Siguiente", model::next)
        GlassAction(
            if (state.repeat == Player.REPEAT_MODE_ONE) Icons.Rounded.RepeatOne
            else Icons.Rounded.Repeat,
            "Repetición",
            model::repeat,
            active = state.repeat != Player.REPEAT_MODE_OFF,
        )
    }
}

@Composable
private fun OutputControls(model: PlayerModel, sound: () -> Unit, modifier: Modifier = Modifier) {
    val volume by model.volume.collectAsStateWithLifecycle()
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = sound) {
            Icon(Icons.Rounded.VolumeUp, "Sonido", tint = MaterialTheme.colorScheme.primary)
        }
        Slider(
            volume.toFloat(),
            { model.setVolume(it.toInt()) },
            valueRange = 0f..model.maximumVolume.coerceAtLeast(1).toFloat(),
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
        )
    }
}

@Composable
fun PlayerControls(
    model: PlayerModel,
    state: PlaybackViewState,
    extras: SongExtras,
    wide: Boolean,
    sound: () -> Unit,
) {
    if (
        wide &&
            with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() } >=
                1100.dp
    )
        Row(
            Modifier.fillMaxWidth()
                .background(MaterialTheme.colorScheme.background)
                .padding(horizontal = 24.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            WaveformTimeline(model, state, extras.waveform, Modifier.weight(1.3f))
            Transport(model, state)
            OutputControls(model, sound, Modifier.weight(.7f))
        }
    else if (wide)
        Column(
            Modifier.fillMaxWidth()
                .background(MaterialTheme.colorScheme.background)
                .padding(horizontal = 24.dp, vertical = 8.dp),
        ) {
            WaveformTimeline(model, state, extras.waveform)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Transport(model, state)
                OutputControls(model, sound, Modifier.weight(1f))
            }
        }
    else
        Column(
            Modifier.fillMaxWidth()
                .background(MaterialTheme.colorScheme.background)
                .navigationBarsPadding()
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            WaveformTimeline(model, state, extras.waveform)
            Spacer(Modifier.height(8.dp))
            Transport(model, state)
            OutputControls(model, sound, Modifier.fillMaxWidth().padding(vertical = 8.dp))
        }
}
