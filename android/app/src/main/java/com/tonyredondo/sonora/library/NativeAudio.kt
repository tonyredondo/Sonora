package com.tonyredondo.sonora

/** Native metadata is read through a borrowed descriptor; writing is limited to staged copies. */
object NativeAudio {
    init {
        System.loadLibrary("sonora_audio")
    }

    external fun inspect(fd: Int, offset: Long, length: Long, extension: String): String

    external fun artwork(fd: Int, offset: Long, length: Long, extension: String): ByteArray?

    external fun writeTags(
        path: String,
        names: Array<String>,
        values: Array<Array<String>>,
        artwork: ByteArray?,
    )

    external fun copyPictures(
        fd: Int,
        offset: Long,
        length: Long,
        extension: String,
        destination: String,
    ): Int

    external fun encoderOpen(path: String, sampleRate: Int, channels: Int): Long

    external fun encoderWrite(handle: Long, interleaved: FloatArray, frames: Int)

    external fun encoderFinish(handle: Long)

    external fun encoderAbort(handle: Long)
}
