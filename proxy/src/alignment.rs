//! Opt-in forced alignment. Only canonical bounded PCM is accepted; source audio is never persisted.
use crate::{
    audio_job::{AudioJob, pcm_duration},
    config::Provider,
    providers::{Client, Error, Priority, Reply},
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const MAX_AUDIO_BYTES: usize = 19_200_044; // Ten minutes, mono 16 kHz PCM16.
pub const MAX_TEXT_BYTES: usize = 65_536;

#[derive(Clone)]
pub(crate) struct AlignmentInput {
    pub audio: Bytes,
    pub text: String,
    pub duration: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Alignment {
    pub plain_lyrics: String,
    pub synced_lyrics: String,
    pub audio_sha256: String,
    pub text_sha256: String,
    pub duration: f64,
}
pub fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

impl AlignmentInput {
    pub fn new(audio: Bytes, text: String) -> Result<Self, Error> {
        let bad = || {
            Error::InvalidInput(
                "alignment requires plain lyrics and a 1-600 second mono 16 kHz PCM16 WAV",
            )
        };
        if text.is_empty()
            || text.len() > MAX_TEXT_BYTES
            || text.contains('\0')
            || normalized(&text).is_empty()
            || text
                .lines()
                .any(|line| !line.trim().is_empty() && normalized(line).is_empty())
        {
            return Err(bad());
        }
        Ok(Self {
            duration: pcm_duration(&audio)?,
            audio,
            text,
        })
    }
    // Old positive cache entries may predate the strict start-time bound. Reject
    // and evict those locally; never issue another paid request in the same call.
    fn accepts_cached(&self, result: &Alignment) -> bool {
        result.synced_lyrics.lines().all(|line| {
            if line.trim().is_empty() {
                return true;
            }
            let Some((cue, _)) = line.strip_prefix('[').and_then(|line| line.split_once(']'))
            else {
                return false;
            };
            let Some((minutes, seconds)) = cue.split_once(':') else {
                return false;
            };
            match (minutes.parse::<u32>(), seconds.parse::<f64>()) {
                (Ok(minutes), Ok(seconds)) => {
                    seconds.is_finite()
                        && (0.0..60.0).contains(&seconds)
                        && f64::from(minutes) * 60.0 + seconds <= self.duration
                }
                _ => false,
            }
        })
    }
    /// Match the complete transcript in order, including repeated verses; retain original line text.
    pub fn aligned(&self, value: &serde_json::Value) -> Result<Alignment, Error> {
        #[derive(Deserialize)]
        struct Word {
            text: String,
            start: f64,
            end: f64,
        }
        #[derive(Deserialize)]
        struct Output {
            words: Vec<Word>,
        }
        let invalid = || Error::InvalidResponse(Provider::Elevenlabs);
        let out: Output = serde_json::from_value(value.clone()).map_err(|error| {
            tracing::warn!(validation_reason = "alignment_schema", category = ?error.classify(), "audio analysis rejected");
            invalid()
        })?;
        let mut transcript = String::new();
        let mut offsets = Vec::new();
        let mut previous = 0.0;
        for (index, word) in out.words.into_iter().enumerate() {
            if !word.start.is_finite()
                || !word.end.is_finite()
                || word.start < previous
                || word.start > self.duration
                || word.end < word.start
                || word.end > self.duration + 0.05
            {
                tracing::warn!(
                    validation_reason = "alignment_word_timing",
                    word_index = index,
                    start = word.start,
                    end = word.end,
                    previous_start = previous,
                    duration = self.duration,
                    "audio analysis rejected"
                );
                return Err(invalid());
            }
            previous = word.start;
            let token = normalized(&word.text);
            if !token.is_empty() {
                if word.end <= word.start {
                    tracing::warn!(
                        validation_reason = "alignment_word_duration",
                        word_index = index,
                        start = word.start,
                        end = word.end,
                        "audio analysis rejected"
                    );
                    return Err(invalid());
                }
                offsets.push((transcript.len(), word.start));
                transcript.push_str(&token);
            }
        }
        if transcript != normalized(&self.text) || offsets.is_empty() {
            tracing::warn!(
                validation_reason = "alignment_word_text_mismatch",
                words = offsets.len(),
                normalized_word_bytes = transcript.len(),
                normalized_text_bytes = normalized(&self.text).len(),
                "audio analysis rejected"
            );
            return Err(invalid());
        }
        let mut position = 0;
        let mut lines = Vec::new();
        for line in self.text.split('\n') {
            let token = normalized(line);
            if token.is_empty() {
                lines.push(line.to_owned());
                continue;
            }
            let time = offsets
                .iter()
                .rev()
                .find(|(p, _)| *p == position)
                .ok_or_else(invalid)?
                .1;
            let ticks = (time * 100.0).floor() as u64;
            lines.push(format!(
                "[{:02}:{:02}.{:02}]{}",
                ticks / 6000,
                ticks / 100 % 60,
                ticks % 100,
                line
            ));
            position += token.len();
        }
        Ok(Alignment {
            plain_lyrics: self.text.clone(),
            synced_lyrics: lines.join("\n"),
            audio_sha256: digest(&self.audio),
            text_sha256: digest(self.text.as_bytes()),
            duration: self.duration,
        })
    }
}
pub(crate) fn normalized(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

impl Client {
    pub async fn align(
        &self,
        audio: Bytes,
        text: String,
        priority: Priority,
    ) -> Result<Reply<Alignment>, Error> {
        let input = AlignmentInput::new(audio, text)?;
        let settings = self.config().provider(Provider::Elevenlabs);
        if settings.api_key.is_none() {
            return Err(Error::NotConfigured(Provider::Elevenlabs));
        }
        let mut spec = self.request(Provider::Elevenlabs, "/v1/forced-alignment", &[])?;
        let source = spec.url.to_string();
        spec.audio_job = Some(AudioJob::Alignment(input.clone()));
        let key = spec.key(&self.config().user_agent);
        let result = self.scheduler.fetch(spec, priority).await?;
        let data: Alignment = serde_json::from_slice(&result.entry.body)
            .map_err(|_| Error::InvalidResponse(Provider::Elevenlabs))?;
        if !input.accepts_cached(&data) {
            self.scheduler
                .cache()
                .remove(&key)
                .await
                .map_err(|_| Error::Cache)?;
            return Err(Error::InvalidResponse(Provider::Elevenlabs));
        }
        Ok(Reply {
            provider: Provider::Elevenlabs,
            sources: vec![source],
            cache: result.cache.into(),
            fetched_at: result.entry.stored_at,
            data,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn evicts_old_invalid_alignment_without_repeating_paid_work() {
        use crate::{
            cache::{CacheEntry, ResponseHeaders},
            config::Config,
        };
        let root = tempfile::TempDir::new().unwrap();
        let mut config = Config::default();
        config.cache.path = root.path().join("cache.sqlite");
        config.metadata.path = root.path().join("metadata.sqlite");
        config.elevenlabs.api_key = Some("fixture".into());
        config.elevenlabs.base_url = Some("http://127.0.0.1:9".into());
        let client = Client::new(config).unwrap();
        let mut audio = vec![0; 64044];
        audio[..44].copy_from_slice(&[
            b'R', b'I', b'F', b'F', 36, 250, 0, 0, b'W', b'A', b'V', b'E', b'f', b'm', b't', b' ',
            16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0, b'd', b'a', b't',
            b'a', 0, 250, 0, 0,
        ]);
        let input = AlignmentInput::new(audio.clone().into(), "Hello".into()).unwrap();
        let mut spec = client
            .request(Provider::Elevenlabs, "/v1/forced-alignment", &[])
            .unwrap();
        spec.audio_job = Some(AudioJob::Alignment(input));
        let key = spec.key(&client.config().user_agent);
        let cached = Alignment {
            plain_lyrics: "Hello".into(),
            synced_lyrics: "[00:02.01]Hello".into(),
            audio_sha256: digest(&audio),
            text_sha256: digest(b"Hello"),
            duration: 2.0,
        };
        let cache = client.scheduler.cache();
        cache
            .put(
                &key,
                CacheEntry {
                    status: 200,
                    headers: ResponseHeaders::default(),
                    body: serde_json::to_vec(&cached).unwrap().into(),
                    stored_at: 1,
                    expires_at: crate::cache::unix_time() + 86400,
                },
            )
            .await
            .unwrap();
        let result = client
            .align(audio.into(), "Hello".into(), Priority::Interactive)
            .await;
        // A request to the closed fixture port would return Upstream instead.
        assert!(matches!(
            result,
            Err(Error::InvalidResponse(Provider::Elevenlabs))
        ));
        assert!(cache.get(&key).await.unwrap().is_none());
    }
    #[test]
    fn rejects_word_starts_beyond_audio_even_inside_end_tolerance() {
        let input = AlignmentInput {
            audio: Bytes::new(),
            text: "Hello".into(),
            duration: 2.0,
        };
        assert!(
            input
                .aligned(&serde_json::json!({"words":[{"text":"Hello","start":2.01,"end":2.02}]}))
                .is_err()
        );
        assert!(
            input
                .aligned(&serde_json::json!({"words":[{"text":"Hello","start":1.99,"end":2.02}]}))
                .is_ok()
        );
    }
    #[test]
    fn rejects_incomplete_transcript_and_out_of_range_timestamps() {
        let input = AlignmentInput {
            audio: Bytes::new(),
            text: "Hello\nHello".into(),
            duration: 3.0,
        };
        for words in [
            serde_json::json!([{"text":"Hello","start":0,"end":1}]),
            serde_json::json!([{"text":"Hello Hello","start":0,"end":4}]),
            serde_json::json!([{"text":"Hello","start":2,"end":2.5},{"text":"Hello","start":1,"end":1.5}]),
        ] {
            assert!(input.aligned(&serde_json::json!({"words":words})).is_err());
        }
    }
}
