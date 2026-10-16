# Sonora product proposal

Status: expanded local player, 2026-10-16. The user approved the remaining local collection/listening features and original-file metadata editing. The iOS 17+ project now includes library/lyrics/editing, multiple source queues, listening controls and a limited beat-aligned mix beta. See the [current guide](library-and-metadata.md) and README for measured coverage and open device/provider validation.

## Agreed starting point

Sonora is an iPhone music player for the owner's audio files. Its GitHub repository is public under `tonyredondo/Sonora`. The first version opens a folder through Files, including folders on the iPhone and in iCloud Drive, and plays the files in place. It does not require a music-service subscription or a Sonora account.

The design deliverable established the repository, feature proposal, and visual references. The user then approved a first Xcode implementation with real folder/queue playback and simulator validation. The approved design uses Noche for dark appearance and Papel for iOS light appearance, starting with Noche as the default and first implementation target. Both appearances share navigation, controls, and functionality. The first implementation targets iOS 17+, uses SwiftUI, a small SonoraCore package, SFBAudioEngine 0.14.0, and UserDefaults for a security-scoped folder bookmark and queue snapshot. Distribution and a database beyond the current saved local index remain future decisions.

## Initial scope: open a folder and play

Selecting a folder in Files builds a single queue from the audio files in that folder and all its subfolders, then starts playback and advances through the queue automatically. The user does not need to return to Files or select each track. Include queue/folder browsing, transport controls, embedded song/album/artist metadata and artwork when present, background/system playback, gapless continuity for concerts, and optional adjustable crossfade. The requested transition goal is both Crossfade and adaptive AutoMix-style behavior if feasible; the user accepts the feasible alternative if both cannot be delivered. The implemented automatic-mix beta aligns compatible steady pulses without time stretching; its limits and conservative fallback are explicit in the current guide. The approved ten-band EQ and presets now share the player's processing graph.

Build the recursive queue in deterministic natural relative-path order, including numerical ordering such as track 2 before track 10 and CD 2 before CD 10. Keep folder grouping, distinguish identical basenames in different subfolders, and allow explicit queue reordering. Do not follow links outside the authorized folder or enter traversal loops. A future album-library index is not required for folder playback.

Folder selection is an explicit play action. Assemble its queue with cancellable scan progress, then replace the current queue and start the first playable track when preparation succeeds. Cancelling the picker/scan or selecting an empty/unreadable folder leaves the current queue intact. An explicit Add to Queue action appends instead and preserves the current track. Unsupported/corrupt audio entries report a reason and do not repeatedly block automatic advancement. Queue items are file references; do not open every decoder, read every embedded cover, or download the whole tree merely to build the list.

Use the system document picker to open a folder in place. Keep a security-scoped bookmark to restore access, plus relative child paths and minimal queue/display state. There is no mandatory import, whole-folder download, or copy into a Sonora-managed audio library. Playback reads source audio; cached artwork and metadata are rebuildable. The subsequently approved editor writes tags only after an explicit Save to the original file. Opening iCloud Drive is not multi-device Sonora-library synchronization.

For cloud-only files, ask the provider/system to make the selected file locally readable before opening the decoder. Prepare upcoming tracks with bounded look-ahead so automatic advancement and concert boundaries do not wait until the current track ends to request their data. Show waiting/downloading, cancellation, no-network, provider and storage failures. iOS manages the provider's local cache; access to a cloud folder does not guarantee that every track is available offline. SFBAudioEngine accepts file URLs, so this is provider-backed file playback, not direct HTTP streaming from iCloud. Materialization must not block the UI, and playback must not be reported as started before the file and decoder are ready. If the next file is unavailable in time, show its preparation/error state; a network stall cannot be described as gapless playback.

Keep scoped access alive for enumeration, metadata reads, playback, and queued/preloaded decoders until their actual reads finish or are cancelled. A temporary access scope around an asynchronous play/enqueue call is insufficient. Coordinate provider I/O, recover stale bookmarks, and ask the user to choose the folder again if access is revoked. Handle moved/deleted files and refresh folder contents on return without assuming perpetual background folder watching. Removing a queued item or forgetting a folder must not delete source files.

The subsequent expansion adds local collection indexing, album/artist views, favorites, playlists, lyrics and original-file tag editing. Managed audio import, backups and online enrichment remain future scope.

## Playback

The first usable player needs play/pause, seeking, previous/next, shuffle, repeat-one/repeat-all, a mini-player, and an editable queue. Allow play next, add to the end, reorder, and remove without losing the current position. Restore the queue and position after relaunch without unexpectedly starting playback.

Background audio, Lock Screen and Control Center metadata, headset/AirPods commands, audio interruptions, and output changes belong to the initial playback contract. Unplugging headphones must pause. Returning from a call must follow the system's resumption advice and the user's most recent intent. Include an output picker for available system routes, including AirPlay, and test Bluetooth/AirPlay behavior separately from local decoding.

Track/album ReplayGain normalization, balance, and a sleep timer with end-of-track behavior are implemented in the local expansion. Multiband EQ with presets/preamp is implemented locally. Gapless playback and optional overlapping transitions belong to the initial player. Keep DSP optional and preserve original files; all audio features need measurements before being described as working.

## Initial transitions: continuous playback and optional crossfade

Continuous playback is the proposed default for concerts and album sequences: join adjacent tracks without adding silence, cutting their audio, or overlapping their content. Preserve any silence that belongs to the recording. Handle codec encoder delay and padding where the format supplies that information; do not implement gapless playback by guessing which quiet samples to trim.

Crossfade fades the outgoing track down while fading the next track up over an adjustable interval. A 1-12 second control, plus disabled/continuous mode, follows the familiar [Apple Music crossfade model](https://support.apple.com/es-la/105067). Crossfade is explicitly optional so a concert's continuous recording is not mixed over itself. Its duration must fit short tracks, and changing the setting must not corrupt an active transition. The additional requested adaptive mode is assessed separately below.

The next track must be locally readable, decoded ahead, and scheduled on the audio timeline before the boundary. Bound cloud look-ahead and PCM buffering instead of loading the entire folder into memory. If the next track is not ready, let the current track finish, show preparation/failure honestly, and preserve queue state; do not truncate its end to fake a successful transition. Manual next/previous, seeking, cancellation, queue edits, interruptions and output changes must cancel or reschedule pending audio without duplicate or orphaned playback.

Gapless and crossfade require different proof. For continuous playback, split a known continuous PCM signal into tracks, render the queue and compare the join with the unsplit reference, then listen to concert fixtures. Cover the initial codecs, their padding metadata, and sample-rate/channel changes. For crossfade, render distinguishable input signals and inspect the overlap duration, gain envelope, clipping/headroom and resulting timeline; test short files and unavailable next files. Exercise both modes on-device, in the background, with route changes, and with the proposed EQ insertion point before accepting the engine design.

## Requested adaptive mixing: feasibility pending

The desired third mode analyzes local tracks to choose suitable transition points and overlap lengths, and can align beats or adjust tempo when the result is reliable. It must preserve the selected queue order. Continuous playback remains the default for concerts; neither overlapping mode is applied automatically to concert playback. If beat analysis is unreliable or a pair is unsuitable, use a conservative, visibly identified Crossfade/continuous result without pretending it was beat matched.

Apple's documented AutoMix behavior concerns Apple Music catalog content. The reviewed MusicKit overview did not identify a documented way to feed arbitrary Files/iCloud audio into that feature. Sonora must assess its own adaptive processing; no equivalent quality or reuse of Apple's algorithm is promised. The [Apple Music transition documentation](https://support.apple.com/es-la/105067) and [MusicKit overview](https://developer.apple.com/documentation/musickit) are product/API boundaries, not a ready-made local-file implementation.

There are suitable building blocks, so adaptive mixing is technically plausible rather than established as impossible. Apple's [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch) independently controls rate and pitch. [Essentia's RhythmExtractor2013](https://essentia.upf.edu/reference/std_RhythmExtractor2013.html) estimates tempo and beat positions, but its [licensing](https://essentia.upf.edu/licensing_information.html), mobile packaging and analysis cost need evaluation before adoption. [Superpowered AdvancedAudioPlayer](https://docs.superpowered.com/reference/latest/advanced-audio-player/) documents beat/tempo synchronization and time stretching as another technical reference; its documented built-in format matrix is narrower than Sonora's goal, so it is not an automatic replacement for the decoder choice. These are research candidates, not installed dependencies or approved purchases.

The feasibility check must cover steady and variable tempos, low-confidence/no-beat material, vocals at transition boundaries, stretching artifacts, time/pitch latency, CPU/battery use, iCloud readiness, codec coverage, and the shared EQ path. Analyze locally and bound look-ahead, memory and processing; do not download or analyze an entire cloud library simply to start a folder. Demonstrating the required components does not prove a finished adaptive mix.

The local feasibility result is a bounded steady-pulse beta, alongside ordinary Crossfade. It aligns compatible pulse grids and limits estimated drift, with no tempo/pitch processing or vocal-phrase detection. Synthetic PCM and real folder-player/EQ tests exercise this narrower behavior. Varied real-music listening and device/cloud measurements remain release work; no parity with Apple AutoMix is claimed. No analysis SDK was installed or purchased.

## Formats and audio quality

| Group | Intended coverage | Proof required |
| --- | --- | --- |
| Initial formats | MP3; WAV/PCM; FLAC; AAC in M4A; ALAC in M4A; AIFF/PCM; assess CAF | Decode, seek, duration, metadata, artwork, background playback, and transitions using representative files on the minimum supported iOS version |
| Additional formats | Ogg/Vorbis, Ogg/Opus, WavPack, APE, WMA, additional container variants | Check native capability first, then assess a decoder's coverage, maintenance, licensing, package size, and battery cost |
| Specialist collections | CUE sheets, long single-file albums, DSD, multichannel sources | Separate feasibility and UX work; define seeking, track boundaries, conversion policy, and output behavior |

No extension alone proves a file is playable. Containers, codecs, bit depths, sample rates, channel layouts, and damaged files need separate checks. A broad format goal does not mean every possible audio format is already supported.

Show source-file information such as `FLAC · 24 bit / 96 kHz` separately from the current output route and its negotiated format. A high-resolution file does not prove lossless Bluetooth playback, matching output sample rate, or bit-perfect output. Do not down-convert originals during import. Any future playback conversion must be explicit and leave the source intact.

## Metadata, artwork and original-file editing

Read embedded title, artist, album artist, album, disc and track numbers/totals, genre, date, composer, comments, lyrics, and available loudness tags. Store technical details including codec, container, duration, bit depth where meaningful, sample rate, channels, and bitrate. Keep multiple values when the source distinguishes them.

Prefer embedded artwork, then user-selected sidecars such as `cover.jpg` or `folder.jpg`, then an optional online match. Handle absent and oversized artwork, cache display-sized versions, and keep full-resolution artwork off scrolling hot paths. Artist pages show the local discography, track list, artwork, and useful metadata; an external biography is optional.

The user explicitly replaced the earlier override-only proposal with original-file editing like iTunes, including lyrics and batch album/song edits. The editor previews selected fields and artwork, fixes its file targets, checks external changes, stages the update, verifies requested tags, and reports each result. The current guide lists the nine fixture-verified writable combinations and read-only exceptions. Online metadata lookup must show its candidate and provenance before replacing user data. No external metadata service is required for importing or playing music.

MusicBrainz and Cover Art Archive are candidates for optional enrichment. Match the release edition rather than guessing from artist/title alone. Review usage and image-rights requirements before shipping. MusicBrainz currently requires an identifying User-Agent and a maximum of one API request per second; use caching and bounded retries. See the [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) and [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API).

## Lyrics

Prefer embedded synchronized lyrics when available, then user-provided `.lrc`, then embedded plain text or a `.txt` sidecar. The reader needs a clear distinction between timed and untimed lyrics, tap-to-seek for timed lines, a timing offset, an option to pause automatic scrolling, and useful empty/error states. Handle Unicode, multiple timestamps, malformed lines, and instrumental tracks.

Automatic lyric lookup is an optional later integration. A provider, usage rights, attribution, availability, and any cost must be evaluated before enabling it. Do not assume every song has lyrics or synchronization data. Do not scrape commercial lyric sites. The mockups use newly written fictional lines.

## Collection tools

Provide user playlists with ordering, favorites for songs/albums/artists, recently added and recently played views, listening history with a clear-history action, and search across titles, artists, albums, and metadata. Filters and sorting should work with large libraries and incomplete tags. Multi-select actions should support queueing and playlist management without obscuring playback.

Playlist import/export, smart playlists, import history, backup/restore, duplicate review, and artwork/metadata editing belong in the broader feature set. Define how exported relative paths map back to files; do not export private sandbox paths as if another app could use them. Backups must distinguish library metadata from audio files.

## Navigation and accessibility

The initial UI needs Open Folder, folder contents, a mini-player/Now Playing, and Queue. The existing boards are longer-term visual references. Their plus/import action becomes Open Folder. The expanded implementation adds a working Biblioteca destination for albums, artists, favorites, playlists, history and search, alongside the existing folder player and Lyrics.

Support light/dark appearance, Dynamic Type, VoiceOver names and adjustable sliders, Reduce Motion, safe areas, and controls at least 44 points wide/high. Artwork-derived colors must retain text contrast. Show shuffle, repeat, favorite, download, and error state with more than color. Test long titles and translations, not only the sample content in the boards.

The [selected visual references](design/README.md) define Noche for dark appearance and Papel for iOS light appearance. The native implementation supplies artist detail, queue, playlists, search, indexing/save progress and empty/error states. Actual simulator screenshots and interaction tests accompany the selected references; physical VoiceOver and provider behavior still need validation.

## Audio-library evaluation

The implementation pins **SFBAudioEngine 0.14.0** for decoding, metadata, and sequential playback with AVAudioEngine. Sonora adds EQ through its graph hooks and Crossfade through PCM decoder wrappers. Native AVAudioFile decoding handles Apple containers in the same pipeline because the SFB Core Audio callback rejected a valid short M4A fixture with EOF -39. Runtime evidence is recorded in the README; broad compatibility and distribution checks remain open. The [release](https://github.com/sbooth/SFBAudioEngine/releases/tag/0.14.0) was published on 2026-09-14; the reviewed release commit is `7dea577e74723a182189687ab84d962c4607c3d5`. Its [package manifest](https://github.com/sbooth/SFBAudioEngine/blob/7dea577e74723a182189687ab84d962c4607c3d5/Package.swift) declares iOS 15 as the package minimum; Sonora's approved minimum is iOS 17; runtime proof currently uses an iOS 27 simulator.

| Candidate | Fit for Sonora | Tradeoff |
| --- | --- | --- |
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) | Adds decoders beyond Core Audio, exposes metadata/artwork, and uses a customizable AVAudioEngine graph | Used locally; Simulator WAV continuity and mixed-format Crossfade through EQ have passed. Device slices, release size, licenses, and broader real-file coverage still need validation. WMA is not a documented additional decoder. |
| [VLCKit/libVLC](https://github.com/videolan/vlckit) | Broad media support; [its own EQ API](https://videolan.videolan.me/VLCKit/interface_v_l_c_audio_equalizer.html) includes bands, presets, and preamp | Alternative if the proven format matrix favors VLC. It owns its own audio pipeline; EQ integration must follow the selected VLCKit release. Inspect its LGPL and bundled-component obligations. |
| [BASS](https://www.un4seen.com/bass.html) | iOS audio engine with codec add-ons and BASS FX effects | Viable alternative, but format coverage depends on the iOS add-ons shipped. Its noncommercial/commercial licensing model is an additional product decision; no license purchase is authorized. |
| [AudioKit](https://www.audiokit.io/AudioKit/documentation/audiokit/audioplayer) or Apple APIs alone | Native AVAudioEngine processing and effects | AudioKit's player consumes AVAudioFile; it is not, by itself, evidence of the broader independent decoder coverage we want. |

The [SFBAudioEngine README](https://github.com/sbooth/SFBAudioEngine/blob/7dea577e74723a182189687ab84d962c4607c3d5/README.md) documents Core Audio formats plus FLAC/MP3/Opus decoders, Vorbis, WavPack, Monkey's Audio, and other formats. Its playback convenience API takes file URLs, which fits a locally readable provider URL. Validate MP3, WAV/PCM, FLAC, AAC/M4A, ALAC, and AIFF first, then representative Vorbis/Opus, WavPack, and APE files. Do not promise every extension or WMA/DSD/CUE behavior from this list.

The [player header](https://github.com/sbooth/SFBAudioEngine/blob/7dea577e74723a182189687ab84d962c4607c3d5/Sources/CSFBAudioEngine/include/SFBAudioEngine/SFBAudioPlayer.h) limits its gapless guarantee to matching sample rate and channel count; different formats reconfigure the graph. Its graph API and delegate now host Sonora's EQ. There is no ready-made crossfade switch: Sonora uses the [PCM decoder protocol](https://github.com/sbooth/SFBAudioEngine/blob/7dea577e74723a182189687ab84d962c4607c3d5/Sources/CSFBAudioEngine/include/SFBAudioEngine/SFBPCMDecoding.h) to mix an outgoing tail with a bounded incoming head before enqueueing the remainder. SFB keeps exclusive ownership of each enqueued decoder; a synchronized handoff transfers only the not-yet-enqueued successor. Simulator tests verify overlap timing, gain, playhead advancement, cancellation, and the EQ path.

SFBAudioEngine itself is MIT-licensed, while the default package also includes separately licensed dependencies; its README specifies dynamic linking for several LGPL components. Keep the full dependency notices and verify the actual distribution configuration.

## Equalizer and presets

The local implementation uses SFB's decoder queue with an outgoing-tail/incoming-head PCM wrapper for Crossfade, normalized to 48 kHz stereo. Complementary linear transition gains precede AVAudioUnitEQ and output. Continuous mode keeps the source-format path and does not overlap tracks. The graph uses SFB's supported modification/reconfiguration hooks. Ten-band response, preamp, bypass, persistence, low-rate mono reconfiguration, and mixed-format Crossfade through EQ have passed simulator audio checks. The automatic-mix beta uses local pulse analysis without time/pitch processing. Device CPU/battery use, parameter-change noise, and physical-route behavior remain unverified.

[AVAudioUnitEQ](https://developer.apple.com/documentation/avfaudio/avaudiouniteq) creates a multiband equalizer and offers overall gain. Its [band parameters](https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters) expose filter type, frequency, bandwidth, gain, and bypass. The user approved ten bands, presets, manual adjustment, and preamp. Sonora remembers Plano, Graves, Voces, Rock, Jazz, Clásica, custom values, reset, and bypass without another codec library.

Before shipping EQ, measure its frequency response, clipping/headroom, CPU and battery effects, parameter-change noise, low-sample-rate band handling, and output-route behavior. Use suitable preamp attenuation with boosts, and verify the combined response rather than assuming that a nominal gain limit prevents clipping. EQ never rewrites audio files. DSD/DoP passthrough and PCM DSP are separate paths; do not promise EQ on unconverted DSD.

## Native app responsibilities

Use native Swift/SwiftUI with concrete ownership of folder access/provider readiness, metadata reads, and transport state. MediaPlayer and AVAudioSession still supply system commands, Now Playing, background audio, interruption handling, and routing; choosing a decoder does not implement those features. Keep playback read-only and require explicit original-file Save for metadata edits. No backend or speculative engine abstraction is needed.

Keep folder enumeration, provider waits, metadata extraction, and artwork decoding away from the UI thread with bounded concurrency. Persist bookmarks and queue/preferences separately from rebuildable artwork/metadata caches. The audio transport owns playback state; views observe it instead of creating independent players.

Apple's relevant contracts:

- [File and folder access](https://developer.apple.com/documentation/uikit/providing-access-to-directories): provider access uses security-scoped URLs, bookmarks, and coordinated I/O. Balance access with actual asynchronous reader lifetimes and handle permission changes.
- [Downloading an iCloud item](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)): request iCloud materialization when needed; availability must be confirmed before passing the URL to the decoder. Other File Providers may require their own coordinated-read behavior.
- [AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile) and [FLAC audio format](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac): starting points for file decoding, not a project compatibility certificate.
- [AVURLAsset content types](https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualcontenttypes): query runtime capability; verify each actual codec/container combination.
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession): use an appropriate playback category and background audio mode, activating when playback begins.
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) and [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter): publish current metadata and handle system playback commands.

## Delivery sequence and proof

| Step | Deliverable | Acceptance evidence |
| --- | --- | --- |
| 1. Product and design | Repository, Paseo workspace, this proposal, three exploration boards and the approved Noche/Papel pairing | Verify account/visibility/path/workspace; inspect all generated boards; record Noche as the default dark starting point and Papel as the iOS light appearance. |
| 2. Playback feasibility | Minimum iOS target and a decoder/provider/transition/EQ-compatibility experiment, plus an adaptive-mode feasibility decision | Open an external folder recursively; decode and seek real formats; restore access after relaunch; prepare cloud tracks; keep access through asynchronous reads. Prove gapless joins and adjustable overlap/headroom with the EQ path, background playback, route/format changes; inspect packaging/licenses. Assess adaptive analysis/stretching separately and record the outcome instead of assuming either support or impossibility. |
| 3. Initial folder player | Recursive folder-to-queue playback, gapless and optional crossfade, embedded metadata/artwork, and system/background controls | One folder selection plays root and nested tracks in natural order without reopening Files; cancellation/empty selection preserves the queue; test duplicate names, unsupported/corrupt tracks, large folders, cloud availability and permission/file changes. Verify joins/overlaps and rendered Noche UI/accessibility. |
| Conditional adaptive mode | AutoMix-style transitions for local files if feasibility passes; otherwise report the demonstrated limitation and feasible alternative | Verify beat/tempo estimates, mix timing and artifacts, unsuitable-pair behavior, original queue order, device performance, cloud/error behavior and EQ integration. A deferred or unproven mode remains explicitly unfinished. |
| 4. Multiband EQ | Bands, preamp, factory/custom presets, bypass and reset | Measure response and clipping/headroom; persist settings; check sample-rate/route changes, interruptions, preset switching and preservation of originals. |
| 5. Expanded player and collection | Rich album/artist browsing, playlists/favorites, lyrics, other listening tools, additional codecs and optional online services | Define each expansion before implementation; validate its offline/error behavior, compatibility, provider terms/costs, and performance. The larger collection is not a prerequisite for the first folder player. |

Server libraries such as SMB, WebDAV, Jellyfin, and Plex, Apple Music/Spotify integration, multi-device library sync, iPad/macOS/Watch apps, widgets, Siri/App Intents, and CarPlay are possible extensions. They are outside the agreed first source scope; CarPlay would also require its own entitlement and device validation. No service signup, paid API, analysis SDK, or license purchase is authorized. The initial audio dependencies have been resolved and locked for local implementation.
