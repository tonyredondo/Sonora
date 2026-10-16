# Sonora proxy

A Rust service for MusicBrainz metadata, AcoustID identification, LRCLIB lyrics and Cover Art Archive artwork. It caches downloaded responses in SQLite and shares a separate request budget for each provider across all callers. Audio decoding, fingerprint generation, candidate selection and tag writes belong on the iPhone.

This directory provides the backend API. Sonora's iOS interface does not call it yet. The service has no audio upload endpoint and does not edit music files or publish data to providers.

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

See [the complete example](sonora-proxy.example.toml). Credentials are plaintext as requested. Configuration values and provider request URLs/bodies are excluded from logs and parse errors. MusicBrainz, LRCLIB and Cover Art Archive public lookups do not require credentials. AcoustID identification needs your own application `client_key` in `[acoustid]`; registering/submitting fingerprints is outside this API.

The default listener is `127.0.0.1:8089`. If `[server].api_token` is set, every `/v1/` call requires `Authorization: Bearer <token>`. Binding to another interface requires a token of at least 24 characters. `/health` is public and returns only status/version. Remote deployments need an appropriate HTTPS endpoint; this binary serves HTTP and does not install a service or change network settings.

## Cache and scheduling

Provider JSON, plain/timed lyrics and actual artwork bytes share one persistent SQLite cache. Secrets are not cache keys or cached headers. Cache keys include the upstream endpoint and lookup arguments, so changing an administrator-configured mirror does not reuse another endpoint's answers.

Default freshness caps are seven days for MusicBrainz, 30 days for AcoustID/LRCLIB and 90 days for artwork. Origin freshness can shorten these caps. Expired entries retain ETag/Last-Modified validators for conditional requests; a 304 refreshes freshness while retaining the body. Nothing polls providers in the background. Responses marked `no-store`, `private`, or an unsupported `Vary` are not retained. `no-cache` requires validation on every reuse. A 404 is cached briefly (five minutes by default); authentication, throttling, server errors, oversized data and malformed responses are not successful cache entries.

The default payload budget is 512 MiB and 10,000 entries. Least recently used entries are evicted as needed; SQLite page/index metadata adds overhead. Freed pages are reclaimed after writes. The database has an ownership lock: two processes cannot use the same cache file simultaneously.

Identical in-flight requests share one provider operation, including retries. Each provider has a bounded queue (128 unique active/queued lookups by default). Interactive requests take priority, with a background turn after at most three interactive turns while both queues contain work. Cancelling one consumer preserves work needed by another; cancelling the last consumer drops queued work or the active HTTP future. Cache hits bypass the queue and rate budget.

MusicBrainz starts are spaced by at least 1.1 seconds by default, AcoustID by 350 ms, and artwork by one second. LRCLIB runs sequentially with a 500 ms delay after a completed response. Configuration rejects MusicBrainz intervals below one second and AcoustID intervals below 334 ms. A provider's retries and redirects consume the same budget. Throttling and server failures apply a shared cooldown, honor `Retry-After` and use bounded backoff with jitter when no delay is supplied. Defaults allow two retries, a 15-second HTTP timeout and a 60-second total lookup deadline, including queue time.

Run **one proxy instance per upstream budget/egress IP**. Separate processes or other applications on the same IP can still exceed MusicBrainz's shared limit. Replication would require a shared scheduler; an independent limiter in each replica is insufficient. Jobs, priorities and cooldowns are in memory; completed cache entries survive restarts.

## API

All JSON provider responses use an envelope with `provider`, `sources` (upstream request URLs), `cache`, `fetched_at` (Unix seconds) and `data`. Cache status is `hit`, `miss`, `shared` or `revalidated`; combined fingerprint candidates use `mixed` when their requests had different cache states and report the oldest component timestamp. Artwork returns image bytes and `X-Sonora-Cache`. HTTP responses to clients are `Cache-Control: no-store`; persistent caching is handled inside the proxy.

| Method | Path | Input / result |
| --- | --- | --- |
| GET | `/health` | Status and binary version |
| GET | `/v1/recordings` | `title`, optional `artist`, `album`, `duration`; up to 20 recording candidates and their release editions |
| GET | `/v1/recordings/{mbid}` | Recording details, credits, genres and release choices |
| GET | `/v1/releases/{mbid}` | Full MusicBrainz release JSON, including media/discs, track positions, dates and credits |
| GET | `/v1/lyrics` | Required `title`, `artist`, `album`, `duration` in seconds; LRCLIB's exact-signature result, including `plainLyrics`, `syncedLyrics`, `instrumental` |
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

Errors use JSON `error` and `message`: invalid input is 400, no provider result is 404, full queues are 429 with a retry hint, deadlines are 504, unavailable configuration/cache/providers are 503 and other upstream failures are 502. Transport success does not guarantee a matching recording, available lyrics or a cover.

## Verify

```sh
cargo test --locked --manifest-path proxy/Cargo.toml
cargo fmt --manifest-path proxy/Cargo.toml --check
cargo clippy --locked --manifest-path proxy/Cargo.toml --all-targets -- -D warnings
```

Integration tests run real HTTP clients against local synthetic provider servers and actual temporary SQLite files. They exercise restart reuse, conditional validation, deduplication, per-provider pacing, retries, cancellation, queue/memory bounds, authentication, partial batch results and artwork redirects. They do not need real keys, send personal music metadata, or consume production provider quotas. AcoustID's live authenticated lookup still needs a user-supplied registered client key. An iPhone consumer and deployment are separate work.

Provider contracts: [MusicBrainz rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting), [AcoustID web service](https://acoustid.org/webservice), [LRCLIB documentation](https://lrclib.net/docs), [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API), [HTTP caching](https://www.rfc-editor.org/rfc/rfc9111.html). Provider/data terms and lyrics/artwork permissions apply independently of cache retention.
