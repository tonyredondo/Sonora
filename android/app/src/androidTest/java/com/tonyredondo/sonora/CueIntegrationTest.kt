package com.tonyredondo.sonora

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class CueIntegrationTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test
    fun flac24BitOriginalKeepsQuietLeastSignificantBits() = runBlocking {
        val root = File(context.cacheDir, "cue24-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = File(root, "source.flac")
            instrumentation.context.assets.open("cue-24bit.flac").use { input ->
                source.outputStream().use(input::copyTo)
            }
            val song =
                CueSegment("file:///qa24.cue", 1, 1, 76)
                    .applyTo(LocalAudio(context).read(Uri.fromFile(source)))
            val target = File(root, "track.wav")
            CueWavExporter(context).export(song, target)
            target.inputStream().use { input ->
                val wav = WavPcm.read(input)!!
                assertEquals(16000L, wav.frames)
                val pcm =
                    ByteBuffer.wrap(input.exact(wav.dataBytes.toInt()))
                        .order(ByteOrder.LITTLE_ENDIAN)
                // Independent source sequence was encoded as signed PCM24 by host FFmpeg.
                for (frame in 213 until 16213) {
                    val expected = ((frame.toLong() * 123457) % 16000001 - 8000000) / 8388608f
                    assertEquals(
                        "PCM24 frame $frame",
                        expected.toRawBits(),
                        wav.sample(pcm).toRawBits(),
                    )
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun compressedCueOriginalAndMp3ExportTheSelectedIntervalInsteadOfCopyingTheDisc() =
        runBlocking {
            val root =
                File(context.cacheDir, "compressed-cue-${UUID.randomUUID()}").apply { mkdirs() }
            val database = "compressed-cue-${UUID.randomUUID()}.sqlite"
            val store = LibraryStore(context, database)
            try {
                val wav = File(root, "source.wav")
                wave(wav)
                val mp3 = File(root, "disc.mp3")
                Mp3Converter(context).convert(LocalAudio(context).read(Uri.fromFile(wav)), mp3)
                val original = mp3.readBytes()
                val source = LocalAudio(context).read(Uri.fromFile(mp3))
                val track =
                    CueSegment("file:///compressed.cue", 1, 450, 600)
                        .applyTo(source)
                        .copy(title = "Selected two seconds")
                for (mode in PlaylistExportFormat.entries) {
                    val out = File(root, mode.name).apply { mkdirs() }
                    val result =
                        PlaylistExporter(context, store)
                            .export(listOf(track), "Compressed", Uri.fromFile(out), mode)
                    val name =
                        File(out, result.playlistName).readLines().single {
                            it.isNotBlank() && !it.startsWith('#')
                        }
                    val file = File(out, name)
                    val imported = LocalAudio(context).read(Uri.fromFile(file))
                    assertEquals("Selected two seconds", imported.title)
                    assertTrue(
                        "${mode}: ${imported.durationMs}",
                        abs(imported.durationMs - 2000) < 80,
                    )
                    var channels = 0
                    var rate = 0
                    var frames = 0
                    var crossings = 0
                    var last = 0f
                    PcmAudioReader(context)
                        .read(
                            imported,
                            10,
                            {
                                channels = it.channels
                                rate = it.rate
                            },
                            { pcm ->
                                for (index in pcm.indices step channels) {
                                    val value = pcm[index]
                                    if (last < 0 && value >= 0) crossings++
                                    last = value
                                    frames++
                                }
                            },
                        )
                    assertTrue(
                        "Selected audio must be the 660Hz second passage",
                        crossings.toDouble() * rate / frames in 655.0..665.0,
                    )
                    if (mode == PlaylistExportFormat.ORIGINAL)
                        file.inputStream().use { assertEquals(32, WavPcm.read(it)!!.bits) }
                }
                assertArrayEquals(original, mp3.readBytes())
            } finally {
                store.close()
                context.deleteDatabase(database)
                root.deleteRecursively()
            }
        }

    private fun wave(file: File, channels: Int = 2, rate: Int = 44100, bits: Int = 32) {
        val format =
            ByteBuffer.allocate(40)
                .order(ByteOrder.LITTLE_ENDIAN)
                .putShort((-2).toShort())
                .putShort(channels.toShort())
                .putInt(rate)
                .putInt(rate * channels * bits / 8)
                .putShort((channels * bits / 8).toShort())
                .putShort(bits.toShort())
                .putShort(22)
                .putShort(bits.toShort())
                .putInt(if (channels == 2) 3 else 0x3f)
                .putInt(1)
                .putShort(0)
                .putShort(16)
                .put(byteArrayOf(-128, 0, 0, -86, 0, 56, -101, 113))
                .array()
        val frames = rate * 12
        file.outputStream().buffered().use { out ->
            WavPcm(format, channels, rate, bits, false, frames.toLong() * channels * 4)
                .header(out, frames.toLong())
            val block = ByteBuffer.allocate(4096 * channels * 4).order(ByteOrder.LITTLE_ENDIAN)
            for (frame in 0 until frames) {
                val value =
                    ((if (frame < rate * 6) .08 else .65) *
                            sin(2 * PI * (if (frame < rate * 6) 220 else 660) * frame / rate) *
                            Int.MAX_VALUE)
                        .roundToInt()
                repeat(channels) { channel -> block.putInt(value xor (channel + 1)) }
                if (!block.hasRemaining()) {
                    out.write(block.array())
                    block.clear()
                }
            }
            if (block.position() > 0) out.write(block.array(), 0, block.position())
        }
    }

    @Test
    fun cueFolderImportsVirtualTracksAndExportsOnlyTheirExactSamplesAndLyrics() = runBlocking {
        val grant =
            context.contentResolver.persistedUriPermissions.first {
                it.isReadPermission &&
                    it.isWritePermission &&
                    runCatching {
                            DocumentsContract.getTreeDocumentId(it.uri) ==
                                "primary:Download/Sonora_QA_20261025"
                        }
                        .getOrDefault(false)
            }
        val root = DocumentFile.fromTreeUri(context, grant.uri)!!
        val id = UUID.randomUUID().toString()
        val folder = root.createDirectory("Cue-QA-$id")!!
        val work = File(context.cacheDir, "cue-$id").apply { mkdirs() }
        val database = "cue-$id.sqlite"
        val store = LibraryStore(context, database)
        try {
            val source = File(work, "disc.wav")
            wave(source)
            val original = source.readBytes()
            fun put(name: String, mime: String, bytes: ByteArray) {
                val doc = folder.createFile(mime, name)!!
                check(doc.name == name) { "Fixture filename: ${doc.name}, wanted $name" }
                context.contentResolver.openOutputStream(doc.uri, "wt")!!.use { it.write(bytes) }
            }
            put("disc.wav", "audio/wav", original)
            put(
                "disc.lrc",
                "application/octet-stream",
                "[00:00.000]Outside\n[00:01.000]Opening\n[00:06.000]Second\n[00:11.000]Final phrase"
                    .toByteArray(),
            )
            put(
                "disc.cue",
                "application/octet-stream",
                "PERFORMER \"CUE QA\"\nTITLE \"Intervals\"\nFILE \"disc.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"Quiet\"\nINDEX 01 00:00:01\nTRACK 02 AUDIO\nTITLE \"Loud\"\nINDEX 01 00:06:00"
                    .toByteArray(),
            )
            val sourceUri = folder.findFile("disc.wav")!!.uri.toString()
            val songs = LocalAudio(context).scanTree(grant.uri) {}.filter { it.uri == sourceUri }
            assertEquals(listOf("Quiet", "Loud"), songs.map { it.title })
            assertEquals(2, songs.map { it.id }.distinct().size)
            assertEquals("[00:00.987]Opening", songs[0].lyricsText)
            assertEquals("[00:00.000]Second\n[00:05.000]Final phrase", songs[1].lyricsText)
            store.saveSongs(songs)
            assertEquals(songs, store.songs().sortedBy { it.trackNumber })
            val a = LocalAudioAnalyzer(context).analyze(songs[0])
            val b = LocalAudioAnalyzer(context).analyze(songs[1])
            assertTrue(a.volume!!.lufs() + 12 < b.volume!!.lufs())
            assertEquals(6 * 16000 * 2 + 44, b.characterWav!!.size)
            for (mode in PlaylistExportFormat.entries) {
                val output = File(work, mode.name).apply { mkdirs() }
                val result =
                    PlaylistExporter(context, store)
                        .export(songs, "Intervals", Uri.fromFile(output), mode)
                val names =
                    File(output, result.playlistName).readLines().filter {
                        it.isNotBlank() && !it.startsWith('#')
                    }
                assertEquals(2, names.size)
                names.forEachIndexed { index, name ->
                    val target = File(output, name)
                    val restored = LocalAudio(context).read(Uri.fromFile(target))
                    assertEquals(songs[index].title, restored.title)
                    assertEquals(songs[index].lyricsText, restored.lyricsText)
                    assertTrue(abs(restored.durationMs - songs[index].durationMs) < 80)
                    if (mode == PlaylistExportFormat.ORIGINAL) {
                        target.inputStream().use { stream ->
                            val exported = WavPcm.read(stream)!!
                            assertEquals(32, exported.bits)
                            assertEquals(2, exported.channels)
                            val cue = songs[index].cueSegment()!!
                            val start = cue.startFrame(44100)
                            val end = cue.endFrame(44100, 44100L * 12)
                            assertEquals(end - start, exported.frames)
                            source.inputStream().use { input ->
                                val originalWav = WavPcm.read(input)!!
                                assertArrayEquals(originalWav.format, exported.format)
                                input.skipExactly(start * 8)
                                assertArrayEquals(
                                    input.exact(((end - start) * 8).toInt()),
                                    stream.exact(exported.dataBytes.toInt()),
                                )
                            }
                        }
                    }
                }
            }
            val sourceDocument = folder.findFile("disc.wav")!!
            assertArrayEquals(
                original,
                context.contentResolver.openInputStream(sourceDocument.uri)!!.use {
                    it.readBytes()
                },
            )
        } finally {
            store.close()
            context.deleteDatabase(database)
            work.deleteRecursively()
            check(folder.delete())
        }
    }

    @Test
    fun mediaSessionClipsPlaybackAndRetainsSegmentsAcrossQueuePersistence() = runBlocking {
        val root = File(context.cacheDir, "cue-play-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(root, "disc.wav")
        wave(file)
        var controller: MediaController? = null
        val graph = (context.applicationContext as SonoraApplication).graph
        try {
            val source = LocalAudio(context).read(Uri.fromFile(file))
            val songs =
                listOf(
                    CueSegment("file:///qa.cue", 1, 75, 225).applyTo(source),
                    CueSegment("file:///qa.cue", 2, 450, 600).applyTo(source),
                )
            graph.store.saveSongs(songs, inLibrary = false)
            val future =
                withContext(Dispatchers.Main) {
                    MediaController.Builder(
                            context,
                            SessionToken(
                                context,
                                ComponentName(context, PlaybackService::class.java),
                            ),
                        )
                        .buildAsync()
                }
            controller = future.get(10, TimeUnit.SECONDS)
            val player = controller
            withContext(Dispatchers.Main) {
                graph.loop.value = null
                graph.setSleepTimer(null)
                player.setMediaItems(songs.map { it.mediaItem() })
                player.repeatMode = Player.REPEAT_MODE_OFF
                player.shuffleModeEnabled = false
                player.prepare()
                player.play()
            }
            withTimeout(10_000) {
                while (
                    !withContext(Dispatchers.Main) { player.isPlaying && player.duration == 2000L }
                ) delay(50)
            }
            withContext(Dispatchers.Main) {
                assertEquals(
                    1_000_000L,
                    player.currentMediaItem!!.clippingConfiguration.startPositionUs,
                )
                assertTrue(player.currentPosition < 1800)
            }
            withTimeout(10_000) {
                while (
                    !withContext(Dispatchers.Main) {
                        player.currentMediaItemIndex == 1 && player.currentPosition > 250
                    }
                ) delay(50)
            }
            withContext(Dispatchers.Main) {
                assertEquals(2000L, player.duration)
                player.pause()
            }
            withTimeout(5000) {
                while (
                    withContext(Dispatchers.IO) { graph.store.snapshot()?.ids } !=
                        songs.map { it.id }
                ) delay(50)
            }
            val restored = graph.store.song(songs[1].id)!!.mediaItem()
            assertEquals(6_000_000L, restored.clippingConfiguration.startPositionUs)
            assertEquals(8_000_000L, restored.clippingConfiguration.endPositionUs)
            val updated = CueSegment("file:///qa.cue", 2, 450, 675).applyTo(source)
            graph.store.saveSongs(listOf(updated), inLibrary = false)
            graph.refresh(metadataChanged = true)
            withTimeout(5000) {
                while (
                    !withContext(Dispatchers.Main) {
                        player.duration == 3000L &&
                            player.currentMediaItem!!.clippingConfiguration.endPositionUs ==
                                9_000_000L
                    }
                ) delay(30)
            }
            withContext(Dispatchers.Main) {
                assertEquals(1, player.currentMediaItemIndex)
                assertFalse(player.playWhenReady)
            }
        } finally {
            withContext(Dispatchers.Main) {
                controller?.stop()
                controller?.clearMediaItems()
                controller?.release()
            }
            root.deleteRecursively()
        }
    }

    @Test
    fun sixChannelWavOriginalPreservesSpeakerMaskAndAll32Bits() = runBlocking {
        val root = File(context.cacheDir, "cue-surround-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = File(root, "source.wav")
            wave(source, 6)
            val target = File(root, "track.wav")
            val cue = CueSegment("file:///qa.cue", 1, 1, 76)
            source.inputStream().use { input ->
                target.outputStream().use { WavPcm.copySegment(input, it, cue) }
            }
            source.inputStream().use { input ->
                target.inputStream().use { output ->
                    val original = WavPcm.read(input)!!
                    val result = WavPcm.read(output)!!
                    assertArrayEquals(original.format, result.format)
                    assertEquals(44100L, result.frames)
                    input.skipExactly(588L * 24)
                    assertArrayEquals(input.exact(44100 * 24), output.exact(44100 * 24))
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
