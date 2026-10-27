package com.tonyredondo.sonora

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProxyClientTest {
    @Test
    fun sendsTheWholeDocumentAndRejectsMovedMissingOrMalformedLineIds() = runBlocking {
        val server = MockWebServer()
        server.start()
        try {
            val doc = LyricsDocument.parse("[00:01]I will see you\n[00:02]from the distance")
            val input = ProxyContent.translationInput(doc, "es")
            server.enqueue(
                MockResponse()
                    .setBody(
                        """{"model":"gpt-6.1-sol","effort":"medium","lines":[{"id":0,"text":"Te veré"},{"id":1,"text":"desde la distancia"}]}""",
                    ),
            )
            val value =
                ProxyClient(
                        OnlineSettings(server.url("/proxy/").toString(), "synthetic-test-token"),
                    )
                    .post("v1/lyrics/translate", input)
            assertEquals(
                mapOf(0 to "Te veré", 1 to "desde la distancia"),
                ProxyContent.translation(value, doc),
            )
            val request = requireNotNull(server.takeRequest(2, TimeUnit.SECONDS))
            assertEquals("/proxy/v1/lyrics/translate", request.path)
            assertEquals("Bearer synthetic-test-token", request.getHeader("Authorization"))
            assertEquals(2, JSONObject(request.body.readUtf8()).getJSONArray("lines").length())
            for (lines in
                listOf(
                    "[]",
                    "[{\"id\":1,\"text\":\"a\"},{\"id\":0,\"text\":\"b\"}]",
                    "[{\"id\":0.5,\"text\":\"a\"},{\"id\":1,\"text\":\"b\"}]",
                )) {
                assertThrows(ProxyFailure::class.java) {
                    ProxyContent.translation(
                        JSONObject("""{"model":"gpt-6.1-sol","effort":"medium","lines":$lines}"""),
                        doc,
                    )
                }
            }
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun authorizationErrorsAndCancellationNeverBecomeSuccessfulContent() = runBlocking {
        val server = MockWebServer()
        val arrived = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val calls = java.util.concurrent.atomic.AtomicInteger()
        server.dispatcher =
            object : okhttp3.mockwebserver.Dispatcher() {
                override fun dispatch(
                    request: okhttp3.mockwebserver.RecordedRequest,
                ): MockResponse {
                    if (calls.incrementAndGet() == 1)
                        return MockResponse().setResponseCode(401).setBody("{}")
                    arrived.countDown()
                    check(release.await(2, TimeUnit.SECONDS))
                    return MockResponse().setBody("{}")
                }
            }
        server.start()
        try {
            try {
                ProxyClient(OnlineSettings(server.url("/").toString())).check()
                fail("Expected unauthorized")
            } catch (error: ProxyFailure) {
                assertEquals("unauthorized", error.code)
            }
            val job = async { ProxyClient(OnlineSettings(server.url("/").toString())).check() }
            withContext(Dispatchers.IO) { assertTrue(arrived.await(2, TimeUnit.SECONDS)) }
            job.cancelAndJoin()
            assertTrue(job.isCancelled)
        } finally {
            release.countDown()
            server.shutdown()
        }
    }

    @Test
    fun endpointAndLanguageChangesAreValidatedWithoutExposingTokens() {
        assertThrows(IllegalArgumentException::class.java) {
            OnlineSettings("https://user:secret@example.com/").validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            OnlineSettings("https://example.com/?token=x").validate()
        }
        assertFalse(
            OnlineSettings(token = "synthetic-secret").toString().contains("synthetic-secret"),
        )
    }
}
