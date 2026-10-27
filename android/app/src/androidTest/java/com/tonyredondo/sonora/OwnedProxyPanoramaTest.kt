package com.tonyredondo.sonora

import android.graphics.BitmapFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Opt-in wire proof against an owned proxy fixture. Codex must be disabled; it cannot spend usage.
 */
class OwnedProxyPanoramaTest {
    @Test
    fun cachedNativeImageRoundTripPreservesOriginalPixelsThroughStreamingUpload() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        val endpoint = args.getString("sonora_owned_proxy")
        assumeTrue(
            "Requires an isolated proxy with a previously cached native image and Codex disabled",
            endpoint != null,
        )
        val id = requireNotNull(args.getString("sonora_cached_panorama_id"))
        val expected = requireNotNull(args.getString("sonora_cached_panorama_sha"))
        val app = ApplicationProvider.getApplicationContext<SonoraApplication>()
        val source = File(app.cacheDir, "wire-source-${UUID.randomUUID()}.png")
        val saved = File(app.cacheDir, "wire-result-${UUID.randomUUID()}.png")
        val large = File(app.cacheDir, "wire-large-${UUID.randomUUID()}.png")
        InstrumentationRegistry.getInstrumentation().context.assets.open("cover.png").use { input ->
            source.outputStream().use(input::copyTo)
        }
        val digest = contentDigest(source.readBytes())
        try {
            val client =
                ProxyClient(OnlineSettings(endpoint!!, "sonora-panorama-synthetic-probe-only"))
            val status = client.get("v1/status", emptyMap())
            assertFalse(status.getJSONObject("artwork_expansion").getBoolean("enabled"))
            assertEquals(
                "completed",
                client.get("v1/artwork/expansions/jobs/$id", emptyMap()).getString("state"),
            )
            val job = client.expandArtwork(source, digest, "9:4")
            assertEquals(id, job.getString("id"))
            assertEquals("completed", job.getString("state"))
            val image = client.image("v1/artwork/expansions/jobs/$id/image")
            assertEquals(expected, image.sha256)
            saved.outputStream().use { output ->
                output.write(image.bytes)
                output.fd.sync()
            }
            assertEquals(expected, contentDigest(saved.readBytes()))
            client.acknowledge("v1/artwork/expansions/jobs/$id/ack", image.sha256)
            val original = BitmapFactory.decodeFile(source.path)!!
            val expanded = BitmapFactory.decodeFile(saved.path)!!
            try {
                assertTrue(expanded.width > original.width)
                assertEquals(original.height, expanded.height)
                val left = IntArray(original.width * original.height)
                val right = IntArray(left.size)
                original.getPixels(left, 0, original.width, 0, 0, original.width, original.height)
                expanded.getPixels(right, 0, original.width, 0, 0, original.width, original.height)
                assertArrayEquals(left, right)
            } finally {
                original.recycle()
                expanded.recycle()
            }
            assertEquals(digest, contentDigest(source.readBytes()))
            // Exercise the real route's multi-megabyte body limit and chunked JSON parsing.
            val random =
                android.graphics.Bitmap.createBitmap(
                    1024,
                    1024,
                    android.graphics.Bitmap.Config.ARGB_8888,
                )
            try {
                var seed = 0x125ac32
                val pixels =
                    IntArray(1024 * 1024) {
                        seed = seed xor (seed shl 13)
                        seed = seed xor (seed ushr 17)
                        seed = seed xor (seed shl 5)
                        0xff000000.toInt() or seed
                    }
                random.setPixels(pixels, 0, 1024, 0, 0, 1024, 1024)
                large.outputStream().use {
                    random.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
            } finally {
                random.recycle()
            }
            assertTrue(large.length() > 1_000_000)
            try {
                client.expandArtwork(large, contentDigest(large.readBytes()), "9:4")
                fail("An uncached image must never start generation while Codex is disabled")
            } catch (failure: ProxyFailure) {
                assertEquals("codex_disabled", failure.code)
                assertEquals(503, failure.status)
            }
        } finally {
            source.delete()
            saved.delete()
            large.delete()
        }
    }
}
