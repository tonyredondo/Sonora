//! Plaintext TOML configuration and deterministic discovery.

use serde::Deserialize;
use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    time::Duration,
};

/// Configuration failures deliberately omit TOML source, which can contain secrets.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("configuration file could not be read")]
    Read,
    #[error("configuration is not valid TOML or contains unknown fields")]
    Parse,
    #[error("invalid configuration: {0}")]
    Invalid(&'static str),
    #[error(
        "no configuration file found; use --config or create ~/.config/sonora-proxy/config.toml"
    )]
    Missing,
}

/// Explicit paths are authoritative: a missing explicit file never falls back.
pub fn discover_config(
    explicit: Option<&Path>,
    home: &Path,
    executable_dir: &Path,
) -> Result<PathBuf, ConfigError> {
    if let Some(path) = explicit {
        return path
            .is_file()
            .then(|| path.to_owned())
            .ok_or(ConfigError::Read);
    }
    [
        home.join(".config/sonora-proxy/config.toml"),
        executable_dir.join("sonora-proxy.toml"),
    ]
    .into_iter()
    .find(|p| p.is_file())
    .ok_or(ConfigError::Missing)
}

/// The independent upstream budgets. All callers of one process share each budget.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, serde::Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Musicbrainz,
    Acoustid,
    Lrclib,
    CoverArt,
    Elevenlabs,
}

impl Provider {
    pub const ALL: [Self; 5] = [
        Self::Musicbrainz,
        Self::Acoustid,
        Self::Lrclib,
        Self::CoverArt,
        Self::Elevenlabs,
    ];
    pub fn name(self) -> &'static str {
        match self {
            Self::Musicbrainz => "musicbrainz",
            Self::Acoustid => "acoustid",
            Self::Lrclib => "lrclib",
            Self::CoverArt => "cover_art",
            Self::Elevenlabs => "elevenlabs",
        }
    }
    pub fn base_url(self) -> &'static str {
        match self {
            Self::Musicbrainz => "https://musicbrainz.org",
            Self::Acoustid => "https://api.acoustid.org",
            Self::Lrclib => "https://lrclib.net",
            Self::CoverArt => "https://coverartarchive.org",
            Self::Elevenlabs => "https://api.elevenlabs.io",
        }
    }
    pub fn interval(self) -> Duration {
        Duration::from_millis(match self {
            Self::Musicbrainz => 1100,
            Self::Acoustid => 350,
            Self::Lrclib => 500,
            Self::CoverArt => 1000,
            Self::Elevenlabs => 1000,
        })
    }
    pub fn ttl(self) -> u64 {
        86400
            * match self {
                Self::Musicbrainz => 7,
                Self::Acoustid | Self::Lrclib => 30,
                Self::CoverArt => 90,
                Self::Elevenlabs => 365,
            }
    }
}

/// Omitted settings use conservative provider-specific defaults.
#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ProviderConfig {
    pub enabled: bool,
    pub min_interval_ms: Option<u64>,
    pub ttl_seconds: Option<u64>,
    /// Intended for administrator-controlled mirrors and local test servers.
    pub base_url: Option<String>,
    pub client_key: Option<String>,
    /// ElevenLabs credential. Never included in diagnostic output or cache keys.
    pub api_key: Option<String>,
}
impl Default for ProviderConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            min_interval_ms: None,
            ttl_seconds: None,
            base_url: None,
            client_key: None,
            api_key: None,
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServerConfig {
    pub listen: SocketAddr,
    pub api_token: Option<String>,
    pub max_jobs: usize,
    pub max_tracks_per_job: usize,
    pub max_job_result_bytes: usize,
    /// Durable panorama sources and undelivered results, separate from the evictable provider cache.
    pub panorama_max_bytes: u64,
    pub job_retention_seconds: u64,
}
impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            listen: ([127, 0, 0, 1], 8089).into(),
            api_token: None,
            max_jobs: 64,
            max_tracks_per_job: 100,
            max_job_result_bytes: 4_000_000,
            panorama_max_bytes: 512 * 1024 * 1024,
            job_retention_seconds: 3600,
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct CacheConfig {
    pub path: PathBuf,
    /// Payload budget; SQLite indexes and page metadata add a small overhead.
    pub max_bytes: u64,
    pub max_entries: usize,
    pub negative_ttl_seconds: u64,
}
impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            path: dirs::cache_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join("sonora-proxy/cache.sqlite"),
            max_bytes: 512 * 1024 * 1024,
            max_entries: 10000,
            negative_ttl_seconds: 300,
        }
    }
}

/// Confirmed edits are durable data, never subject to provider-cache eviction.
#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct MetadataConfig {
    pub path: PathBuf,
    /// Reaching this budget rejects new copies; existing copies are never evicted.
    pub max_bytes: u64,
}
impl Default for MetadataConfig {
    fn default() -> Self {
        Self {
            path: dirs::data_local_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join("sonora-proxy/metadata.sqlite"),
            max_bytes: 5 * 1024 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct NetworkConfig {
    pub queue_capacity: usize,
    pub deadline_seconds: u64,
    pub timeout_seconds: u64,
    pub max_retries: u32,
    pub max_response_bytes: usize,
}
impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            queue_capacity: 128,
            deadline_seconds: 60,
            timeout_seconds: 15,
            max_retries: 2,
            max_response_bytes: 10_000_000,
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct CodexConfig {
    /// Opt in to using this OS user's existing Codex ChatGPT session.
    pub enabled: bool,
    /// Prefer an absolute path when running the proxy through launchd.
    pub binary: PathBuf,
}
impl Default for CodexConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            binary: PathBuf::from("codex"),
        }
    }
}

/// Optional local runtime. Relative paths are resolved alongside the TOML file.
#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AudioCharacterConfig {
    pub enabled: bool,
    pub python: PathBuf,
    pub models: PathBuf,
}
impl Default for AudioCharacterConfig {
    fn default() -> Self {
        let root = dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("sonora-proxy/analysis");
        Self {
            enabled: false,
            python: root.join(".venv/bin/python"),
            models: root.join("models"),
        }
    }
}

/// Secrets are intentionally excluded from Debug and all diagnostic output.
#[derive(Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub user_agent: String,
    pub server: ServerConfig,
    pub cache: CacheConfig,
    pub metadata: MetadataConfig,
    pub network: NetworkConfig,
    pub musicbrainz: ProviderConfig,
    pub acoustid: ProviderConfig,
    pub lrclib: ProviderConfig,
    pub cover_art: ProviderConfig,
    pub elevenlabs: ProviderConfig,
    pub codex: CodexConfig,
    pub audio_character: AudioCharacterConfig,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            user_agent: "SonoraProxy/0.1.0 (https://github.com/tonyredondo/Sonora)".into(),
            server: ServerConfig::default(),
            cache: CacheConfig::default(),
            metadata: MetadataConfig::default(),
            network: NetworkConfig::default(),
            musicbrainz: ProviderConfig::default(),
            acoustid: ProviderConfig::default(),
            lrclib: ProviderConfig::default(),
            cover_art: ProviderConfig::default(),
            elevenlabs: ProviderConfig::default(),
            codex: CodexConfig::default(),
            audio_character: AudioCharacterConfig::default(),
        }
    }
}
impl Config {
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        if std::fs::metadata(path)
            .map_err(|_| ConfigError::Read)?
            .len()
            > 65536
        {
            return Err(ConfigError::Invalid("file exceeds 64 KiB"));
        }
        let text = std::fs::read_to_string(path).map_err(|_| ConfigError::Read)?;
        let absolute = std::path::absolute(path).map_err(|_| ConfigError::Read)?;
        Self::parse(
            &text,
            absolute.parent().ok_or(ConfigError::Read)?.to_owned(),
        )
    }
    /// Relative storage paths are resolved against the configuration file's directory.
    pub fn parse(text: &str, directory: PathBuf) -> Result<Self, ConfigError> {
        let mut config: Self = toml::from_str(text).map_err(|_| ConfigError::Parse)?;
        if let Ok(suffix) = config.cache.path.strip_prefix("~") {
            config.cache.path = dirs::home_dir()
                .ok_or(ConfigError::Invalid("home directory is unavailable"))?
                .join(suffix);
        } else if config.cache.path.is_relative() {
            config.cache.path = directory.join(&config.cache.path);
        }
        if let Ok(suffix) = config.metadata.path.strip_prefix("~") {
            config.metadata.path = dirs::home_dir()
                .ok_or(ConfigError::Invalid("home directory is unavailable"))?
                .join(suffix);
        } else if config.metadata.path.is_relative() {
            config.metadata.path = directory.join(&config.metadata.path);
        }
        for path in [
            &mut config.audio_character.python,
            &mut config.audio_character.models,
        ] {
            if let Ok(suffix) = path.strip_prefix("~") {
                *path = dirs::home_dir()
                    .ok_or(ConfigError::Invalid("home directory is unavailable"))?
                    .join(suffix);
            } else if path.is_relative() {
                *path = directory.join(&*path);
            }
        }
        config.validate()?;
        Ok(config)
    }
    pub fn provider(&self, provider: Provider) -> &ProviderConfig {
        match provider {
            Provider::Musicbrainz => &self.musicbrainz,
            Provider::Acoustid => &self.acoustid,
            Provider::Lrclib => &self.lrclib,
            Provider::CoverArt => &self.cover_art,
            Provider::Elevenlabs => &self.elevenlabs,
        }
    }
    pub fn validate(&self) -> Result<(), ConfigError> {
        let invalid = ConfigError::Invalid;
        if self.audio_character.python.as_os_str().is_empty()
            || self.audio_character.models.as_os_str().is_empty()
        {
            return Err(invalid("local analysis paths must not be empty"));
        }
        if self.codex.binary.as_os_str().is_empty()
            || (self.codex.binary.is_relative() && self.codex.binary.components().count() != 1)
        {
            return Err(invalid(
                "codex binary must be an absolute path or a command name",
            ));
        }
        if config_paths_overlap(&self.cache.path, &self.metadata.path)
            || self.metadata.path.as_os_str().is_empty()
            || !(22_000_000..=1024 * 1024 * 1024 * 1024).contains(&self.metadata.max_bytes)
        {
            return Err(invalid(
                "metadata storage requires a separate path and a 22 MB-1 TiB budget",
            ));
        }
        let panorama = self.cache.path.with_extension("panorama.sqlite");
        if config_paths_overlap(&panorama, &self.metadata.path)
            || !(22_000_000..=10 * 1024 * 1024 * 1024).contains(&self.server.panorama_max_bytes)
        {
            return Err(invalid(
                "panorama jobs require a separate path and a 22 MB-10 GiB budget",
            ));
        }
        if self.user_agent.len() < 10
            || self.user_agent.len() > 512
            || reqwest::header::HeaderValue::from_str(&self.user_agent).is_err()
        {
            return Err(invalid(
                "user_agent must be a valid identifying HTTP header",
            ));
        }
        if !self.server.listen.ip().is_loopback()
            && self
                .server
                .api_token
                .as_ref()
                .is_none_or(|s| s.trim().len() < 24)
        {
            return Err(invalid(
                "non-loopback listeners require an api_token of at least 24 characters",
            ));
        }
        if self.server.api_token.as_ref().is_some_and(|s| {
            s.is_empty() || s.len() > 512 || s.bytes().any(|b| !b.is_ascii_graphic())
        }) {
            return Err(invalid(
                "api_token must contain 1-512 visible ASCII characters",
            ));
        }
        if !(1..=1024).contains(&self.server.max_jobs)
            || !(1..=500).contains(&self.server.max_tracks_per_job)
            || !(60..=86400).contains(&self.server.job_retention_seconds)
        {
            return Err(invalid("job limits are outside their supported ranges"));
        }
        if !(1024..=20_000_000).contains(&self.server.max_job_result_bytes) {
            return Err(invalid("max_job_result_bytes must be 1024-20000000"));
        }
        if self.cache.max_bytes == 0
            || self.cache.max_bytes > 100 * 1024 * 1024 * 1024
            || !(1..=100000).contains(&self.cache.max_entries)
            || self.cache.negative_ttl_seconds > 3600
        {
            return Err(invalid("cache limits are outside their supported ranges"));
        }
        if !(1..=1024).contains(&self.network.queue_capacity)
            || !(1..=300).contains(&self.network.deadline_seconds)
            || !(1..=60).contains(&self.network.timeout_seconds)
            || self.network.max_retries > 5
            || !(1024..=20_000_000).contains(&self.network.max_response_bytes)
        {
            return Err(invalid("network limits are outside their supported ranges"));
        }
        for provider in Provider::ALL {
            let settings = self.provider(provider);
            let minimum = match provider {
                Provider::Musicbrainz => 1000,
                Provider::Acoustid => 334,
                Provider::Lrclib => 200,
                Provider::CoverArt => 200,
                Provider::Elevenlabs => 1000,
            };
            if settings
                .min_interval_ms
                .is_some_and(|ms| ms < minimum || ms > 3_600_000)
                || settings.ttl_seconds.is_some_and(|s| s > 365 * 86400)
            {
                return Err(invalid(
                    "provider interval or TTL is outside its supported range",
                ));
            }
            if let Some(base) = &settings.base_url {
                let url =
                    url::Url::parse(base).map_err(|_| invalid("provider base_url is invalid"))?;
                let local = url
                    .host_str()
                    .and_then(|h| h.parse::<std::net::IpAddr>().ok())
                    .is_some_and(|ip| ip.is_loopback());
                if (url.scheme() != "https" && !(url.scheme() == "http" && local))
                    || !url.username().is_empty()
                    || url.password().is_some()
                    || url.query().is_some()
                    || url.fragment().is_some()
                    || url.host_str().is_none()
                {
                    return Err(invalid(
                        "provider base_url requires HTTPS or loopback HTTP, without credentials, query or fragment",
                    ));
                }
            }
            if settings.api_key.as_ref().is_some_and(|key| {
                key.is_empty() || key.len() > 512 || !key.bytes().all(|b| b.is_ascii_graphic())
            }) {
                return Err(invalid(
                    "provider api_key must contain 1-512 visible ASCII characters",
                ));
            }
            if settings
                .client_key
                .as_ref()
                .is_some_and(|key| key.trim().is_empty() || key.len() > 512)
            {
                return Err(invalid("provider client_key must contain 1-512 characters"));
            }
        }
        Ok(())
    }
}

fn config_paths_overlap(cache: &Path, metadata: &Path) -> bool {
    cache == metadata || cache.with_extension("lockfile") == metadata.with_extension("lockfile")
}
