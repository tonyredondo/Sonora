# Library, metadata and listening

The expanded local build keeps Noche and Papel and the fixed Now Playing layout. Audio stays in the folders selected through Files. Library entries, playlists and queue items are references to those files. [View the native screens](screenshots/library/README.md).

## Library and queue

Open **Biblioteca** from the folder screen to browse songs, albums, artists and local discographies. Search matches titles, artists, albums and other indexed tags, including accents and case variants. Mark songs, albums or artists as favorites. Song options create playlists or add songs to an existing one; playlists can be renamed, reordered and deleted. History records the last 500 distinct played songs and can be cleared.

Use **Seleccionar** in a song list for ordered multi-selection, playlist actions, queueing or batch metadata editing. **Reproducir a continuación** inserts after the current song; **Añadir al final de la cola** appends. The queue also accepts another recursive folder without replacing the current song. Identical filenames in different sources have distinct identities. Relaunch restores available source references and position, paused.

Adding a folder indexes locally available metadata without downloading every cloud-only song. Playing a cloud song requests provider readiness. Forgetting a folder removes its references from the library, playlists and queue; it does not delete audio. Reopen a folder if access has expired or its files have moved.

## Edit the original file

Open **Editar información** from song options in the player, queue or library. The editor supports title, artist, album, album artist, composer, genre, date/year, track/disc numbers and totals, comments, lyrics and cover art. The editor keeps its target fixed while playback changes songs.

For several songs, activate only the fields to apply to every selected file. Mixed fields are identified; an enabled empty field clears that tag. Cover art can be replaced or removed. **Guardar** presents the original-file destination before writing. The result reports successful writes and individual failures.

Each save checks the original size, modification time and file identity, copies that file to a temporary sibling, updates its tags, and reads the requested fields and artwork back. A verified staged result replaces the original under file coordination. Invalid input, unsupported writes and external-change conflicts leave the original untouched. An unsuccessful file does not count as saved. There is no automatic backup copy; keep a separate backup for edits you may want to undo.

Tag writing does not encode the audio again. Synthetic round-trip tests compare the complete decoded PCM hashes before and after edits, including removal of lyrics/artwork and preservation of unedited fields. TagLib's year-only ID3 date handling is supplemented by a small native bridge using the same pinned dependency.

| Tested file/container | Decode, seek and complete EOF | Edit tags, cover and lyrics |
| --- | --- | --- |
| MP3 | Yes | Yes |
| FLAC | Yes | Yes |
| WAV/PCM | Yes | Yes, ID3 tags |
| AIFF/PCM | Yes | Yes, ID3 tags |
| AAC in M4A | Yes | Yes |
| ALAC in M4A | Yes | Yes |
| Ogg/Vorbis | Yes | Yes |
| Ogg/Opus | Yes | Yes |
| WavPack | Yes | Yes |
| TTA | Yes | Read-only in this editor |
| CAF/PCM | Yes | Technical information only; read-only |
| AAC/ADTS | Yes | Technical information only; read-only |

These are fixture-backed combinations on iOS 27 Simulator, not a claim about every possible stream/container variant. Other extensions recognized by the pinned decoder, including APE and Musepack, have not received equivalent fixture validation. WMA and DSD are outside this delivery. CUE support and its shared-file editing limits are described in the [portable-library guide](portable-library.md).

## Lyrics

The lyric reader prefers timestamped embedded text, then a matching `.lrc` sidecar, then embedded plain text or a `.txt` sidecar. It handles Unicode, multiple timestamps per line and file offsets. Timed lines highlight with playback and seek when tapped. A per-song offset and an automatic-scroll toggle are remembered. Plain lyrics remain readable without seeking controls.

The information editor edits the embedded lyric text and can load an LRC/TXT file. No online lyric or metadata service is contacted. Unsupported binary lyric-frame variants are not advertised as synchronized-text support.

## Listening controls

**Ajustes → Escucha** offers ReplayGain by song or album, stereo balance and a sleep timer. Normalization uses fresh local measurements or the selected gain/peak tags before transitions and EQ. Without valid data for that mode, it preserves the original level. Album mode preserves relative album dynamics. Balance attenuates the opposite channel; centered balance and disabled normalization retain the existing source-format path. The [manual ReplayGain analyzer](replaygain-analysis.md) measures songs, albums and selections, reuses current results and can optionally write verified file tags. See the [native captures](screenshots/replaygain/README.md).

The timer can pause after 15, 30, 45, 60 or 90 minutes, or at the end of the current song. End-of-song mode discards buffered successors and preserves the entire ending, including when an overlap mode is selected. A manual song change cancels that end-of-song target. Pausing and changing listening settings preserve pause intent and position.

**Ajustes → Entre canciones** offers:

- **Continua**, the default for concerts: no overlap or intro skipping. Matching rates/layouts are required for the verified gapless path.
- **Crossfade**, an adjustable 1–12 second maximum overlap, bounded by half the shorter available track.
- **Mezcla automática (beta)**, a local steady-pulse analysis that aligns the entry and chooses an overlap with at least four beats and a bounded estimated drift. It may skip at most one second of the incoming intro. It changes neither tempo nor pitch. Uncertain, incompatible or short pairs use identified Crossfade; late preparation leaves the outgoing audio intact.

Automatic analysis reads at most two eight-second windows per track using fixed scratch buffers and a 500 ms processing budget. Synthetic steady-pulse analysis measured about 35–50 ms on the test simulator; actual PCM tests check coincident beats, absence of an offbeat incoming pulse, transfer of the consumed head, queue order and output through EQ. Silence/irregular inputs and unsuitable pair plans are rejected. This beta does not detect vocal phrases and is not Apple's AutoMix algorithm. Varied real-music listening, signed-in cloud readiness, physical routes and device energy use still need validation before a release.

## Validation scope

Tests operate on temporary generated signals and the marked **Sonora QA** simulator folder. They do not edit the owner's music. The project targets iOS 17+, while current runtime evidence uses iPhone 17 Simulator / iOS 27. Minimum-iOS runtime, signed-in iCloud providers and physical-device audio routes remain unverified for this expansion. 
