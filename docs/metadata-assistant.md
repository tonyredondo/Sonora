# Metadata assistant

Open **Editar información → Completar información** for an editable song. Search by title, artist and optionally album, or choose **Reconocer por el audio**. Choose the recording and the release edition, then review each proposed field, artwork and lyrics. **Solo completar campos vacíos** is enabled initially. Disable it to select replacements for existing information.

**Aplicar al editor** updates the unsaved form. The existing **Guardar → Guardar en archivo** action validates and writes the tags with file-conflict detection. Cancelling the editor leaves the original file unchanged. Read-only formats and virtual CUE songs retain their existing editing restrictions.

MusicBrainz supplies recording, artist, album, release date, genre and track/disc information. Track positions are proposed only when the selected recording occurs once in the edition. LRCLIB supplies plain or synchronized lyrics for the selected title, artist, album and the actual file duration. Cover Art Archive supplies that edition's artwork. Missing artwork or lyrics is reported independently; it does not discard the other proposals. A duration difference over three seconds is shown for review.

## Recovering confirmed edits

Saving a song or a batch also keeps a durable copy of the editor's tags, embedded artwork and lyrics, including LRC timing and AI attribution. The app sends these confirmed values to your configured Sonora server; it does not upload the audio for this feature. Each confirmation has an immutable ID, so two albums, editions or devices cannot silently overwrite each other's choices.

Open **Editar información → Recuperar información guardada**, choose a copy and review the fields and artwork. The default completes empty fields. Disable that option to choose replacements or restore an empty value. **Aplicar al editor** changes the draft; **Guardar → Guardar en archivo** still performs the original file-conflict check. Cancelling leaves the file unchanged.

The match is a versioned SHA-256 over all decoded samples at their original rate and channel layout, without tags, paths, resampling or downmixing. Renaming a file and editing tags retain its identity. Re-encoding, changing samples or using a decoder that produces different samples can prevent an exact match; there is no approximate automatic restore. Computing this identity reads the full file during save or recovery, without scanning the whole library.

Confirmed copies and the outgoing queue live in **Application Support/Sonora/ConfirmedMetadata**, outside the lookup cache. An offline save remains pending for its original server address. Sonora retries when the network returns, the app becomes active, another edit is saved or you tap **Enviar copias pendientes** in the assistant settings. A failed or unsupported server leaves the copy pending and reports the problem. Changing the server does not forward another address's pending data. Without a configured server, copies remain local. Keep the original server address to resume its queue.

Server copies use a separate permanent SQLite database, configured by `[metadata]`, in the platform application-data directory. There is no TTL or LRU eviction. The default 5 GiB budget rejects new copies when full and keeps existing ones. Back up this database independently of the provider cache. Clearing the app or server provider cache does not remove confirmed editions. A new device can recover copies by identifying the same audio, connecting to the same server and reviewing the saved edition. Read-only and CUE editing restrictions remain unchanged.

## Connection

In **Ajustes → Asistente de información**, enter the server URL and its access token, save, then check the connection. The token is stored in this app's Keychain item; it is not included in UserDefaults, cache entries, URLs or bundled source. A connection check calls the authenticated `/v1/status` endpoint and reports whether AcoustID has an application key.

The URL must use HTTPS, or HTTP on localhost, a `.local` hostname, a private IPv4 address or the Tailscale IPv4 range. The app has scoped local-network ATS allowances and requests local-network access when needed. Public HTTP and embedded URL credentials are rejected. The client does not follow redirects, so the configured bearer token cannot be sent to a redirected endpoint. `0.0.0.0` is a server bind address; use the Mac's reachable address in the app.

The [proxy configuration](../proxy/sonora-proxy.example.toml) separates two credentials:

- `[server].api_token`: the access token shared with Sonora; a non-loopback listener requires at least 24 characters.
- `[acoustid].client_key`: the application key obtained by [registering an application](https://acoustid.org/new-application). It stays on the server. It is different from AcoustID's personal fingerprint-submission key.

MusicBrainz, LRCLIB and Cover Art Archive lookups work without provider accounts or keys. No AcoustID key is fabricated. The app reports the missing configuration and keeps text search available.

## Offline behavior

**Modo desconectado** prevents assistant HTTP requests. Previously requested searches, recording details, editions, lyrics and artwork are stored on the iPhone and survive relaunch. A missing local entry is identified explicitly. While the lookup screen remains open, an unsuccessful offline search retries when the assistant returns online. Closing it cancels its work.

Local copies are labelled with their save date. Without the manual toggle, a network failure can also use a saved response with a warning. Authentication errors remain visible. The app cache holds at most 100 MB or 1,000 entries, evicting the least recently used entries. Its freshness caps are seven days for metadata, 30 days for identification/lyrics and 90 days for artwork. Offline mode can use older entries. **Borrar información guardada** clears only this cache, after confirmation.

Playback and manual metadata editing are independent of the proxy. Audio still needs to be present locally: an undownloaded iCloud file cannot play or be fingerprinted without downloading it first. Use Sonora's managed local-folder copies when preparing cloud music for offline use. The proxy's separate SQLite cache reduces provider traffic; it is not the iPhone's offline cache.

## Audio recognition

Chromaprint is pinned through ChromaSwift at revision `900b29aff4129541c19e5e2b91f9cd4068afd19d`. Sonora uses its C API, the existing file decoders and Apple's sample-rate converter, without the wrapper's AVFoundation-only decoder. The package excludes FFmpeg/avresample and uses Accelerate/vDSP.

The analysis reads at most the first 120 seconds, on a cancellable worker, using bounded PCM buffers. It sends the encoded fingerprint and full track duration to the proxy. It does not upload audio or write fingerprint tags. Files that are too short to produce a fingerprint report an error. Candidate recordings are fetched from MusicBrainz and still require explicit selection.

## Simulator verification

Use normal ad-hoc Simulator signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) for the Keychain tests. The native assistant UI scenario uses only the marked synthetic Sonora QA folder and this localhost fixture:

```sh
python3 scripts/metadata-fixture-server.py --log /tmp/sonora-metadata-fixture.jsonl
```

After installing Sonora and seeding/selecting the demo folder, run `SonoraUITests/MetadataAssistantUITests` on that simulator. The fixture's fixed token is test data. It never contacts external providers. The scenario checks connection, recording/edition choice, review before file writes, persistent offline reuse, both themes and explicit lyric/tag saving. Stop the fixture after the test and restore the app's intended server connection.

Real AcoustID identification requires the registered application key. Minimum-iOS runtime, live iCloud, and physical-device energy/network-route behavior need their own device validation.

The 2026-10-16 Simulator run on iPhone 17 / iOS 27 passed all 98 app/audio tests and both assistant UI scenarios, with no failures or skips. The Core suite passed 31 tests; the proxy passed 35 Rust tests plus formatting and Clippy. Fingerprint tests compare independent AVFoundation decoding, verify the 120-second sampling cap with a 125-second file, and cover cancellation, short audio, path escape and unchanged source bytes. The UI run checks actual file saving, cancelling unsaved proposals, offline reuse after relaunch, both appearances and visible authentication failures.


## Find, synchronize or transcribe lyrics

Open **Letra → Sincronizar letra** for untimed lyrics, **Letra → Buscar o transcribir letra** when none exist, or the corresponding action in **Editar información**. Sonora follows three steps:

1. Look up LRCLIB, accepting complete ordered timestamps only when duration and any existing text match. A timed catalog hit needs no audio upload.
2. If text is available in the file/sidecar or LRCLIB, align it with ElevenLabs.
3. If neither source supplies text, transcribe the audio with ElevenLabs Scribe v2 and build line-level LRC from its word timestamps.

LRC information headers such as `[ar:…]` and `[ti:…]` do not count as lyric text. They are omitted from alignment input; files containing only headers follow the missing-lyrics flow. Verse spacing is retained.

The paid steps prepare mono 16 kHz PCM in memory using Sonora's existing playback decoders. Starting the action can consume the configured ElevenLabs account's credits; playback never starts analysis automatically. A catalog network failure can reuse an exact analysis already cached on the iPhone, with a warning; it never authorizes a new paid request. Authentication errors remain visible. Failed alignment does not trigger a second paid transcription.

The proxy administrator supplies `[elevenlabs].api_key` in the existing TOML configuration. The provider key stays on the server. Configuration must be loaded by the new binary before the new transcription route is available; editing repository files alone does not update a running proxy.

The preview identifies LRCLIB, ElevenLabs alignment or ElevenLabs Scribe v2. Transcription is labelled **Transcrita por IA · ElevenLabs** in preview, artwork and the full reader. The LRC provenance header is saved in the file and survives offline playback and relaunch; it is hidden from sung lines. AI can mishear singing: review the editable text and timing. **Usar esta letra** adds synchronized LRC to the editor's draft, where times and text remain editable. **Guardar → Guardar en archivo** performs the existing transactional original-file write. Cancelling a preview or draft leaves the original unchanged. Supported editable formats remain those of the metadata editor; shared CUE tracks remain read-only.

Every fallback has persistent cache on both the proxy and iPhone: LRCLIB timed/plain results and brief not-found results; alignments keyed by exact PCM and text; transcriptions keyed by exact PCM, endpoint and model/version. Server transcription keys include timing/event/diarization options and line-grouping version. Metadata renames do not invalidate the audio transcription. A valid no-voice result is cached and reported explicitly, avoiding another paid request. Transient failures are not treated as catalog misses or successful analyses. App catalog misses last five minutes online; offline mode can reuse older catalog entries. Derived analysis on the iPhone remains until cleared/evicted; server analysis retention defaults to one year, subject to its shared LRU/size budget. **Modo desconectado** can reuse a retained analysis after relaunch; a cache miss reports that it needs a connection. Cache eviction/clearing can require analysis again. Audio is prepared only after the catalog step, cancellation checks protect local work, and source changes invalidate the upload/save target. Already-started paid server work finishes caching if the phone disconnects. A timeout is not proof that the provider did not charge; the proxy does not automatically repeat paid requests.

Audio analysis uploads are limited to songs of up to ten minutes and 65,536 UTF-8 bytes of lyrics. The proxy rejects malformed audio, mismatched text and invalid timestamps. Music-specific timing quality requires live provider validation and user review.

The local integration fixture is `scripts/lyrics-synchronization-fixture.py` on loopback port 18092. Point a separate test proxy's LRCLIB and ElevenLabs base URLs at that fixture and listen on 18093 with the synthetic credentials from `scripts/seed-lyrics-synchronization-simulator.py`. Seed only the designated simulator, then run `LyricsSynchronizationUITests`. The fixture never contacts external providers. It exercises catalog-only lookup, alignment and missing-text transcription through real FLAC decoding and the Rust proxy, preview/cancel, original-file save, offline cache reuse, persistent AI attribution and both themes. The transcription fixture includes a Unicode paragraph break to verify complete LRC generation. These fixtures validate the integration without paid calls; real singing transcription accuracy remains unverified. Stop both test servers after validation; their synthetic configuration is separate from the installed proxy.
