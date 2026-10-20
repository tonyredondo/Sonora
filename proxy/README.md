# Sonora proxy

A Rust service for MusicBrainz metadata, AcoustID identification, LRCLIB lyrics, Cover Art Archive artwork and opt-in ElevenLabs lyric alignment and transcription. It caches downloaded responses in SQLite and shares a separate request budget for each provider across all callers. Audio decoding, fingerprint generation, candidate selection and tag writes belong on the iPhone.

This directory provides the backend API used by Sonora's [metadata assistant](../docs/metadata-assistant.md). Ordinary metadata requests send tags or fingerprints. Explicit lyric analysis uploads a bounded PCM copy to ElevenLabs, with known lyrics for alignment; the proxy never edits music files.

## Build and configure

```sh
cargo build --release --locked --manifest-path proxy/Cargo.toml
mkdir -p ~/.config/sonora-proxy
cp proxy/sonora-proxy.example.toml ~/.config/sonora-proxy/config.toml
chmod 600 ~/.config/sonora-proxy/config.toml
proxy/target/release/sonora-proxy --check-config
proxy/target/release/sonora-proxy
```

Configuration discovery, in priority order:

1. The file supplied with `--config /absolute/path/config.toml`.
2. `~/.config/sonora-proxy/config.toml`.
3. `sonora-proxy.toml` beside the executable.

Only one file is loaded; credentials from separate files are never merged. A missing explicit file or an invalid discovered file stops startup. Relative cache paths are resolved against the TOML directory. `~/` paths are expanded. Settings are loaded at startup; restart after changing them. `--check-config` validates without opening the cache, starting a listener or contacting providers.

See [the complete example](sonora-proxy.example.toml). Credentials are plaintext as requested. Configuration values and provider request URLs/bodies are excluded from logs and parse errors. MusicBrainz, LRCLIB and Cover Art Archive public lookups do not require credentials. AcoustID identification needs your own application `client_key` in `[acoustid]`; registering/submitting fingerprints is outside this API. Paid alignment and Scribe v2 transcription require your ElevenLabs `api_key` in `[elevenlabs]`. `/v1/status` reports whether each provider is configured without returning its key.

The default listener is `127.0.0.1:8089`. If `[server].api_token` is set, every `/v1/` call requires `Authorization: Bearer <token>`. Binding to another interface requires a token of at least 24 characters. `/health` is public and returns only status/version. Use the host's reachable address in Sonora, not `0.0.0.0`. Public deployments need an HTTPS endpoint; the app also permits HTTP on private/local or Tailscale addresses. This binary serves HTTP and does not install a service or change network settings.

## Confirmed metadata archive

`[metadata].path` stores immutable copies of user-confirmed editor values in a separate SQLite database. It defaults to the platform application-data directory (`~/Library/Application Support/sonora-proxy/metadata.sqlite` on macOS), not the cache directory. Omitted settings keep existing configurations valid. Relative paths resolve against the configuration file. Back up this database as personal data; cache clearing and provider TTL/LRU eviction do not apply to it.

All routes use the existing bearer authentication and do not call providers:

| Method | Route | Result |
| --- | --- | --- |
| PUT | `/v1/metadata-records/{uuid}` | Confirm an immutable copy; 201 when created, 200 for an identical retry, 409 if that ID already has different content. |
| GET | `/v1/metadata-records/{uuid}` | Full copy, or `metadata_not_found` with HTTP 404. |
| GET | `/v1/audio/{audio_id}/metadata?before={cursor}` | Up to 50 summaries and `next_cursor`; omit `before` for the first page. |

A record contains `id`, `audio_id` (`pcm64-v1:` and a lowercase SHA-256 digest), `confirmed_at` (Unix milliseconds), `values` (the editor's field names and strings) and nullable base64 `artwork`. No filesystem path, audio or credentials are part of a record. Limits match the editor: 16,384 UTF-8 bytes per tag, 1,000,000 for lyrics and 10,000,000 decoded artwork bytes. Requests are capped at 22 MB to allow JSON escaping and base64. `[metadata].max_bytes` defaults to 5 GiB; HTTP 507 rejects additional data without evicting any confirmed copy. `/v1/status` adds `metadata_archive_version: 1`; existing provider routes and response envelopes are unchanged.

## Cache and scheduling

Provider JSON, plain/timed lyrics and actual artwork bytes share one persistent SQLite cache. Secrets are not cache keys or cached headers. Cache keys include the upstream endpoint and lookup arguments, so changing an administrator-configured mirror does not reuse another endpoint's answers.

Default freshness caps are seven days for MusicBrainz, 30 days for AcoustID/LRCLIB and 90 days for artwork. Origin freshness can shorten these caps. Expired entries retain ETag/Last-Modified validators for conditional requests; a 304 refreshes freshness while retaining the body. Nothing polls providers in the background. Responses marked `no-store`, `private`, or an unsupported `Vary` are not retained. `no-cache` requires validation on every reuse. A 404 is cached briefly (five minutes by default); authentication, throttling, server errors, oversized data and malformed responses are not successful cache entries.

The default payload budget is 512 MiB and 10,000 entries. Least recently used entries are evicted as needed; SQLite page/index metadata adds overhead. Freed pages are reclaimed after writes. The database has an ownership lock: two processes cannot use the same cache file simultaneously.

Identical in-flight requests share one provider operation, including retries. Each provider has a bounded queue (128 unique active/queued lookups by default). Interactive requests take priority, with a background turn after at most three interactive turns while both queues contain work. Cancelling one consumer preserves work needed by another; cancelling the last consumer drops queued work or the active HTTP future for ordinary lookups. Paid audio analysis keeps an already-started operation alive to cache its result, and reconnecting callers share that flight. Cache hits bypass the queue and rate budget.

MusicBrainz starts are spaced by at least 1.1 seconds by default, AcoustID by 350 ms, and artwork by one second. LRCLIB runs sequentially with a 500 ms delay after a completed response. Configuration rejects MusicBrainz intervals below one second and AcoustID intervals below 334 ms. A provider's retries and redirects consume the same budget. Throttling and server failures apply a shared cooldown, honor `Retry-After` and use bounded backoff with jitter when no delay is supplied. Defaults allow two retries, a 15-second HTTP timeout and a 60-second total lookup deadline, including queue time.

Run **one proxy instance per upstream budget/egress IP**. Separate processes or other applications on the same IP can still exceed MusicBrainz's shared limit. Replication would require a shared scheduler; an independent limiter in each replica is insufficient. Jobs, priorities and cooldowns are in memory; completed cache entries survive restarts.

## Lyric synchronization and transcription

Sonora first requests an exact LRCLIB result using the song's tags and duration. It accepts complete, ordered timestamps only when they fit the audio and match the existing lyrics, preserving that text. A catalog outage or authentication error is reported without silently starting a paid operation. Missing metadata cannot identify a catalog edition; available lyrics can still be aligned explicitly, or missing lyrics transcribed. When LRCLIB returns only plain lyrics and the file has no text, that catalog text becomes the alignment input. Transcription is the third fallback, used only when neither source supplies text; failed alignment does not silently switch to transcription.

`POST /v1/lyrics/align` is the explicit paid fallback. It accepts one `file` and one `text` part: mono, 16 kHz, signed PCM16 little-endian WAV with the canonical 44-byte header, 1–600 seconds (19,200,044 bytes maximum), and at most 65,536 UTF-8 bytes of known lyrics. The app uses its playback decoders to prepare this representation, supporting its existing audio formats. The server checks WAV structure and actual duration before contacting ElevenLabs. Only the configured provider endpoint is reachable; clients cannot supply URLs or local paths.

`POST /v1/lyrics/transcribe` accepts the same canonical WAV as one `file` part, without a `text` part. It calls `/v1/speech-to-text` with `model_id=scribe_v2`, word timestamps, audio event tags disabled and diarization disabled. The proxy validates the complete transcript and word times before grouping phrases by sentence punctuation, pauses or target line length/time. Original Unicode and word spacing are retained, including languages without spaces between words. Unicode paragraph breaks delimit phrases; a break inside a single provider word becomes a space so it cannot create an untimed line. Literal LRC timestamp/offset controls are rejected before caching. The iPhone also rejects inconsistent plain/timed pairs and timing outside the actual audio, including global LRC offsets. Returned fields are `plain_lyrics`, `synced_lyrics`, `audio_sha256`, `duration`, `model_id` and optional `language_code`.

The shared ElevenLabs queue admits at most four unique active/queued operations and has one worker with a one-second default start interval. Four upload permits bound buffered request bodies. Requests have a 120-second upstream timeout and 180-second total caller deadline. Paid POSTs are never automatically retried, including on timeouts, 429 or 5xx responses, and redirects are rejected. A failed/ambiguous operation may have consumed credits; retry deliberately. Process shutdown cannot recover an upstream operation whose result was not cached. The 65,536-byte transcript limit also applies after phrase grouping, so added line separators cannot produce a cached result that exceeds the iPhone's limit.

Completed alignments are checked against the entire transcript, preserving Unicode, punctuation, line order and repeated verses; non-finite, backwards, incomplete, mismatched or out-of-range timing is rejected. Derived results, rather than source audio, are cached in SQLite for up to one year by default, subject to the shared size/LRU limits. Keys include canonical audio and exact text SHA-256 plus the alignment version and endpoint; API keys are excluded. These derived records use their configured retention instead of upstream HTTP freshness. Transcription cache identities additionally include the model, word timing/event/diarization options and line-grouping version. A valid empty/no-voice transcript is cached too; malformed or incomplete results are rejected. Audio uploads stay in bounded memory and are not persisted by the proxy. ElevenLabs processes the submitted audio/text under its own terms.

Paid-provider errors, including HTTP 404, are not cached as audio analyses. Older negative audio-cache records are ignored on lookup so an explicit retry can recover after the provider is fixed; the proxy still never retries paid requests automatically. Catalog not-found responses keep their normal short cache lifetime.

The app shows the provider and a preview before adding LRC to the metadata editor's draft. Its existing original-file save confirmation remains required. Transcribed LRC includes `[by:Sonora AI transcription - ElevenLabs]`; Sonora displays **Transcrita por IA · ElevenLabs** in the preview, artwork and full reader, including after tag save, relaunch and offline. Successful analysis is retained in the iPhone cache for offline reuse until cleared or evicted. Singing accuracy still needs evaluation against real music; this integration validates structure and correspondence, not musical alignment quality.

## API

All JSON provider responses use an envelope with `provider`, `sources` (upstream request URLs), `cache`, `fetched_at` (Unix seconds) and `data`. Cache status is `hit`, `miss`, `shared` or `revalidated`; combined fingerprint candidates use `mixed` when their requests had different cache states and report the oldest component timestamp. Artwork returns image bytes and `X-Sonora-Cache`. HTTP responses to clients are `Cache-Control: no-store`; persistent caching is handled inside the proxy.

| Method | Path | Input / result |
| --- | --- | --- |
| GET | `/health` | Status and binary version |
| GET | `/v1/status` | Authenticated provider availability; credentials are never returned |
| GET | `/v1/recordings` | `title`, optional `artist`, `album`, `duration`; up to 20 recording candidates and their release editions |
| GET | `/v1/recordings/{mbid}` | Recording details, credits, genres and release choices |
| GET | `/v1/releases/{mbid}` | Full MusicBrainz release JSON, including media/discs, track positions, dates and credits |
| GET | `/v1/lyrics` | Required `title`, `artist`, `album`, `duration` in seconds; LRCLIB's exact-signature result, including `plainLyrics`, `syncedLyrics`, `instrumental` |
| POST | `/v1/lyrics/align` | Multipart `file` (canonical WAV) and UTF-8 `text`; returns validated synchronized LRC and audio/text SHA-256 digests |
| POST | `/v1/lyrics/transcribe` | Multipart `file` (canonical WAV); returns validated Scribe v2 text, line-level LRC and audio SHA-256; valid no-voice results contain empty text |
| POST | `/v1/lyrics/translate` | JSON `lines` (`id`, `text`), `source_language` and `target_language`; full-context Codex translation with one result per source ID |
| POST | `/v1/lyrics/interpret` | JSON `lyrics`, `language` and optional song `context`; cached literary interpretation via the host user's Codex session, GPT-6-Astra at `xhigh` |
| POST | `/v1/identify` | JSON `fingerprint` and `duration`; AcoustID recording IDs and scores |
| GET | `/v1/artwork/{release_mbid}` | Front artwork at the provider's 500-pixel variant; downloaded only when requested |
| POST | `/v1/jobs` | Create a bounded batch; returns 202 and a `Location` to poll |
| GET | `/v1/jobs/{id}` | State, total, completed count, individual results and provider warnings |
| DELETE | `/v1/jobs/{id}` | Cancel unfinished work; the final snapshot remains available until expiry/eviction |

Search text is escaped before forming MusicBrainz's query. IDs must be canonical UUIDs. Clients cannot supply arbitrary upstream URLs. Cover artwork redirects are limited to the configured origin and HTTPS Cover Art Archive/Internet Archive hosts; every hop is paced. Request JSON is limited to 256 KiB and downloaded bodies to 10 MB by default. The proxy preserves the returned bytes/MIME type and does not decode artwork.

Example batch:

```sh
curl --fail-with-body http://127.0.0.1:8089/v1/jobs \
  -H 'Content-Type: application/json' \
  --data '{"priority":"background","tracks":[{"title":"One More Time","artist":"Daft Punk","album":"Discovery","duration":320,"lyrics":true}]}'
```

Tracks can provide a locally generated encoded Chromaprint `fingerprint` plus `duration` when tags are missing. Identification retrieves up to three distinct MusicBrainz recording candidates; tag search is also available when identification yields no usable candidate. Scores are provider relevance, not automatic approval. Artwork paths identify release editions; request an image after choosing an edition rather than downloading covers for every search result.

Metadata and lyrics fail independently. A completed job means every track was processed; inspect each result's warnings and candidate list. Missing or incomplete lyrics signatures do not cause the proxy to guess another version. No result is automatically written into a file.

Job states are `queued`, `running`, `completed`, `cancelled` and `failed`. At most four batches execute at once. Defaults retain up to 64 jobs for one hour and accept up to 100 tracks per batch. Older terminal jobs can be evicted when new jobs arrive; active jobs are never evicted to admit new work. Results are bounded to 4 MB per job. A job exceeding that limit fails with an explicit error and keeps its earlier results. Submit smaller batches to continue. Jobs do not resume after a proxy restart; resubmitting a batch reuses its still-fresh cached provider responses.

Errors use JSON `error` and `message`: invalid input is 400, oversized audio uploads are 413, no provider result is 404, full queues are 429 with a retry hint, deadlines are 504, unavailable configuration/cache/providers are 503 and other upstream failures are 502. Transport success does not guarantee a matching recording, available lyrics or a cover.

## Error diagnostics

Every response includes `X-Sonora-Request-ID`. A valid client UUID is echoed; missing or malformed references receive a new UUID. Errors retain the existing `error` and `message` fields and add nullable `provider`/`upstream_status` and a symbolic `reason`. Older clients can ignore these additions. Transport failures distinguish connection, timeout, body and decoding errors; known provider codes such as `quota_exceeded` are preserved.

Failed requests are logged to standard output with their reference, method, route template, HTTP status and elapsed milliseconds. Provider failures and payload-validation stages use the same request span, including paid work that finishes after a caller disconnects. The launcher controls log retention; the existing macOS launch agent collects this output in `~/Library/Logs/SonoraProxy/stdout.log`.

Background metadata jobs retain the reference of the request that created them, so provider failures can be traced after the initial response has returned.

Logs exclude credentials, query strings, music tags, audio and lyrics. Provider error bodies are bounded and inspected only for allowlisted symbolic codes; their raw messages are discarded. The cache identity and paid retry policy remain unchanged.

## Verify

```sh
cargo test --locked --manifest-path proxy/Cargo.toml
cargo fmt --manifest-path proxy/Cargo.toml --check
cargo clippy --locked --manifest-path proxy/Cargo.toml --all-targets -- -D warnings
```

Integration tests run real HTTP clients against local synthetic provider servers and actual temporary SQLite files. They exercise restart reuse, conditional validation, deduplication, per-provider pacing, retries, cancellation, queue/memory bounds, authentication, partial batch results and artwork redirects. They do not need real keys, send personal music metadata, or consume production provider quotas. AcoustID's live authenticated lookup still needs a user-supplied registered client key. See the [iPhone assistant guide](../docs/metadata-assistant.md) for client and offline behavior.

A separate ignored test, `approved_synthetic_elevenlabs_alignment` in `tests/live_alignment.rs`, can verify the real service after explicit approval. It accepts only a synthetic canonical WAV of up to ten seconds and a short known transcript. Supply the exact key, WAV, text and result paths through `SONORA_LIVE_ALIGNMENT_KEY_FILE`, `SONORA_LIVE_ALIGNMENT_WAV`, `SONORA_LIVE_ALIGNMENT_TEXT` and `SONORA_LIVE_ALIGNMENT_OUTPUT`, plus `SONORA_LIVE_ALIGNMENT_ACK=one-paid-synthetic-test`. Run that one test with `--ignored --exact`; it makes one paid request with no automatic retry. Ordinary test runs never read a provider key or run this probe.

Provider contracts: [MusicBrainz rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting), [AcoustID web service](https://acoustid.org/webservice), [LRCLIB documentation](https://lrclib.net/docs), [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API), [HTTP caching](https://www.rfc-editor.org/rfc/rfc9111.html), [ElevenLabs Forced Alignment](https://elevenlabs.io/docs/api-reference/forced-alignment/create), [ElevenLabs speech to text](https://elevenlabs.io/docs/api-reference/speech-to-text/convert). Provider/data terms and lyrics/artwork permissions apply independently of cache retention.

## Lyric interpretation with Codex

This optional personal integration uses the installed Codex CLI and its existing
ChatGPT login. Sonora never reads, exports or copies the CLI credential. Enable it
in the proxy TOML configuration after signing in with `codex login` as the same OS
user that runs the proxy:

```toml
[codex]
enabled = true
binary = "/absolute/path/to/codex"
```

The adapter is verified with Codex CLI 0.162.0. It uses `codex exec` in an ephemeral,
read-only session with user configuration, project instructions, shell tools,
plugins, hooks, browsing and app connectors disabled. Interpretation requests select
`gpt-6-astra` with reasoning effort `xhigh`; translation requests select `gpt-6.1-sol`
with `medium`. Both use the default service tier and ChatGPT auth.
No API key is required. Each new analysis consumes the account's Codex allowance;
this does not turn a ChatGPT login into an API key.

The protected `/v1/lyrics/interpret` route accepts up to 64 KiB of lyrics and one
response language (`es`, `en`, `fr`, `de`, `it`, `pt`). The optional `context` object
contains `title`, `artist`, `album` (up to 4096 UTF-8 bytes each), `styles` (up to
two labels of 200 bytes) and `moods` (up to two of `happy`, `sad`, `relaxed`,
`aggressive`). Missing context remains valid for older clients. The app supplies
the same prominent style/mood labels shown in the player, after preparing the
available audio analysis. Unavailable or disabled analysis does not prevent a
reading based on the song metadata and lyrics. No audio is sent to Codex.
All fields are treated as data; tags are explicitly described as estimates,
with lyrics as primary evidence and no claim of confirmed author intent. Results
identify their model and effort. The iPhone labels them as AI interpretations.

The protected `/v1/lyrics/translate` route accepts up to 2000 nonempty lines and
100 KB of lyric text (10 KB per line). Source can be `auto`; otherwise source and
target are language tags such as `en`, `es` or `zh-Hans`. The complete document is
one request, so expressions split across lines keep their context. The response
contains `lines` with the same IDs in the same order, plus `model` and `effort`.
Every ID must occur exactly once with nonempty translated text. Source timestamps
are never sent or generated. The client rejects incomplete or mismatched output.

Up to four Codex processes run concurrently across both routes, with at most eight
active/waiting requests. The app also shares a four-request limit between its
translation and interpretation queues.
The process deadline is 180 seconds and the total queue deadline 210 seconds.
The proxy does not automatically start another Codex invocation after failure.
Cancelling the owning task stops its child process. Requests for the same cache key
wait on that key before acquiring a process slot; ordinary callers reuse the first
successful cached result, while explicit refreshes run in order for that key.
Text, language, model, effort and prompt version form the SHA-256 cache identity.
Interpretation also includes the song context, so metadata/tag changes cannot
reuse another reading; lyric timestamp edits still reuse the cached meaning.
Translations and interpretations share the existing bounded SQLite cache and are reusable until
eviction, including when Codex is disabled. Errors are never cached as results.
The iPhone keeps its own exact-input cache for offline viewing.
Previously saved Codex translations remain available on the iPhone after the model
change. An explicit refresh replaces them with a result from the current model.
An explicit `refresh: true` in the request bypasses the server cache and replaces
the same entry only after a valid result. Normal requests continue
to reuse it. The app's **Sound → Refresh analysis** control also refreshes local
BPM, waveform and translation data; manual BPM corrections and markers survive.
Both lyric tools require an updated proxy. Older proxies return an explicit error
for the translation route instead of silently reusing an Apple translation.
Update the app and proxy together when changing the translation model: the client
validates the response model and effort as well as the line IDs.

Ordinary tests use a local stub CLI. The ignored
`live_codex_astra_xhigh_interpretation_and_cache` test uses only synthetic text and
requires explicitly setting `SONORA_LIVE_CODEX` to an approved CLI binary. It makes
one real request, then verifies reuse with Codex disabled.

The ignored `real_codex_translation` test accepts explicit `SONORA_REAL_CODEX_BINARY`,
`SONORA_REAL_TRANSLATION_INPUT` and `SONORA_REAL_TRANSLATION_OUTPUT` paths. It makes
one bounded real request and writes the validated result for semantic inspection.
Run it only with authorization to consume the user's Codex plan. Ordinary translation
tests cover IDs, authentication, shared capacity, cache persistence and refresh failures
using a stub; they do not establish translation quality.
## Local music style and mood analysis

The optional `POST /v1/audio/character` endpoint runs Discogs-EffNet and four
Essentia mood heads on this host. It accepts only canonical mono 16 kHz PCM16
WAV, from 1 to 90 sampled seconds (at most 2,880,044 bytes). The phone samples
three 30-second regions at 15%, 50% and 85% of the available start range, with
one region for tracks of 30 seconds or less. No audio goes to an external AI
provider and no original file or embedded genre is changed.
Clips shorter than three seconds repeat locally to fill the model's minimum
input; no synthetic audio is appended to the source file.

Install the optional runtime in a **new dedicated directory**, using `uv` on
PATH and Python 3.14 (the pinned native arm64 wheel requires macOS 15+):

```sh
python3 analysis/setup.py "$HOME/Library/Application Support/sonora-proxy/analysis"
```

Copy the printed `[audio_character]` section into the proxy configuration.
The installer does not edit configuration or restart services. Both runtime
paths must be absolute, or relative to the TOML file; `~/` expands to the
server user's home. Models are downloaded from Essentia's official host and
checked against the SHA-256 hashes embedded in `analysis/models.json`.
Runtime dependencies are pinned to the versions used in the local validation.

Enable the feature only after installing the runtime. Existing configurations
default to disabled, and `/v1/status` advertises its version and enabled state.
An older or disabled server is detected before the phone decodes or uploads
samples. Authentication and redirect protection are the same as other routes.

Only one TensorFlow child runs at a time (measured peak about 1.4 GiB); at most
eight requests hold upload/queue slots, reserved before reading their bodies.
Workers have a 60-second execution deadline and analysis, including queue time,
has a 90-second deadline. The HTTP route also bounds upload plus analysis to
110 seconds. Output
is limited to 32 KiB. Processes are killed when dropped. Cached results are
identified by sampled PCM, pipeline version and pinned model identities;
queued duplicates reuse the first completion. `?refresh=true` replaces a
cached result only after a valid, successful inference. The phone also keeps
content-addressed results and unchanged-file bindings for offline use.

Styles and moods are independent affinities, not accuracy percentages. The
player shows the two strongest styles and up to two moods scoring at least
0.6; the detail shows all returned styles and four mood affinities. Silence
produces an explicit empty result rather than invented tags. Timing, pitch,
speed, EQ and volume processing never enter this analysis.

Essentia and its pretrained weights have separate licences. The linked model
metadata includes noncommercial restrictions; review the [model catalogue](https://essentia.upf.edu/models.html)
and [licensing information](https://essentia.upf.edu/licensing_information.html)
before distributing a commercial product. Weights and Python binaries are not
bundled with the iPhone app or committed to this repository.

The model/pipeline version must change when changing sampling, preprocessing
or weights so the phone's derived-result cache is invalidated as well.
