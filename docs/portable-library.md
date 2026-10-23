# CUE, playlists, local copies and CarPlay

Sonora still opens folders directly through Files. Local copying is an explicit option in **Biblioteca → Copias locales**.

## CUE albums and concerts

Put the `.cue` beside its audio, or use relative paths inside the folder selected in Files. Opening that folder creates separate queue and library songs using the CUE titles, performers, album and `INDEX 01` boundaries. The audio image is represented by those songs rather than a second full-length entry. Multi-file CUE sheets retain their track order.

Playback and seeking use positions relative to each virtual song. Consecutive boundaries map to the same PCM frame, preserving continuity in Continua mode. Timed lyrics from the shared audio file are sliced and shifted to the selected song. Artwork still comes from the audio or folder sidecar.

The parser accepts UTF-8, BOM-marked UTF-16 and Windows-1252. CUE time is measured in 75 CD frames per second. Stored `INDEX 00` pregaps remain attached to the preceding song until the next `INDEX 01`; audio before the first `INDEX 01` is not a separate hidden track. Synthetic nonzero `PREGAP`/`POSTGAP`, data tracks, overlapping or out-of-order indexes, missing audio and competing sheets for the same image produce an explicit error. The referenced decoder must support seeking, and every interval must fit inside its audio file.

When an older saved queue contains the whole audio image, reopening its folder expands that entry into the CUE songs. Sonora restores the song containing the saved position, with a position relative to that song, and keeps playback paused. Existing favorites and playlist references expand to the new songs; a history event for the whole image is associated with its first song.

Virtual-song metadata is read from the CUE. The tag editor is read-only for these entries because all songs share the physical audio file. ReplayGain analysis measures each interval and stores its result in Sonora; virtual-song results cannot overwrite shared file tags. Ordinary audio-file editing remains available.

## M3U and M3U8

Open **Biblioteca → Playlists → Importar playlist**, choose a file, then authorize the folder containing its music. This creates a normal Sonora playlist. Relative paths resolve from the playlist's location; parent components are accepted only when the resolved audio remains inside the authorized music folder. Local `file:` URIs are accepted; Internet streams and HLS are outside this file-player flow.

The import report lists missing files, paths outside the selected folder, unsupported streams and repeated references. As with existing Sonora playlists, a song appears once, at its first position. A list with no valid songs leaves the library unchanged.

Use **Exportar playlist** from a playlist or its options. **Canciones y lista** creates a new folder in the destination chosen in Files, containing numbered songs in playlist order and a UTF-8 M3U8 with relative paths. Moving that whole folder keeps the playlist playable. An existing folder is preserved and a numbered suffix is used for the new export.

Choose **Originales** to copy the audio without recompression, or **MP3 · 320 kb/s** to convert other formats locally at a constant 320 kb/s. Existing whole MP3 files keep their encoded audio. MP3 conversion accepts mono or stereo; multichannel audio produces an explicit error. Sample rates other than 32, 44.1 or 48 kHz are converted to 44.1 kHz. CUE selections become independent WAV files in Originales (uncompressed Float64 PCM preserving source precision), or independent MP3 files, rather than copies of the complete album image. CUE WAV exports are limited to 4 GB per file and channel layouts representable by WAVE extensible.

Exports preserve supported file tags, artwork and effective embedded/sidecar lyrics. Timed lyrics are also written as LRC sidecars; CUE timestamps are shifted to the exported interval. ID3 exports retain additional text tags as TXXX frames. Raw AAC/CAF originals keep external artwork as `<song>.cover.jpg` or `.png`, which Sonora recognizes per song.

MP3 exports also embed all completed «Sobre la canción» and «Sobre el álbum» readings in the supported languages (es, en, fr, de, it and pt), including results restored from disk caches. Each language has its own ID3 TXXX field, for example `SONORA_SONG_ABOUT:es` and `SONORA_ALBUM_ABOUT:en`. These contain UTF-8 JSON values with schema version 1, language, model/effort provenance and the explanation. Export merges matching readings already embedded in the source with completed cached readings, replacing only the corresponding language; it never generates missing languages. The field suffix must match the payload language. Sonora also reads the previous unsuffixed `SONORA_SONG_ABOUT` and `SONORA_ALBUM_ABOUT` fields, preferring a valid language-specific field when both exist.

Song records bind to title, artist, album and the untimed lyric digest; album records bind to album title/artist and retain the original lyric coverage counts without including the other songs’ lyrics. Sonora restores valid matching records from imported or reopened MP3 files without a server or new Codex requests. Malformed, oversized, unsupported-version and mismatched records are ignored; ordinary playback/import still works. Explicit analysis refresh bypasses embedded readings and the next export uses the updated result. Other players may not display these custom fields.

Other analysis caches and app settings remain in Sonora. Source files are never edited. Progress and cancellation cover copying and conversion; a failure before publication removes the private staging folder. Cancellation racing with the final directory move returns the completed export.

**Solo lista M3U** retains the references-only export. Choose M3U8 or M3U and select its destination folder. Both outputs use UTF-8; M3U declares that encoding with `EXTENC`. This mode copies no audio and creates a numbered filename if the requested one exists. Save the list beside the music to make its relative paths portable.

CUE intervals use VLC's `EXTVLCOPT:start-time` and `stop-time` comments. Sonora restores them against the matching CUE tracks. Other players may ignore those comments and play the entire image; plain M3U has no universal virtual-track boundary convention.

Text playlists are limited to 2 MB and M3U imports to 10,000 entries. Paths containing line breaks cannot be exported.

## Local copies

Choose **Importar carpeta** in **Biblioteca → Copias locales**. Sonora copies supported audio, CUE, M3U/M3U8, LRC/TXT and JPEG/PNG sidecars recursively. Symbolic links and hidden items are skipped. Originals are preserved. Progress and cancellation cover the copy; leaving the screen or putting the app in the background requests cancellation.

Copying streams through fixed 1 MB buffers. Each original's size and modification fingerprint is checked around its coordinated read. A staging folder becomes a published copy only after all files and CUE references validate. Cancellation or an I/O failure before that point removes the staging files. A cancellation racing with the final directory move may leave an already completed, valid copy.

Completed copies live in Application Support, rather than an evictable cache, and have independent library sources labelled **Local**. Adding a copy does not merge or remove an existing source for the original folder. The existing **Olvidar carpeta** action removes a source's references without deleting its files. **Eliminar copia local** explicitly removes the selected Sonora copy and its references, with confirmation; the original folder is preserved. Resetting the library leaves these copies available in Copias locales.

Importing a cloud-only file requests provider materialization through coordinated I/O. A file visible in iCloud Drive is not necessarily downloaded. Live signed-in iCloud, other providers, low-storage behavior and interrupted downloads still need provider/device validation; simulator tests use local synthetic files. Opening **En mi iPhone** directly continues to require no copy.

## CarPlay

The CarPlay scene uses four native tabs: Biblioteca, Listas, Favoritos and Cola. Library browsing includes album artwork, artists, source folders, songs and recent listening. Native search is available on iOS 27 and later; earlier versions do not permit the search template for audio apps ([template availability](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)). Favorites include songs, albums and artists. Lists paginate in place within CarPlay's item and navigation limits. Collections support playing in order, shuffling, playing next and adding to the queue. Open lists reflect library and queue changes made on the iPhone. Provider failures produce a native CarPlay alert.

Now Playing has five additional controls: favorite, shuffle, repeat, playback speed and Audio. Shuffle and repeat use the system's native button states; speed cycles through 0.5×–2×. Album/artist and queue shortcuts open native lists. Audio offers speed selection, independent pitch adjustment in semitone steps (−12 to +12), EQ presets, transitions, volume normalization, balance and a sleep timer. Changing these settings preserves a paused song and uses the same settings and audio engine as the iPhone.

Audio also shows the cached BPM and named markers; selecting a marker seeks to its time. These screens reuse the existing analysis and do not launch AI requests. Lyrics, translations, interpretation text and a custom waveform remain on the iPhone: standard CarPlay audio templates do not provide a custom scrolling lyrics or waveform surface.

Both scenes share one player and one paused restoration task, including a launch initiated by the car. Cached browsing appears before provider-backed queue restoration finishes. Disconnecting releases CarPlay observers and templates while preserving the phone's transport.

Apple approved `com.apple.developer.carplay-audio` for the `com.tonyredondo.Sonora` App ID. The **Sonora Development** profile regenerated on 2026-10-20 includes that entitlement and iTony, using the existing development certificate. Install the regenerated profile rather than the earlier profile without CarPlay. See [Apple's entitlement instructions](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements).

The project enables `Sonora/CarPlay.entitlements` for both device and Simulator builds. Device builds select **Sonora Development** explicitly. Simulator signing uses `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`; unsigned builds cannot prove CarPlay Home-screen availability. Successful device signing confirms the provisioning prerequisite, but connection, browsing and playback still need validation on a real CarPlay display.

Native template, transport, error and lifecycle tests complement head-unit validation. A real vehicle, locked-iPhone access, interruptions, Siri and route behavior require separate device checks, as described in [Apple's simulator guidance](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator).

## Validation

On 2026-10-16, the signed iPhone 17 Simulator / iOS 27 run passed all 93 app/audio tests plus four UI tests, with no failures or skips. Source input hashes were unchanged throughout the run. The Core suite separately passed 23 tests. The installed app executable, debug library and Info.plist match the tested build, and its Simulator Mach-O contains the CarPlay entitlement in both embedded entitlement sections.

The new native cases cover exact CUE decoder ranges and rendered continuity, interval lyrics and ReplayGain, legacy queue/favorite/playlist migration, M3U order and round trips, atomic local-copy failures and cancellation, original preservation, and CarPlay templates, selection, pagination, alerts and reconnect observation. UI checks cover actual Files selection, local copying and CUE playback at maximum text size, both themes, paused restoration, playlist import/export, listening settings and a ReplayGain file-tag save. See the [native captures](screenshots/portable/README.md).

The external CarPlay Simulator screen remained black despite successful capture commands and the embedded entitlement. Visual head-unit integration remains unverified. Live iCloud materialization, real providers and physical-device CarPlay also remain outside this simulator proof.
