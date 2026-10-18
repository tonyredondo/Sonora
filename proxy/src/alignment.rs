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
        let out: Output = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
        let mut transcript = String::new();
        let mut offsets = Vec::new();
        let mut previous = 0.0;
        for word in out.words {
            if !word.start.is_finite()
                || !word.end.is_finite()
                || word.start < previous
                || word.end < word.start
                || word.end > self.duration + 0.05
            {
                return Err(invalid());
            }
            previous = word.start;
            let token = normalized(&word.text);
            if !token.is_empty() {
                if word.end <= word.start {
                    return Err(invalid());
                }
                offsets.push((transcript.len(), word.start));
                transcript.push_str(&token);
            }
        }
        if transcript != normalized(&self.text) || offsets.is_empty() {
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
        spec.audio_job = Some(AudioJob::Alignment(input));
        let result = self.scheduler.fetch(spec, priority).await?;
        let data = serde_json::from_slice(&result.entry.body)
            .map_err(|_| Error::InvalidResponse(Provider::Elevenlabs))?;
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
