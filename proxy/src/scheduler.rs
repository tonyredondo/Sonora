//! One bounded, fair queue and one outbound worker per provider.

use crate::{
    cache::{Cache, CacheEntry, ResponseHeaders, WeakCache, unix_time},
    config::{Config, Provider},
    providers::{Error, Priority},
};
use bytes::Bytes;
use reqwest::{Client, StatusCode, Url, header::HeaderMap};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::{Duration, SystemTime},
};
use tokio::{
    sync::{Mutex, Notify, watch},
    task::JoinHandle,
    time::Instant,
};

#[derive(Clone)]
pub(crate) struct RequestSpec {
    pub provider: Provider,
    pub url: Url,
    pub form: Option<Vec<(String, String)>>,
    pub image: bool,
}
impl RequestSpec {
    fn key(&self, user_agent: &str) -> String {
        let mut hash = Sha256::new();
        hash.update(b"sonora-http-v1\0");
        hash.update(self.provider.name());
        hash.update(b"\0");
        hash.update(self.url.as_str());
        hash.update(b"\0");
        hash.update(user_agent);
        if let Some(form) = &self.form {
            // AcoustID's public lookup data is independent of the application's client key.
            for (key, value) in form.iter().filter(|(k, _)| k != "client") {
                hash.update(b"\0");
                hash.update(key);
                hash.update(b"\0");
                hash.update(value);
            }
        }
        format!("{:x}", hash.finalize())
    }
}

#[derive(Clone)]
pub(crate) struct FetchResult {
    pub entry: Arc<CacheEntry>,
    pub cache: &'static str,
}
type FlightResult = Option<Result<FetchResult, Error>>;
struct Work {
    key: String,
    spec: RequestSpec,
    result: watch::Sender<FlightResult>,
}

#[derive(Default)]
struct QueueState {
    interactive: VecDeque<Work>,
    background: VecDeque<Work>,
    flights: HashMap<String, watch::Sender<FlightResult>>,
    interactive_streak: u8,
}
impl QueueState {
    fn prune(&mut self) {
        self.interactive.retain(|w| w.result.receiver_count() > 0);
        self.background.retain(|w| w.result.receiver_count() > 0);
        self.flights.retain(|_, tx| tx.receiver_count() > 0);
    }
    fn next(&mut self) -> Option<Work> {
        self.prune();
        if !self.background.is_empty()
            && (self.interactive.is_empty() || self.interactive_streak >= 3)
        {
            self.interactive_streak = 0;
            self.background.pop_front()
        } else {
            let work = self.interactive.pop_front();
            if work.is_some() {
                self.interactive_streak = self.interactive_streak.saturating_add(1);
            }
            work
        }
    }
}
struct Queue {
    state: Mutex<QueueState>,
    changed: Notify,
}
struct Inner {
    cache: Cache,
    queues: HashMap<Provider, Arc<Queue>>,
    config: Config,
    workers: Vec<JoinHandle<()>>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        for worker in &self.workers {
            worker.abort();
        }
    }
}

#[derive(Clone)]
pub(crate) struct Scheduler(Arc<Inner>);
impl Scheduler {
    pub fn new(config: Config) -> Result<Self, Error> {
        config.validate().map_err(|_| Error::Configuration)?;
        let cache = Cache::open(
            &config.cache.path,
            config.cache.max_bytes,
            config.cache.max_entries,
        )
        .map_err(|_| Error::Cache)?;
        let client = Client::builder()
            .user_agent(&config.user_agent)
            .timeout(Duration::from_secs(config.network.timeout_seconds))
            .connect_timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| Error::Configuration)?;
        let mut queues = HashMap::new();
        let mut workers = Vec::new();
        for provider in Provider::ALL {
            let queue = Arc::new(Queue {
                state: Mutex::default(),
                changed: Notify::new(),
            });
            workers.push(tokio::spawn(worker(
                queue.clone(),
                cache.downgrade(),
                client.clone(),
                config.clone(),
                provider,
            )));
            queues.insert(provider, queue);
        }
        Ok(Self(Arc::new(Inner {
            cache,
            queues,
            config,
            workers,
        })))
    }
    pub async fn fetch(&self, spec: RequestSpec, priority: Priority) -> Result<FetchResult, Error> {
        let deadline = Duration::from_secs(self.0.config.network.deadline_seconds);
        tokio::time::timeout(deadline, self.fetch_inner(spec, priority))
            .await
            .map_err(|_| Error::Deadline)?
    }
    async fn fetch_inner(
        &self,
        spec: RequestSpec,
        priority: Priority,
    ) -> Result<FetchResult, Error> {
        if !self.0.config.provider(spec.provider).enabled {
            return Err(Error::Disabled(spec.provider));
        }
        let key = spec.key(&self.0.config.user_agent);
        if let Some(entry) = self
            .0
            .cache
            .get(&key)
            .await
            .map_err(|_| Error::Cache)?
            .filter(|e| e.is_fresh(unix_time()))
        {
            return Ok(FetchResult {
                entry: Arc::new(entry),
                cache: "hit",
            });
        }
        let queue = self
            .0
            .queues
            .get(&spec.provider)
            .ok_or(Error::Configuration)?;
        let (mut receiver, shared) = {
            let mut state = queue.state.lock().await;
            state.prune();
            if let Some(tx) = state.flights.get(&key) {
                let rx = tx.subscribe();
                if priority == Priority::Interactive {
                    if let Some(index) = state.background.iter().position(|w| w.key == key) {
                        if let Some(work) = state.background.remove(index) {
                            state.interactive.push_back(work);
                        }
                    }
                }
                (rx, true)
            } else {
                if state.flights.len() >= self.0.config.network.queue_capacity {
                    return Err(Error::QueueFull);
                }
                let (tx, rx) = watch::channel(None);
                state.flights.insert(key.clone(), tx.clone());
                let work = Work {
                    key,
                    spec,
                    result: tx,
                };
                match priority {
                    Priority::Interactive => state.interactive.push_back(work),
                    Priority::Background => state.background.push_back(work),
                }
                (rx, false)
            }
        };
        queue.changed.notify_one();
        loop {
            if let Some(result) = receiver.borrow_and_update().clone() {
                return result.map(|mut result| {
                    if shared {
                        result.cache = "shared";
                    }
                    result
                });
            }
            receiver.changed().await.map_err(|_| Error::Unavailable)?;
        }
    }
}

async fn worker(
    queue: Arc<Queue>,
    cache: WeakCache,
    client: Client,
    config: Config,
    provider: Provider,
) {
    let mut next_start = Instant::now();
    loop {
        let notification = queue.changed.notified();
        let empty = {
            let mut state = queue.state.lock().await;
            state.prune();
            state.interactive.is_empty() && state.background.is_empty()
        };
        if empty {
            notification.await;
            continue;
        }
        // Choose priority after the rate-limit wait, so a newly arrived interactive lookup can pass a queued batch lookup.
        tokio::time::sleep_until(next_start).await;
        let Some(work) = queue.state.lock().await.next() else {
            continue;
        };
        let Some(storage) = cache.upgrade() else {
            return;
        };
        let result = tokio::select! {
            biased;
            _=work.result.closed()=>None,
            result=fetch_remote(&client,&storage,&config,&work.key,&work.spec,&mut next_start)=>Some(result),
        };
        drop(storage);
        let mut state = queue.state.lock().await;
        // A cancelled flight can have been replaced while its HTTP future was being dropped.
        if state
            .flights
            .get(&work.key)
            .is_some_and(|tx| tx.same_channel(&work.result))
        {
            state.flights.remove(&work.key);
        }
        if let Some(result) = result {
            work.result.send_replace(Some(result));
        }
        tracing::debug!(provider = provider.name(), "provider work finished");
    }
}

async fn fetch_remote(
    client: &Client,
    cache: &Cache,
    config: &Config,
    key: &str,
    spec: &RequestSpec,
    next_start: &mut Instant,
) -> Result<FetchResult, Error> {
    let stale = cache.get(key).await.map_err(|_| Error::Cache)?;
    if let Some(entry) = stale.as_ref().filter(|e| e.is_fresh(unix_time())) {
        return Ok(FetchResult {
            entry: Arc::new(entry.clone()),
            cache: "hit",
        });
    }
    let settings = config.provider(spec.provider);
    let interval = settings
        .min_interval_ms
        .map(Duration::from_millis)
        .unwrap_or_else(|| spec.provider.interval());
    let mut retries = 0;
    let mut redirects = 0;
    let mut url = spec.url.clone();
    loop {
        tokio::time::sleep_until(*next_start).await;
        *next_start = Instant::now() + interval;
        let mut request = if let Some(form) = &spec.form {
            client.post(url.clone()).form(form)
        } else {
            client.get(url.clone())
        };
        request = request.header(
            "Accept",
            if spec.image {
                "image/jpeg,image/png,image/webp"
            } else {
                "application/json"
            },
        );
        if let Some(old) = &stale {
            if let Some(etag) = &old.headers.etag {
                request = request.header("If-None-Match", etag);
            } else if let Some(date) = &old.headers.last_modified {
                request = request.header("If-Modified-Since", date);
            }
        }
        let response = match request.send().await {
            Ok(response) => response,
            Err(_) => {
                // reqwest errors can include URLs and form data. Do not propagate them.
                if retries >= config.network.max_retries {
                    return Err(Error::Upstream {
                        provider: spec.provider,
                        status: None,
                    });
                }
                *next_start = (*next_start).max(Instant::now() + backoff(retries));
                retries += 1;
                continue;
            }
        };
        let status = response.status();
        if status.is_redirection() && status != StatusCode::NOT_MODIFIED {
            if spec.form.is_some() || redirects >= 4 {
                return Err(Error::InvalidResponse(spec.provider));
            }
            let location = response
                .headers()
                .get("location")
                .and_then(|h| h.to_str().ok())
                .ok_or(Error::InvalidResponse(spec.provider))?;
            let target = url
                .join(location)
                .map_err(|_| Error::InvalidResponse(spec.provider))?;
            if !allowed_redirect(spec, &target) {
                return Err(Error::InvalidResponse(spec.provider));
            }
            url = target;
            redirects += 1;
            continue;
        }
        if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
            let delay = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(retry_after)
                .unwrap_or_else(|| backoff(retries));
            *next_start = (*next_start).max(Instant::now() + delay);
            if retries >= config.network.max_retries {
                return Err(Error::Upstream {
                    provider: spec.provider,
                    status: Some(status.as_u16()),
                });
            }
            retries += 1;
            continue;
        }
        let now = unix_time();
        let headers = ResponseHeaders::from_http(response.headers());
        let (entry, cache_status) = if status == StatusCode::NOT_MODIFIED {
            let mut entry = stale.clone().ok_or(Error::InvalidResponse(spec.provider))?;
            entry.headers.merge(headers);
            entry.stored_at = now;
            (entry, "revalidated")
        } else {
            if status != StatusCode::OK && status != StatusCode::NOT_FOUND {
                return Err(Error::Upstream {
                    provider: spec.provider,
                    status: Some(status.as_u16()),
                });
            }
            let body = match read_body(response, config.network.max_response_bytes).await {
                Ok(body) => body,
                Err(BodyError::Large) => return Err(Error::TooLarge),
                Err(BodyError::Network) => {
                    if retries >= config.network.max_retries {
                        return Err(Error::Upstream {
                            provider: spec.provider,
                            status: None,
                        });
                    }
                    *next_start = (*next_start).max(Instant::now() + backoff(retries));
                    retries += 1;
                    continue;
                }
            };
            if status == StatusCode::OK {
                if spec.image {
                    let mime = headers
                        .content_type
                        .as_deref()
                        .unwrap_or("")
                        .split(';')
                        .next()
                        .unwrap_or("")
                        .trim();
                    if !matches!(mime, "image/jpeg" | "image/png" | "image/webp") || body.is_empty()
                    {
                        return Err(Error::InvalidResponse(spec.provider));
                    }
                } else {
                    let value: serde_json::Value = serde_json::from_slice(&body)
                        .map_err(|_| Error::InvalidResponse(spec.provider))?;
                    crate::providers::validate_payload(spec.provider, spec.url.path(), &value)?;
                }
            }
            (
                CacheEntry {
                    status: status.as_u16(),
                    headers,
                    body,
                    stored_at: now,
                    expires_at: now,
                },
                "miss",
            )
        };
        let configured_ttl = if entry.status == 404 {
            config.cache.negative_ttl_seconds
        } else {
            settings.ttl_seconds.unwrap_or_else(|| spec.provider.ttl())
        };
        let mut entry = entry;
        if let Some(ttl) = entry.headers.lifetime(now, configured_ttl) {
            entry.expires_at = now.saturating_add(ttl);
            cache
                .put(key, entry.clone())
                .await
                .map_err(|_| Error::Cache)?;
        } else {
            cache.remove(key).await.map_err(|_| Error::Cache)?;
        }
        // LRCLIB asks clients to complete each request before a short delay.
        if spec.provider == Provider::Lrclib {
            *next_start = Instant::now() + interval;
        }
        return Ok(FetchResult {
            entry: Arc::new(entry),
            cache: cache_status,
        });
    }
}

fn backoff(attempt: u32) -> Duration {
    Duration::from_millis((500_u64 << attempt.min(5)) + rand::random_range(0..=250))
}
fn retry_after(value: &str) -> Option<Duration> {
    let duration = if let Ok(seconds) = value.trim().parse::<u64>() {
        Duration::from_secs(seconds)
    } else {
        httpdate::parse_http_date(value)
            .ok()?
            .duration_since(SystemTime::now())
            .unwrap_or_default()
    };
    // Avoid Instant overflow on malformed or impractically distant server dates.
    Some(duration.min(Duration::from_secs(365 * 86400)))
}
fn allowed_redirect(spec: &RequestSpec, target: &Url) -> bool {
    if !target.username().is_empty() || target.password().is_some() {
        return false;
    }
    if target.origin() == spec.url.origin() {
        return true;
    }
    spec.provider == Provider::CoverArt
        && target.scheme() == "https"
        && target.port_or_known_default() == Some(443)
        && target.host_str().is_some_and(|host| {
            host == "archive.org" || host.ends_with(".archive.org") || host == "coverartarchive.org"
        })
}
enum BodyError {
    Large,
    Network,
}
async fn read_body(mut response: reqwest::Response, limit: usize) -> Result<Bytes, BodyError> {
    if response.content_length().is_some_and(|n| n > limit as u64) {
        return Err(BodyError::Large);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| BodyError::Network)? {
        if chunk.len() > limit.saturating_sub(body.len()) {
            return Err(BodyError::Large);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Bytes::from(body))
}

impl ResponseHeaders {
    fn from_http(headers: &HeaderMap) -> Self {
        let header = |name| {
            headers
                .get(name)
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned)
        };
        Self {
            content_type: header("content-type"),
            etag: header("etag"),
            last_modified: header("last-modified"),
            cache_control: header("cache-control"),
            expires: header("expires"),
            date: header("date"),
            vary: header("vary"),
            age: header("age"),
        }
    }
    fn merge(&mut self, new: Self) {
        macro_rules! replace { ($($field:ident),*) => { $(if new.$field.is_some() { self.$field=new.$field; })* }; }
        replace!(
            content_type,
            etag,
            last_modified,
            cache_control,
            expires,
            vary
        );
        self.date = new.date;
        self.age = new.age;
    }
    /// Provider TTLs are upper bounds; origin freshness and no-store/private always win.
    fn lifetime(&self, now: u64, configured: u64) -> Option<u64> {
        let mut max_age = None;
        let mut shared_max_age = None;
        let mut revalidate = false;
        if let Some(control) = &self.cache_control {
            for directive in control.split(',').map(str::trim) {
                let (name, value) = directive.split_once('=').unwrap_or((directive, ""));
                match name.trim().to_ascii_lowercase().as_str() {
                    "no-store" | "private" => return None,
                    "no-cache" => revalidate = true,
                    "s-maxage" => {
                        shared_max_age = value.trim().trim_matches('"').parse::<u64>().ok()
                    }
                    "max-age" => max_age = value.trim().trim_matches('"').parse::<u64>().ok(),
                    _ => {}
                }
            }
        }
        // Requests have a fixed Accept/User-Agent. Unknown Vary dimensions are unsafe to share.
        if self.vary.as_ref().is_some_and(|vary| {
            vary.split(',').any(|v| {
                !matches!(
                    v.trim().to_ascii_lowercase().as_str(),
                    "accept" | "accept-encoding" | "user-agent"
                )
            })
        }) {
            return None;
        }
        if revalidate {
            return Some(0);
        }
        let date = self
            .date
            .as_deref()
            .and_then(|s| httpdate::parse_http_date(s).ok())
            .and_then(|d| d.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs());
        let age = self
            .age
            .as_deref()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0)
            .max(date.map(|d| now.saturating_sub(d)).unwrap_or(0));
        if let Some(max_age) = shared_max_age.or(max_age) {
            return Some(configured.min(max_age.saturating_sub(age)));
        }
        if let Some(expires) = self
            .expires
            .as_deref()
            .and_then(|s| httpdate::parse_http_date(s).ok())
            .and_then(|d| d.duration_since(std::time::UNIX_EPOCH).ok())
        {
            return Some(
                configured.min(
                    expires
                        .as_secs()
                        .saturating_sub(date.unwrap_or(now))
                        .saturating_sub(age),
                ),
            );
        }
        Some(configured)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cache_expiry_accounts_for_origin_age_once() {
        let headers = ResponseHeaders {
            date: Some("Sun, 06 Nov 1994 08:49:37 GMT".into()),
            expires: Some("Sun, 06 Nov 1994 08:50:57 GMT".into()),
            age: Some("20".into()),
            ..Default::default()
        };
        let now = httpdate::parse_http_date("Sun, 06 Nov 1994 08:49:57 GMT")
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert_eq!(headers.lifetime(now, 300), Some(60));
    }
    #[test]
    fn cache_age_shared_freshness_and_validation_directives_are_respected() {
        let headers = ResponseHeaders {
            cache_control: Some("max-age=120, s-maxage=60".into()),
            age: Some("20".into()),
            ..Default::default()
        };
        assert_eq!(headers.lifetime(0, 300), Some(40));
        assert_eq!(headers.lifetime(0, 30), Some(30));
        assert_eq!(
            ResponseHeaders {
                cache_control: Some("no-cache".into()),
                ..Default::default()
            }
            .lifetime(0, 300),
            Some(0)
        );
        assert_eq!(
            ResponseHeaders {
                cache_control: Some("private=\"content-type\"".into()),
                ..Default::default()
            }
            .lifetime(0, 300),
            None
        );
    }
    #[test]
    fn retry_after_understands_seconds_dates_and_invalid_values() {
        assert_eq!(retry_after("12"), Some(Duration::from_secs(12)));
        assert_eq!(
            retry_after("Sun, 06 Nov 1994 08:49:37 GMT"),
            Some(Duration::ZERO)
        );
        assert_eq!(retry_after("invalid"), None);
    }
}
