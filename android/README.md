# Sonora for Android

Native Kotlin/Compose application for Android phones and Android Car boxes that run ordinary APKs. The player adapts to portrait and landscape, including short panoramic displays. This is a separate Android client; the iPhone application is unchanged.

The current implementation includes local file/folder references and Open With, persistent playlists and playback, five artwork/text pages, synchronized lyrics and translations, song/album descriptions, cached waveform/BPM and audio character, generated covers and panoramic artwork, lyric editing/manual timing and AI-assisted synchronization/transcription/repair, markers and phrase repeat, speed/pitch, equalizer/balance/normalization, sleep timers, CUE virtual tracks, crossfades and BPM-guided automatic mixes, metadata edits in Sonora, and direct-folder playlist export. Export supports originals and MP3 at 320 kb/s, keeps standalone MP3 audio without recompression, embeds lyrics and available descriptions by language, and writes an ordered portable M3U8. Editing metadata in Sonora does not rewrite the source audio.

CUE folders keep references to each interval. Analysis and playback use that interval; original export creates an independent WAV and MP3 export encodes only its audio. PCM WAV export preserves the integer width and speaker mask. Other decoded CUE exports use float32 WAV, retaining PCM24 precision and remaining playable on Android.

In **Sonido → Mezcla**, choose continuous playback, a crossfade, or automatic mixing, with a maximum overlap of 1–12 seconds. Automatic mixing uses detected beat phase when available and a reference BPM otherwise. Pause freezes both tracks; shuffle, repeated queue entries, speed/pitch and the end-of-track timer retain their behavior.

The lyric editor provides **Synchronize**, **Transcribe**, and **Repair** AI tools. Each requires an explicit analysis action and presents a review before changing the editor draft; saving remains separate. Repair keeps unrecognized original text and lets you select corrections, additions, and timing changes. Validated results, including no-speech results, are cached for offline reuse. The server receives only derived mono PCM for the selected song or CUE interval, with a ten-minute limit. Source files remain unchanged. These routes use the existing server audio-analysis service and may consume its usage allowance.

Release signing, performance on older hardware, Android 8 runtime, and physical Car box behavior are not yet verified. API 34 emulator checks are the current runtime evidence. AI lyric tools are tested against local HTTP fixtures; actual provider quality and account availability still need a separately authorized check.

## Build

Use JDK 17, Android SDK platform 36, NDK 27.2.12479018, and CMake 3.22.1. Configure `sdk.dir` in the ignored `local.properties`, or use the normal Android SDK environment configuration.

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
./gradlew :app:assembleDebugAndroidTest
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. It contains ARM64 and ARMv7 native libraries. A local CMake installation can be selected with `cmake.dir` and `cmake.version` in `local.properties`; the development Mac currently uses CMake 4.4.4. The SDK CMake 3.22.1 default has not been run on that Mac.

CMake downloads exact SHA-256-pinned TagLib 2.3.2 and LAME 4.0 source archives. Only LAME's encoder is built; its GPL decoder is excluded. Libraries use one shared C++ runtime, following the [NDK guidance](https://developer.android.com/ndk/guides/cpp-support#shared_runtimes). ARM64 libraries and APK packaging are aligned for 16 KB pages; the ARMv7 build also includes the NDK runtime for older devices. License texts, notices, and source URLs are included in `app/src/main/assets/licenses`. `.native-deps` is an optional ignored local source cache.

## Online services

Set the server address and token in **Servicios online** inside the app. Tokens are encrypted with Android Keystore and excluded from backups. No Mac credentials are bundled in the APK. Song/album descriptions use Astra medium; translations use Sol 6.1 medium through Sonora's existing proxy contracts.

Panoramic artwork uses the proxy's separate `/v1/artwork/expansions/jobs` journal. Original artwork stays separate from generated derivatives. The client saves job receipts and downloaded image hashes, then acknowledges a result after it is stored locally. The matching proxy source must be deployed separately before these endpoints are available on a live server.

## Runtime checks

Instrumentation tests use synthetic audio and an explicitly selected emulator. The real DocumentsProvider export test requires a read/write SAF grant for the disposable `Download/Sonora_QA_20261025` folder. Host-driven cold-restart and chooser fixtures are opt-in; they do not justify clearing application data or touching a physical device.

Image generation has a separate usage budget. Most network tests use local HTTP fixtures; optional real-provider tests must not be enabled as part of an ordinary test run.
