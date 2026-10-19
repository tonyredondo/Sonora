# Sonora

A native iPhone player for your own audio files. Open a folder through Files, including its subfolders, and listen without importing the whole collection into another library.

The first local implementation targets **iOS 17+** with SwiftUI. **Noche** is the default dark appearance; **Papel** is the light appearance of the same interface.

See the [library, metadata and listening guide](docs/library-and-metadata.md), the [new native screens](docs/screenshots/library/README.md), the [EQ and Crossfade screenshots](docs/screenshots/listening-tools/README.md), and the [first folder-player gallery](docs/screenshots/README.md).

The [metadata assistant](docs/metadata-assistant.md) connects to the [Rust metadata proxy](proxy/README.md) for cached MusicBrainz/AcoustID lookups, LRCLIB lyrics and Cover Art Archive downloads. Choose a recording and release edition, review the proposals and apply them to the existing editor. Connection settings and an on-device cache support offline use.

## Current implementation

- Recursive folder scanning in natural relative-path order, an editable queue, and automatic advancement.
- Play/pause, seek, previous/next, shuffle, repeat, mini-player, Now Playing, and system output selection.
- Optional ten-band EQ, six presets, manual curves, preamplification, and remembered settings.
- Continuous playback by default, adjustable Crossfade, and an optional local beat-aligned automatic-mix beta.
- Album/artist browsing, ordered playlists, song/album/artist favorites, listening history, and metadata search.
- CUE virtual songs for album images and concerts, including per-song seeking, lyrics and local ReplayGain results.
- M3U/M3U8 import/export with relative paths, explicit import reports and CUE interval preservation.
- Optional managed local folder copies for offline listening, including sidecars, progress, cancellation and explicit copy removal.
- Native CarPlay browsing and shared transport; device activation requires Apple's audio entitlement approval.
- Play next or append songs and entire recursive folders; queues can reference several source folders and restore paused.
- Plain/timed lyrics from embedded text or LRC/TXT sidecars, seeking, timing offset, and optional automatic scrolling. Cached LRCLIB lookup, ElevenLabs alignment and missing-text Scribe v2 transcription, with persistent AI attribution and preview before saving.
- Individual and batch file-tag editing, including artwork and lyrics, with explicit Save and conflict detection.
- Track/album ReplayGain, manual local loudness analysis with progress/cancellation and optional file tags, stereo balance, and a sleep timer by duration or at the end of the current song. See the [ReplayGain analysis guide](docs/replaygain-analysis.md) and [native screens](docs/screenshots/replaygain/README.md).
- Embedded title/artist/album metadata, embedded artwork, and `cover.jpg`, `folder.jpg`, `cover.png`, or `folder.png` sidecars.
- Security-scoped bookmarks and coordinated provider I/O, one upcoming playback read at a time, and bounded queued decoders. Library indexing reads local metadata without downloading the whole cloud folder. Restoring a queue does not autoplay.
- Background audio configuration, Now Playing metadata, remote-command handlers, interruption handling, and pause on headphone-route loss.
- SFBAudioEngine **0.14.0**, pinned with its resolved dependencies. Apple containers use an AVAudioFile PCM adapter; other formats use SFB decoders. Playback does not rewrite or transcode originals. The metadata editor writes tags only after Save; its staged replacement is described in the guide. Tag writing uses the already-resolved CXXTagLib 2.3.2 dependency, with no decoder upgrade.

Decoder fixtures cover MP3, WAV/PCM, FLAC, AAC/M4A, ALAC/M4A, AIFF/PCM, Ogg/Vorbis, Opus, WavPack, TTA, CAF/PCM, and raw AAC/ADTS. Nine of these format/container combinations also pass tag/artwork/lyrics round trips with unchanged decoded-audio hashes. CAF, raw AAC and TTA remain read-only in the editor. Other recognized extensions remain unverified candidates. A fixture passing does not certify every container variant or damaged file.

Continuous playback uses SFB's sequential queue. A simulator source-node capture through the actual folder controller verified **22,050 contiguous WAV PCM frames at 44.1 kHz stereo with no inserted samples**. Matching sample rates and channel layouts are required by this player path; cloud stalls or format changes can interrupt continuity.

Crossfade mixes decoded PCM at 48 kHz stereo using complementary linear gains, then passes the result through the EQ. It limits the overlap to half the shorter available track and retains the incoming tail. Only an incoming head is buffered (at most 12 seconds, about 4.6 MB); conversion and mixing run on the decoder worker. The incoming playhead includes the audio already heard during the overlap. A late provider leaves the outgoing audio intact and continues without a fade; corrupt files report an error. Queue edits, seeking, and mode changes discard the old transition plan while preserving pause intent. Changing these settings can briefly restart the current audio.

EQ covers 31 Hz–16 kHz with ±12 dB band gains and a −24…+12 dB preamp. Presets lower the preamp to leave margin; this is not a clipping limiter. Manual boosts may require further attenuation. Bands above the source's Nyquist frequency are disabled. Bypass preserves the saved curve and restores the original level. The automatic-mix beta analyzes two eight-second PCM windows per track with a 500 ms analysis budget. It aligns compatible steady pulses, adapts the overlap, and may skip up to one second of the incoming intro. It does not stretch tempo or change pitch. Uncertain or incompatible pairs use identified Crossfade; late preparation preserves continuous playback. Simulator measurements of the synthetic pulse fixture were about 35–50 ms per analysis. This is Sonora's limited local algorithm, not Apple's AutoMix implementation.

Signed-in iCloud downloads, revoked access, physical-device interruptions, Bluetooth/AirPlay, the minimum-iOS runtime, battery use, and release packaging still need device/provider validation. The simulator uses synthetic audio. Library sync, WMA and DSD remain future scope. The beta still needs listening evaluations with varied real music and physical-device energy/route measurements before a release. See the [CUE, playlist, local-copy and CarPlay guide](docs/portable-library.md) for format limits and activation requirements.

## Build and try

Open `Sonora.xcodeproj`, select the **Sonora** scheme and an iPhone simulator, then Run. Xcode resolves the pinned Swift packages. This checkout has been built with Xcode 27.0; no signing team is required for Simulator.

Physical-device builds use team `HNF8XS7V57`, bundle ID `com.tonyredondo.Sonora` and the explicit **Sonora Development** profile. Install that profile from Apple Developer and use its existing Apple Development certificate; it currently includes iTony. The device-only profile setting is generated by `scripts/generate-project.py`. Other teams, devices or distribution builds need their own matching signing configuration. CarPlay remains pending Apple approval.

Tap **Reproducir carpeta**, browse to a folder in Files, and choose **Open/Abrir**. Root and nested audio enter one queue. Cancelling or choosing an empty/unplayable folder preserves the current queue. Removing a row removes only the queue reference. Queue/repeat/shuffle edits reopen the current file at its current position to discard already-buffered successors; they may cause a brief pause.

Relaunch restores the saved queue, including its removals. Choose the folder again to rebuild the queue with newly added files. Manual next/previous preserve paused playback; repeat-one applies to automatic advancement.

Open **Biblioteca** for albums, artists, search, favorites and playlists. Song options include **Editar información**; use **Seleccionar** to edit several files together. **Ajustes → Escucha** contains ReplayGain, balance and the sleep timer.

Use **Ajustes → Apariencia** to choose Noche or Papel. The player has a native system-volume slider that stays in sync with the iPhone buttons, alongside a separate audio-output picker.

Use **Ajustes → Ecualizador** for presets, manual bands, preamp, and bypass. **Ajustes → Entre canciones** selects Continua, Crossfade or Mezcla automática (beta) and the maximum duration. Crossfade's playback conversion leaves source files unchanged; Continua retains the existing source-format path.

## Validation

From the repository root, with a booted simulator UDID:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Packages/SonoraCore
xcodebuild test -project Sonora.xcodeproj -scheme Sonora \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -derivedDataPath .build/DerivedData -scmProvider system \
  -only-testing:SonoraTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

On 2026-10-16, the expanded app/audio suite passed 54 tests on iPhone 17 Simulator / iOS 27.0. These include real metadata writes, unchanged decoded-audio hashes, multi-source restoration, listening controls, and automatic-mix analysis/alignment through EQ. Source-truncation recovery and the other Crossfade transport cases also passed five consecutive focused iterations. The Core suite passed 13 tests. Six native UI scenarios passed across bounded runs, including both themes, the fixed player at maximum text size, settings persistence, and actual individual/batch tag writes through Files.

The subsequent ReplayGain analyzer delivery passed the complete **72-test app/audio suite and five native UI tests in one run** on the same simulator. Its 18 added tests cover full-file measurements in twelve formats, mono/surround channel weighting, album aggregation, cancellation, persistent cache reuse/invalidation, source-forget races, real normalized audio output, paused restoration and verified tag writes in nine formats. The five UI tests include three new analyzer scenarios plus library and listening-settings regressions. See the [guide](docs/replaygain-analysis.md) and [captures](docs/screenshots/replaygain/README.md). Live iCloud providers, minimum-OS runtime behavior and physical-device energy use remain outside this simulator validation.

The CUE, playlist and local-copy expansion passed the complete **93-test app/audio suite and four native UI tests in one signed Simulator run**, with zero failures, skips or changed source inputs. The Core suite passed **23 tests**. These add real CUE rendering and migration, M3U/M3U8 exchange, atomic local copying and six CarPlay template/transport tests. [Native captures](docs/screenshots/portable/README.md) show both themes and maximum accessibility text. The external CarPlay screen remained black on the simulator; visual head-unit behavior and live iCloud downloads still need validation.

The Core suite covers recursion, natural ordering, symlinks, invalid paths, cancellation, and queue identity. The app suite uses real decoders and audio rendering for full-file formats, transport, restoration, errors, artwork/system metadata, interruptions, EQ frequency response/bypass, and Crossfade timing. It also verifies late preparation without a premature fade, short-track overlap, and recovery from a source truncated during playback.

The UI test additionally needs an installed Sonora app and a small demo folder. With the simulator language set to English, create its synthetic source files using the installed `ffmpeg`:

```sh
python3 scripts/seed-simulator.py <SIMULATOR_UDID>
```

Run the same Xcode test command with `-only-testing:SonoraUITests` instead of `SonoraTests`. The suite follows the actual Files picker, selects `On My iPhone → Sonora → Sonora QA`, and exercises playback, the recursive queue, both appearances, backgrounding, and paused restoration. It also checks EQ/Crossfade controls, preference persistence, and maximum accessibility text. It does not access real music or require an iCloud account. Screenshots are kept as XCTest attachments.

The Xcode project is included in the source tree. `python3 scripts/generate-project.py` regenerates it with Python's standard library; it does not require XcodeGen or Tuist. Codec fixtures can be regenerated with `python3 scripts/generate-fixtures.py` and `python3 scripts/generate-additional-fixtures.py` and the app icon with `swift scripts/generate-icon.swift`.

## Product and design

Read the [product proposal](docs/product-proposal.md) for the complete scope and the [selected visual references](docs/design/README.md) for Noche/Papel. The original boards show fictional music and the earlier collection/lyrics proposals; they are design references, not screenshots of implemented features.

The app bundles the upstream [audio license notices](Sonora/Resources/ThirdPartyNotices.txt). Distribution obligations and signed device packaging must be checked before a release.
