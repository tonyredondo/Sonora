package com.tonyredondo.sonora

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
fun SonoraRoot(model: PlayerModel) {
    val issue by model.graph.issue.collectAsStateWithLifecycle()
    val settings by model.showSettings.collectAsStateWithLifecycle()
    val ready by model.graph.ready.collectAsStateWithLifecycle()
    val show by model.showPlayer.collectAsStateWithLifecycle()
    Surface(Modifier.fillMaxSize()) {
        if (!ready)
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        else if (show) NowPlayingScreen(model) else LibraryScreen(model)
    }
    if (settings) OnlineSettingsDialog(model) { model.showSettings.value = false }
    val editor by model.lyricsEditorSource.collectAsStateWithLifecycle()
    editor?.let { LyricsEditorDialog(model, it) }
    val timing by model.timingSource.collectAsStateWithLifecycle()
    timing?.let { ManualTimingDialog(model, it) }
    val lyricAnalysis by model.lyricsAI.state.collectAsStateWithLifecycle()
    lyricAnalysis?.let { LyricsAIDialog(model, it) }

    issue?.let { message ->
        AlertDialog(
            onDismissRequest = { model.graph.issue.value = null },
            title = { Text("Sonora") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { model.graph.issue.value = null }) { Text("Listo") }
            },
        )
    }
}

@Composable
fun NowPlayingScreen(model: PlayerModel) {
    val state by model.playback.collectAsStateWithLifecycle()
    val song by model.currentSong.collectAsStateWithLifecycle()
    val allExtras by model.graph.extras.collectAsStateWithLifecycle()
    val extras = allExtras[state.currentId] ?: SongExtras()
    val selected by model.graph.page.collectAsStateWithLifecycle()
    val windowSize = LocalWindowInfo.current.containerSize
    val windowWidth = with(LocalDensity.current) { windowSize.width.toDp() }
    val wide = windowSize.width > windowSize.height && windowWidth >= 600.dp
    val view = LocalView.current
    DisposableEffect(wide, view) {
        val activity = view.context as? android.app.Activity
        val controller = activity?.let { WindowCompat.getInsetsController(it.window, view) }
        if (wide) {
            controller?.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller?.hide(WindowInsetsCompat.Type.systemBars())
        }
        onDispose { controller?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    var showQueue by remember { mutableStateOf(false) }
    var showSound by remember { mutableStateOf(false) }
    var showTools by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    BackHandler { if (expanded) expanded = false else model.showPlayer.value = false }
    Column(
        Modifier.fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .testTag(if (wide) "playerLandscape" else "playerPortrait"),
    ) {
        Box(
            Modifier.fillMaxWidth().weight(1f).onSizeChanged {
                if (wide) model.graph.panorama.setViewport(it.width, it.height)
            },
        ) {
            val pager =
                rememberPagerState(
                    initialPage = selected.ordinal,
                    pageCount = { PlayerPage.entries.size },
                )
            val coroutine = rememberCoroutineScope()
            LaunchedEffect(pager.settledPage) {
                model.graph.selectPage(PlayerPage.entries[pager.settledPage])
            }
            CoverBackdrop(
                song?.displayArtworkPath() ?: extras.generatedArtwork ?: state.artworkPath,
                extras.panorama,
                wide,
                selected != PlayerPage.ARTWORK,
                Modifier.fillMaxSize(),
            )
            HorizontalPager(
                pager,
                Modifier.fillMaxSize()
                    .testTag("playerCarousel")
                    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                    .drawWithContent {
                        drawContent()
                        drawRect(
                            Brush.verticalGradient(
                                0f to Color.White,
                                .78f to Color.White,
                                1f to Color.Transparent,
                            ),
                            blendMode = BlendMode.DstIn,
                        )
                    },
                beyondViewportPageCount = 1,
            ) { index ->
                val page = PlayerPage.entries[index]
                Box(
                    Modifier.fillMaxSize()
                        .then(if (wide) Modifier.padding(start = windowWidth * .50f) else Modifier)
                        .then(
                            if (index != pager.currentPage) Modifier.clearAndSetSemantics {}
                            else Modifier,
                        ),
                ) {
                    PlayerPageContent(
                        model,
                        song,
                        extras,
                        page,
                        page == selected,
                        Modifier.fillMaxSize(),
                    )
                }
            }
            if (wide)
                SongSummary(
                    state,
                    song,
                    extras,
                    Modifier.align(Alignment.BottomStart)
                        .fillMaxWidth(.47f)
                        .padding(start = 28.dp, end = 12.dp, bottom = 36.dp),
                )
            Row(
                Modifier.align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .then(if (wide) Modifier else Modifier.statusBarsPadding())
                    .padding(20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                GlassAction(
                    Icons.Rounded.KeyboardArrowDown,
                    "Biblioteca",
                    { model.showPlayer.value = false },
                )
                Spacer(Modifier.weight(1f))
                GlassAction(Icons.Rounded.OpenInFull, "Ampliar vista", { expanded = true })
                Box {
                    GlassAction(Icons.Rounded.MoreHoriz, "Opciones", { menu = true })
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(
                            text = { Text("Sonido") },
                            leadingIcon = { Icon(Icons.Rounded.Tune, null) },
                            onClick = {
                                menu = false
                                showSound = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Seguir letra") },
                            leadingIcon = { Icon(Icons.Rounded.VerticalAlignCenter, null) },
                            onClick = {
                                menu = false
                                model.resumeLyrics()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Servicios online") },
                            leadingIcon = { Icon(Icons.Rounded.Settings, null) },
                            onClick = {
                                menu = false
                                model.showSettings.value = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Actualizar análisis") },
                            leadingIcon = { Icon(Icons.Rounded.Refresh, null) },
                            onClick = {
                                menu = false
                                model.graph.prepareAgain()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Biblioteca") },
                            leadingIcon = { Icon(Icons.Rounded.LibraryMusic, null) },
                            onClick = {
                                menu = false
                                model.showPlayer.value = false
                            },
                        )
                    }
                }
                GlassAction(Icons.Rounded.QueueMusic, "Cola", { showQueue = true })
            }
            Row(
                Modifier.align(Alignment.BottomCenter)
                    .padding(bottom = 14.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF303033).copy(alpha = .85f))
                    .padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PlayerPage.entries.forEach { page ->
                    Box(
                        Modifier.size(width = 32.dp, height = 44.dp)
                            .testTag("page:${page.name}")
                            .semantics {
                                contentDescription = "${page.label()}, ${page.ordinal + 1} de 5"
                                this.selected = selected == page
                                role = Role.Tab
                            }
                            .clickable {
                                model.resumeLyrics()
                                model.graph.selectPage(page)
                                coroutine.launch { pager.animateScrollToPage(page.ordinal) }
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            Modifier.size(8.dp)
                                .background(
                                    if (selected == page) Color.White else Color.Gray,
                                    CircleShape,
                                ),
                        )
                    }
                }
            }
        }
        if (!wide)
            SongSummary(
                state,
                song,
                extras,
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
            )
        state.error?.let { message ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    message,
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
                TextButton(onClick = model::togglePlayback) { Text("Reintentar") }
            }
        }
        PlayerControls(model, state, extras, wide) { showSound = true }
    }
    if (showQueue) QueueDialog(model) { showQueue = false }
    if (showSound)
        PlaybackSoundDialog(
            model,
            {
                showSound = false
                showTools = true
            },
        ) {
            showSound = false
        }
    if (showTools && song != null) SongToolsDialog(model, song!!) { showTools = false }
    if (expanded) ExpandedPageDialog(model, song, extras, selected) { expanded = false }
}

fun PlayerPage.label(): String =
    when (this) {
        PlayerPage.ARTWORK -> "Portada"
        PlayerPage.LYRICS -> "Letra"
        PlayerPage.TRANSLATION -> "Traducción"
        PlayerPage.MEANING -> "Significado"
        PlayerPage.ALBUM -> "Álbum"
    }

@Composable
private fun SongSummary(
    state: PlaybackViewState,
    song: Song?,
    extras: SongExtras,
    modifier: Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            song?.title ?: state.title.ifEmpty { "Sonora" },
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
        )
        Text(
            song?.artist ?: state.artist,
            fontSize = 20.sp,
            color = Color(0xFFA7A7AA),
            maxLines = 1,
        )
        Text(song?.album ?: state.album, fontSize = 20.sp, color = Color(0xFFA7A7AA), maxLines = 1)
        if (extras.styles.isNotEmpty() || extras.moods.isNotEmpty())
            Text(
                (extras.styles.map(::styleLabel) + extras.moods.map(::moodLabel)).joinToString(
                    " · ",
                ),
                fontSize = 13.sp,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 2,
            )
        extras.progress[PreparationStage.AUDIO]
            ?.takeIf { it.state != PreparationState.READY }
            ?.let {
                Text(it.message, fontSize = 12.sp, color = Color.LightGray, maxLines = 2)
            }
        (extras.progress[PreparationStage.ARTWORK]?.takeIf { it.state != PreparationState.READY }
                ?: extras.progress[PreparationStage.PANORAMA])
            ?.takeIf { it.state != PreparationState.READY }
            ?.let { Text(it.message, fontSize = 12.sp, color = Color.LightGray, maxLines = 2) }
        val bpm =
            extras.bpm
                ?.takeIf { it.isFinite() && it > 0 }
                ?.let { if (it > 170) it / 2 else it }
                ?.roundToInt()
        Text(
            listOfNotNull(song?.format?.takeIf(String::isNotBlank), bpm?.let { "$it BPM" })
                .joinToString(" · "),
            fontSize = 13.sp,
            color = Color(0xFFA0A0A6),
        )
    }
}

@Composable
fun PlayerPageContent(
    model: PlayerModel,
    song: Song?,
    extras: SongExtras,
    page: PlayerPage,
    visible: Boolean,
    modifier: Modifier = Modifier,
    expanded: Boolean = false,
) {
    when (page) {
        PlayerPage.ARTWORK -> Box(modifier)
        PlayerPage.LYRICS,
        PlayerPage.TRANSLATION ->
            LyricsPane(
                model,
                song,
                extras,
                page == PlayerPage.TRANSLATION,
                visible,
                modifier,
                expanded,
            )
        PlayerPage.MEANING,
        PlayerPage.ALBUM -> {
            val text = if (page == PlayerPage.MEANING) extras.meaning else extras.albumMeaning
            val stage =
                if (page == PlayerPage.MEANING) PreparationStage.MEANING else PreparationStage.ALBUM
            val status = extras.progress[stage]
            LazyColumn(
                modifier,
                contentPadding =
                    PaddingValues(
                        start = 28.dp,
                        end = 28.dp,
                        top = if (expanded) 16.dp else 116.dp,
                        bottom = 120.dp,
                    ),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                item {
                    Text(
                        if (page == PlayerPage.MEANING) "Sobre la canción" else "Sobre el álbum",
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
                if (text != null) {
                    item { Text(text, fontSize = 21.sp, lineHeight = 31.sp) }
                    item {
                        Text("Interpretación generada por IA", fontSize = 13.sp, color = Color.Gray)
                    }
                } else
                    item {
                        if (status?.state == PreparationState.RUNNING) {
                            CircularProgressIndicator()
                            Spacer(Modifier.height(16.dp))
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Text(
                                status?.message?.takeIf(String::isNotBlank)
                                    ?: if (page == PlayerPage.MEANING)
                                        "El significado todavía no está preparado."
                                    else "La información del álbum todavía no está preparada.",
                                color = Color.LightGray,
                                fontSize = 20.sp,
                            )
                            if (status?.state == PreparationState.NEEDS_CONNECTION)
                                TextButton(onClick = { model.showSettings.value = true }) {
                                    Text("Servicios online")
                                }
                        }
                    }
            }
        }
    }
}

@Composable
private fun LyricsPane(
    model: PlayerModel,
    song: Song?,
    extras: SongExtras,
    translated: Boolean,
    visible: Boolean,
    modifier: Modifier,
    expanded: Boolean,
) {
    val state by model.playback.collectAsStateWithLifecycle()
    val follow by model.followLyrics.collectAsStateWithLifecycle()
    val request by model.lyricScrollRequest.collectAsStateWithLifecycle()
    val document = remember(song?.lyricsText) { LyricsDocument.parse(song?.lyricsText.orEmpty()) }
    if (document.lines.none { it.text.isNotBlank() }) {
        val status = extras.progress[PreparationStage.LYRICS]
        Box(modifier.padding(32.dp), contentAlignment = Alignment.Center) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (status?.state == PreparationState.RUNNING) CircularProgressIndicator()
                Text(
                    status?.message?.takeIf(String::isNotBlank)
                        ?: if (song == null) "Cargando letra…"
                        else "Esta canción todavía no tiene letra.",
                    color = Color.LightGray,
                    fontSize = 22.sp,
                )
                if (status?.state == PreparationState.NEEDS_CONNECTION)
                    TextButton(onClick = { model.showSettings.value = true }) {
                        Text("Servicios online")
                    }
            }
        }
        return
    }
    val list = rememberLazyListState()
    val dragging by list.interactionSource.collectIsDraggedAsState()
    val allTools by model.graph.songTools.collectAsStateWithLifecycle()
    val offset = allTools[song?.id]?.offsetMs ?: 0
    val active = document.activeLine(state.positionMs, offset)
    LaunchedEffect(dragging, visible) { if (dragging && visible) model.followLyrics.value = false }
    LaunchedEffect(active, visible, follow, request) {
        if (visible && follow && active != null)
            list.animateScrollToItem(active, -(list.layoutInfo.viewportSize.height / 3))
    }
    BoxWithConstraints(modifier) {
        LazyColumn(
            Modifier.fillMaxSize().testTag(if (expanded) "expandedLyricsList" else "lyricsList"),
            state = list,
            contentPadding =
                PaddingValues(
                    start = 28.dp,
                    end = 28.dp,
                    top = if (expanded) 16.dp else 116.dp,
                    bottom = maxHeight / 2,
                ),
            verticalArrangement = Arrangement.spacedBy(36.dp),
        ) {
            items(document.lines, key = { it.id }) { line ->
                Column(
                    Modifier.fillMaxWidth()
                        .testTag("lyric:${line.id}")
                        .semantics { selected = active == line.id }
                        .then(
                            if (line.timeMs != null)
                                Modifier.clickable {
                                    model.seek((line.timeMs + offset).coerceAtLeast(0))
                                    model.resumeLyrics()
                                }
                            else Modifier,
                        ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        line.text,
                        fontSize = if (expanded) 34.sp else 30.sp,
                        lineHeight = if (expanded) 42.sp else 38.sp,
                        fontWeight = if (active == line.id) FontWeight.Bold else FontWeight.Medium,
                        color =
                            if (active == line.id) MaterialTheme.colorScheme.primary
                            else
                                Color.White.copy(
                                    alpha =
                                        if (document.isTimed && active != null && line.id < active)
                                            .65f
                                        else .95f,
                                ),
                    )
                    if (translated)
                        extras.translation[line.id]?.let {
                            Text(
                                it,
                                fontSize = 22.sp,
                                lineHeight = 30.sp,
                                color = Color(0xFFB0B0B5),
                            )
                        }
                }
            }
            if (translated && extras.translation.isEmpty())
                item {
                    Text(
                        extras.progress[PreparationStage.TRANSLATION]
                            ?.message
                            ?.takeIf(String::isNotBlank)
                            ?: "La traducción todavía no está preparada.",
                        color = Color.Gray,
                    )
                }
        }
    }
}
