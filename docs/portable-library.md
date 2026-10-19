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

Use **Exportar playlist** from a playlist or its options, choose M3U8 or M3U, and select the destination folder. Both outputs use UTF-8; M3U declares that encoding with `EXTENC`. Export uses relative paths and creates a numbered filename if the requested one exists. It never replaces an existing file or copies the music. Save the list beside the music to make the folder portable.

CUE intervals use VLC's `EXTVLCOPT:start-time` and `stop-time` comments. Sonora restores them against the matching CUE tracks. Other players may ignore those comments and play the entire image; plain M3U has no universal virtual-track boundary convention.

Text playlists are limited to 2 MB and M3U imports to 10,000 entries. Paths containing line breaks cannot be exported.

## Local copies

Choose **Importar carpeta** in **Biblioteca → Copias locales**. Sonora copies supported audio, CUE, M3U/M3U8, LRC/TXT and JPEG/PNG sidecars recursively. Symbolic links and hidden items are skipped. Originals are preserved. Progress and cancellation cover the copy; leaving the screen or putting the app in the background requests cancellation.

Copying streams through fixed 1 MB buffers. Each original's size and modification fingerprint is checked around its coordinated read. A staging folder becomes a published copy only after all files and CUE references validate. Cancellation or an I/O failure before that point removes the staging files. A cancellation racing with the final directory move may leave an already completed, valid copy.

Completed copies live in Application Support, rather than an evictable cache, and have independent library sources labelled **Local**. Adding a copy does not merge or remove an existing source for the original folder. The existing **Olvidar carpeta** action removes a source's references without deleting its files. **Eliminar copia local** explicitly removes the selected Sonora copy and its references, with confirmation; the original folder is preserved. Resetting the library leaves these copies available in Copias locales.

Importing a cloud-only file requests provider materialization through coordinated I/O. A file visible in iCloud Drive is not necessarily downloaded. Live signed-in iCloud, other providers, low-storage behavior and interrupted downloads still need provider/device validation; simulator tests use local synthetic files. Opening **En mi iPhone** directly continues to require no copy.

## CarPlay

The CarPlay scene uses four native tabs: Biblioteca, Playlists, Favoritos and Cola. Library browsing includes albums, artists, source folders and songs; favorites include songs, albums and artists. Lists paginate in place within CarPlay's item and navigation limits. Song selection uses the same transport, queue, Now Playing metadata and system remote commands as the iPhone. Provider failures produce a native CarPlay alert.

Both scenes share one player and one paused restoration task, including a launch initiated by the car. Cached browsing appears before provider-backed queue restoration finishes. Disconnecting releases CarPlay observers and templates while preserving the phone's transport.

Apple requires approval of `com.apple.developer.carplay-audio` for the app's App ID before device activation. The explicit `com.tonyredondo.Sonora` App ID now has a **Sonora Development** profile for iTony, using the existing development certificate. It does not include the CarPlay entitlement while approval is pending. See [Apple's entitlement instructions](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements).

The project enables the entitlement for ad-hoc Simulator signing. Device builds select **Sonora Development** explicitly. After approval, regenerate and install that profile with CarPlay enabled, then build with `CODE_SIGN_ENTITLEMENTS=Sonora/CarPlay.entitlements` or add that setting to the device configuration. Simulator signing uses `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`; unsigned builds cannot prove CarPlay Home-screen availability.

Native template, transport, error and lifecycle tests complement head-unit validation. A real vehicle, locked-iPhone access, interruptions, Siri and route behavior require separate device checks, as described in [Apple's simulator guidance](https://developer.apple.com/documentation/carplay/using-the-carplay-simulator).

## Validation

On 2026-10-16, the signed iPhone 17 Simulator / iOS 27 run passed all 93 app/audio tests plus four UI tests, with no failures or skips. Source input hashes were unchanged throughout the run. The Core suite separately passed 23 tests. The installed app executable, debug library and Info.plist match the tested build, and its Simulator Mach-O contains the CarPlay entitlement in both embedded entitlement sections.

The new native cases cover exact CUE decoder ranges and rendered continuity, interval lyrics and ReplayGain, legacy queue/favorite/playlist migration, M3U order and round trips, atomic local-copy failures and cancellation, original preservation, and CarPlay templates, selection, pagination, alerts and reconnect observation. UI checks cover actual Files selection, local copying and CUE playback at maximum text size, both themes, paused restoration, playlist import/export, listening settings and a ReplayGain file-tag save. See the [native captures](screenshots/portable/README.md).

The external CarPlay Simulator screen remained black despite successful capture commands and the embedded entitlement. Visual head-unit integration remains unverified. Live iCloud materialization, real providers and physical-device CarPlay also remain outside this simulator proof.
