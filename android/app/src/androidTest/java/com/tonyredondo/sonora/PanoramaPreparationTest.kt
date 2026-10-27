package com.tonyredondo.sonora

import android.graphics.Bitmap
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.*
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PanoramaPreparationTest {
    private fun main(action: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(action)

    private fun png(width: Int, color: Int = 0xff887744.toInt()): ByteArray =
        ByteArrayOutputStream().use { output ->
            Bitmap.createBitmap(width, 32, Bitmap.Config.ARGB_8888)
                .apply { eraseColor(color) }
                .compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
        }

    private suspend fun ready(graph: AppGraph, ids: List<String>) =
        withTimeout(10000) {
            while (ids.any { graph.extras.value[it]?.panorama == null }) delay(10)
        }

    @Test
    fun duplicateCoversShareOneJobAndVerifiedResultRestoresOffline() = runBlocking {
        exercise(restart = false, corrupt = false)
    }

    @Test
    fun processRestartRecoversJobWithoutSubmittingAnotherGeneration() = runBlocking {
        exercise(restart = true, corrupt = false)
    }

    @Test
    fun corruptDownloadIsNeverAcknowledgedOrPublished() = runBlocking {
        exercise(restart = false, corrupt = true)
    }

    @Test
    fun forgottenServerJobIsSubmittedAgainWithTheSameOriginalImage() = runBlocking {
        exercise(restart = true, corrupt = false, forgotten = true)
    }

    private suspend fun exercise(restart: Boolean, corrupt: Boolean, forgotten: Boolean = false) {
        val graph = ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        withTimeout(5000) { while (!graph.ready.value) delay(10) }
        val old = graph.online.value
        val ids = List(2) { "panorama-${UUID.randomUUID()}" }
        val source =
            File(graph.application.cacheDir, "${ids.first()}.png").apply {
                writeBytes(png(32, 0xff000000.toInt() or ids.first().hashCode()))
            }
        val originalHash = contentDigest(source.readBytes())
        val bytes = png(72)
        val posts = AtomicInteger()
        val requests = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val acks = AtomicInteger()
        val polls = AtomicInteger()
        val completed = AtomicBoolean(!restart)
        val server = MockWebServer()
        val jobId = "a".repeat(64)
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests.add("${request.method} ${request.path}")
                    check(request.getHeader("Authorization") == "Bearer synthetic-panorama-token")
                    // Other automatic queue features share this graph and transport. This fixture
                    // serves only panorama routes; unrelated requests must not count as
                    // generations.
                    if (request.path?.startsWith("/v1/artwork/expansions/jobs") != true)
                        return MockResponse()
                            .setResponseCode(503)
                            .setBody("{\"error\":\"codex_disabled\"}")
                    return when {
                        request.path?.endsWith("/ack") == true -> {
                            assertEquals(
                                contentDigest(bytes),
                                JSONObject(request.body.readUtf8()).getString("sha256"),
                            )
                            acks.incrementAndGet()
                            MockResponse().setResponseCode(204)
                        }
                        request.path?.endsWith("/image") == true ->
                            MockResponse()
                                .setHeader("Content-Type", "image/png")
                                .setHeader(
                                    "x-content-sha256",
                                    if (corrupt) "0".repeat(64) else contentDigest(bytes),
                                )
                                .setBody(Buffer().write(bytes))
                        request.method == "POST" -> {
                            posts.incrementAndGet()
                            val upload = JSONObject(request.body.clone().readUtf8())
                            assertEquals(
                                originalHash,
                                contentDigest(
                                    android.util.Base64.decode(
                                        upload.getString("image"),
                                        android.util.Base64.NO_WRAP,
                                    ),
                                ),
                            )
                            assertEquals(
                                "9:4",
                                JSONObject(request.body.readUtf8()).getString("aspect"),
                            )
                            MockResponse()
                                .setResponseCode(202)
                                .setBody("{\"id\":\"$jobId\",\"state\":\"queued\"}")
                        }
                        else -> {
                            polls.incrementAndGet()
                            if (forgotten && completed.get() && posts.get() == 1)
                                return MockResponse()
                                    .setResponseCode(404)
                                    .setBody("{\"error\":\"artwork_expansion_not_found\"}")
                            MockResponse()
                                .setBody(
                                    "{\"id\":\"$jobId\",\"state\":\"${if(completed.get()) "completed" else "running"}\"}",
                                )
                        }
                    }
                }
            }
        server.start()
        var ownedScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        try {
            graph.store.saveSongs(
                ids.map { Song(it, "content://qa/$it", "Panorama QA", artworkPath = source.path) },
            )
            val online = OnlineSettings(server.url("/").toString(), "synthetic-panorama-token")
            main { graph.online.value = online }
            var engine = PanoramaPreparation(graph, ownedScope, 20)
            main {
                engine.setAspect("9:4")
                engine.prepare(ids)
            }
            if (restart) {
                withTimeout(5000) { while (polls.get() == 0) delay(10) }
                ownedScope.cancel()
                delay(80)
                completed.set(true)
                ownedScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                engine = PanoramaPreparation(graph, ownedScope, 20)
                main {
                    engine.setAspect("9:4")
                    engine.prepare(ids)
                }
            }
            if (corrupt) {
                withTimeout(5000) {
                    while (
                        ids.any {
                            graph.extras.value[it]
                                ?.progress
                                ?.get(PreparationStage.PANORAMA)
                                ?.state != PreparationState.FAILED
                        }
                    ) delay(10)
                }
                assertTrue(ids.all { graph.extras.value[it]?.panorama == null })
                assertEquals(0, acks.get())
            } else {
                ready(graph, ids)
                withTimeout(5000) { while (acks.get() == 0) delay(10) }
                assertEquals(
                    graph.extras.value[ids[0]]?.panorama,
                    graph.extras.value[ids[1]]?.panorama,
                )
                assertEquals(
                    contentDigest(bytes),
                    contentDigest(File(graph.extras.value[ids[0]]!!.panorama!!).readBytes()),
                )
                server.shutdown()
                ownedScope.cancel()
                ownedScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                engine = PanoramaPreparation(graph, ownedScope, 20)
                main {
                    graph.online.value =
                        OnlineSettings(online.endpoint, online.token, enabled = false)
                    graph.extras.value = graph.extras.value - ids.toSet()
                    engine.setAspect("9:4")
                    engine.prepare(ids)
                }
                ready(graph, ids)
            }
            assertEquals(requests.joinToString("; "), if (forgotten) 2 else 1, posts.get())
            assertEquals(originalHash, contentDigest(source.readBytes()))
        } finally {
            ownedScope.cancel()
            main { graph.online.value = old }
            graph.store.removeSongs(ids)
            source.delete()
            server.shutdown()
        }
    }
}
