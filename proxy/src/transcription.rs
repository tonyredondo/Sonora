//! Opt-in Scribe transcription. Cache only the validated derived text, never uploaded PCM.
use crate::{
    alignment::{MAX_TEXT_BYTES, digest, normalized},
    audio_job::{AudioJob, pcm_duration},
    config::Provider,
    providers::{Client, Error, Priority, Reply},
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};

pub const MODEL_ID: &str = "scribe_v2";

#[derive(Clone)]
pub(crate) struct TranscriptionInput {
    pub audio: Bytes,
    pub duration: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Transcription {
    pub plain_lyrics: String,
    pub synced_lyrics: String,
    pub audio_sha256: String,
    pub duration: f64,
    pub model_id: String,
    pub language_code: Option<String>,
}
impl TranscriptionInput {
    pub fn new(audio: Bytes) -> Result<Self, Error> {
        Ok(Self {
            duration: pcm_duration(&audio)?,
            audio,
        })
    }
    pub fn transcribed(&self, value: &serde_json::Value) -> Result<Transcription, Error> {
        #[derive(Deserialize)]
        struct Word {
            text: String,
            start: f64,
            end: f64,
            #[serde(rename = "type")]
            kind: String,
        }
        #[derive(Deserialize)]
        struct Output {
            text: String,
            words: Vec<Word>,
            language_code: Option<String>,
        }
        let invalid = || Error::InvalidResponse(Provider::Elevenlabs);
        let out: Output = serde_json::from_value(value.clone()).map_err(|_| invalid())?;
        if out.text.len() > MAX_TEXT_BYTES
            || out.text.contains('\0')
            || out.language_code.as_ref().is_some_and(|s| {
                s.len() > 32 || !s.chars().all(|c| c.is_ascii_alphabetic() || c == '-')
            })
        {
            return Err(invalid());
        }
        let mut transcript = String::new();
        let mut words = Vec::new();
        let mut previous = 0.0;
        for word in out.words {
            if !word.start.is_finite()
                || !word.end.is_finite()
                || word.start < previous
                || word.start > self.duration
                || word.end < word.start
                || word.end > self.duration + 0.05
                || !matches!(word.kind.as_str(), "word" | "spacing" | "audio_event")
            {
                return Err(invalid());
            }
            previous = word.start;
            if word.kind != "word" {
                continue;
            }
            let token = normalized(&word.text);
            if !token.is_empty() {
                if word.end <= word.start {
                    return Err(invalid());
                }
                words.push((transcript.len(), word.start, word.end));
                transcript.push_str(&token);
            }
        }
        if transcript != normalized(&out.text) || (words.is_empty() && !out.text.trim().is_empty())
        {
            return Err(invalid());
        }
        // Map normalized word offsets back to the original UTF-8, preserving punctuation,
        // accents and languages that do not put spaces between words.
        let mut positions = std::collections::HashMap::new();
        let mut normalized_offset = 0;
        for (byte, character) in out.text.char_indices().filter(|(_, c)| c.is_alphanumeric()) {
            positions.insert(normalized_offset, byte);
            normalized_offset += character.to_lowercase().map(char::len_utf8).sum::<usize>();
        }
        let mut starts = Vec::new();
        if let Some(first) = words.first() {
            starts.push((0, first.1));
        }
        for pair in words.windows(2) {
            let (prior, next) = (pair[0], pair[1]);
            let prior_byte = *positions.get(&prior.0).ok_or_else(invalid)?;
            let next_byte = *positions.get(&next.0).ok_or_else(invalid)?;
            let between = &out.text[prior_byte..next_byte];
            let (line_byte, line_time) = *starts.last().ok_or_else(invalid)?;
            if between
                .trim_end()
                .ends_with(['.', '?', '!', '。', '？', '！'])
                || between.contains('\n')
                || next.1 - prior.2 >= 0.8
                || out.text[line_byte..next_byte].chars().count() >= 56
                || next.1 - line_time >= 6.0
            {
                starts.push((next_byte, next.1));
            }
        }
        let mut plain = Vec::new();
        let mut synced = Vec::new();
        for (index, &(byte, time)) in starts.iter().enumerate() {
            let end = starts.get(index + 1).map_or(out.text.len(), |s| s.0);
            let text = out.text[byte..end].trim();
            let ticks = (time * 100.0).floor() as u64;
            plain.push(text);
            synced.push(format!(
                "[{:02}:{:02}.{:02}]{}",
                ticks / 6000,
                ticks / 100 % 60,
                ticks % 100,
                text
            ));
        }
        Ok(Transcription {
            plain_lyrics: plain.join("\n"),
            synced_lyrics: synced.join("\n"),
            audio_sha256: digest(&self.audio),
            duration: self.duration,
            model_id: MODEL_ID.into(),
            language_code: out.language_code,
        })
    }
}

impl Client {
    pub async fn transcribe(
        &self,
        audio: Bytes,
        priority: Priority,
    ) -> Result<Reply<Transcription>, Error> {
        let input = TranscriptionInput::new(audio)?;
        if self
            .config()
            .provider(Provider::Elevenlabs)
            .api_key
            .is_none()
        {
            return Err(Error::NotConfigured(Provider::Elevenlabs));
        }
        let mut spec = self.request(Provider::Elevenlabs, "/v1/speech-to-text", &[])?;
        let source = spec.url.to_string();
        spec.audio_job = Some(AudioJob::Transcription(input));
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
