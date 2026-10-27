package com.tonyredondo.sonora

import android.net.Uri
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LyricsPreviewTest {
    @Test fun audioPreviewRestoresThePhraseLoopAndNeverPausesANewDuplicateOccurrence()=runBlocking {
        val graph=ApplicationProvider.getApplicationContext<SonoraApplication>().graph
        val id="lyrics-preview-${UUID.randomUUID()}";val source=File(graph.application.cacheDir,"$id.wav")
        InstrumentationRegistry.getInstrumentation().context.assets.open("fixture.wav").use { input -> source.outputStream().use(input::copyTo) }
        val song=LocalAudio(graph.application).read(Uri.fromFile(source)).copy(id=id)
        graph.store.saveSongs(listOf(song),inLibrary=false)
        val scenario=ActivityScenario.launch(MainActivity::class.java);lateinit var model:PlayerModel
        scenario.onActivity { model=ViewModelProvider(it)[PlayerModel::class.java] }
        suspend fun until(check:()->Boolean) { withTimeout(7000) { while(!withContext(Dispatchers.Main) { check() }) delay(30) } }
        try {
            until { model.controller!=null }
            withContext(Dispatchers.Main) { model.play(listOf(song,song)) }
            until { model.controller!!.isPlaying }
            val loop=LoopRegion(song.id,0,2000)
            withContext(Dispatchers.Main) { graph.loop.value=loop;model.listenToAIFragment(song,4.0,5.0) }
            until { !model.controller!!.playWhenReady && model.controller!!.currentPosition>=5000 }
            withContext(Dispatchers.Main) {
                assertEquals(loop,graph.loop.value)
                model.listenToAIFragment(song,8.0,9.0)
                model.listenToAIFragment(song,10.0,11.0)
            }
            until { model.controller!!.isPlaying && model.controller!!.currentPosition>10400 }
            withContext(Dispatchers.Main) { assertNull(graph.loop.value);model.stopAILyricPreview();assertEquals(loop,graph.loop.value);assertFalse(model.controller!!.playWhenReady);model.listenToAIFragment(song,1.0,2.0);model.controller!!.seekToNextMediaItem() }
            until { model.controller!!.currentMediaItemIndex==1 && model.controller!!.isPlaying && model.controller!!.currentPosition>250 }
            withContext(Dispatchers.Main) { assertNull(graph.loop.value) }
        } finally { withContext(Dispatchers.Main) { model.stopAILyricPreview();graph.loop.value=null;model.controller?.stop();model.controller?.clearMediaItems() };scenario.close();graph.store.removeSongs(listOf(id));source.delete() }
    }
}
