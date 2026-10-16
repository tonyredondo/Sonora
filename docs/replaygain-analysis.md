# Manual ReplayGain analysis

Sonora can measure the loudness of songs, whole albums, selections and recursive source-folder lists. Analysis is manual and local. It decodes each complete file once; it does not upload audio, rewrite audio samples or automatically add tags to the originals.

## Use

- Open a song's options and choose **Analizar volumen**. The same action is available in the player and queue.
- Open an album and choose **Analizar álbum completo** to obtain both individual song gains and a shared album gain.
- In a song list, use **Seleccionar**, select songs and choose **Analizar volumen**. The selected files are measured individually.
- Open a source folder under **Biblioteca → Carpetas** to analyze its indexed songs and subfolders. The queue and **Ajustes → Escucha** also offer analysis of the current queue.

Choose **Analizar** to measure missing or changed files and reuse current local results. **Volver a analizar todos** forces a new measurement. The screen shows progress within each file, the number analyzed/reused and individual failures. Cancelling a selection keeps completed measurements and discards the incomplete file; a new album measurement is published only after all its members finish successfully.

Activate **ReplayGain → Por canción** or **Por álbum** under **Ajustes → Escucha** to apply the results. A fresh local measurement takes precedence over the corresponding file tags. Otherwise, playback uses the file's existing tags, or its original level when those tags are absent. Album mode preserves relative levels between songs.

## Saving file tags

Local results work even when a format is read-only in the metadata editor. **Guardar etiquetas…** is a separate, explicitly confirmed action for compatible files. It writes the measured track gain and peak, and album gain/peak when the complete measured album is still valid. A song-only save preserves existing album tags and other metadata.

Saving uses the existing security-scoped, coordinated metadata transaction: copy to a unique sibling file, write tags, read back the requested gain/peak values, check the original fingerprint again and replace it. The original audio is not re-encoded. Conflicts and write failures are reported per file. Playback pause intent and position survive the transaction. Our own verified tag-only writes update local fingerprints so the completed analysis remains usable.

ReplayGain tag round trips cover MP3, WAV, FLAC, AIFF, AAC/M4A, ALAC/M4A, Ogg/Vorbis, Opus and WavPack. Tests compare the full decoded PCM hash and other tags, embedded lyrics and artwork before/after writing. CAF, raw AAC/ADTS and TTA retain their read-only metadata policy; their local analysis can still be used by Sonora.

## Calculation and cache

The analyzer uses the ITU BS.1770 gated loudness implementation already linked from SFBAudioEngine 0.14.0, with the revised ReplayGain reference of **−18 LUFS**. Gain is reference loudness minus measured loudness. Album loudness combines the members' gating-block power statistics; it is not an average of track gains in decibels. Peak is the maximum absolute decoded sample amplitude, as in the engine's existing ReplayGain analyzer. Playback limits gain using that peak before transitions and EQ.

A small Objective-C++ bridge exposes streaming measurement to Sonora's existing decoder paths, including its native reader for Apple containers. Fixed 8,192-frame buffers keep PCM memory independent of file duration. Cancellation is checked between reads, and progress updates are throttled. Album members are read sequentially and their small measurement statistics retained for the final combined result.

Results are stored in the local `volumeAnalysis` preferences archive using source-qualified song IDs. File size, modification time and file identity detect stale results. Before using a local album gain, the I/O worker verifies every member and checks that the current library's album membership still matches. Changes invalidate the local result; independently embedded ReplayGain tags remain file metadata. Forgetting a source removes its local analysis references. A corrupt archive is preserved until an explicit **Restablecer análisis** action.

The bridge uses unmodified declarations from the exact pinned engine revision, documented in [LoudnessHeaders/provenance.json](../Sonora/Library/LoudnessHeaders/provenance.json). Their declarations and class layout must match the engine implementation when updating that dependency. No second loudness implementation or decoder dependency is compiled. The Apache 2.0 notice is retained with the headers and in the bundled third-party notices.

## Limits and validation

BS.1770 integrated loudness needs at least one 400 ms gating block. Silence and audio below its absolute gate report an unavailable measurement rather than an arbitrary gain. Unknown multichannel layouts report an error rather than assigning guessed channel weights. Analysis requests an iCloud download when needed and is cancelled when its screen closes or the app enters the background; it is not an unattended background scanner.

Synthetic fixtures exercise all twelve current playback format/container paths. Integration tests cover known-level signals, album power aggregation, real normalized player output, paused restoration, cache reuse and invalidation, cancellation, corrupt files, read-only formats and tag-write conflicts. Native simulator tests cover the user-facing actions, explicit saving and relaunch, both appearances and the largest accessibility text size. These checks do not certify every codec variant, physical-device energy use or live iCloud/File Provider behavior.
