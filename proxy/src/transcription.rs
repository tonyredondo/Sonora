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
    /// Older cached analyses contain phrase timing only and remain reusable.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub words: Vec<TranscriptionWord>,
}

/// Validated provider words retained for reviewing individual lyric repairs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TranscriptionWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
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
        let out: Output = serde_json::from_value(value.clone()).map_err(|error| {
            tracing::warn!(validation_reason = "transcription_schema", category = ?error.classify(), has_text = value.get("text").is_some(), has_words = value.get("words").is_some(), "audio analysis rejected");
            invalid()
        })?;
        if out.text.len() > MAX_TEXT_BYTES
            || out.text.contains('\0')
            || contains_lrc_control(&out.text)
            || out.language_code.as_ref().is_some_and(|s| {
                s.len() > 32 || !s.chars().all(|c| c.is_ascii_alphabetic() || c == '-')
            })
        {
            tracing::warn!(
                validation_reason = "transcription_metadata",
                text_bytes = out.text.len(),
                has_nul = out.text.contains('\0'),
                has_lrc_control = contains_lrc_control(&out.text),
                "audio analysis rejected"
            );
            return Err(invalid());
        }
        let mut transcript = String::new();
        let mut words = Vec::new();
        let mut previous = 0.0;
        for (index, word) in out.words.iter().enumerate() {
            if !word.start.is_finite()
                || !word.end.is_finite()
                || word.start < previous
                || word.start > self.duration
                || word.end < word.start
                || word.end > self.duration + 0.05
                || !matches!(word.kind.as_str(), "word" | "spacing" | "audio_event")
            {
                tracing::warn!(
                    validation_reason = "transcription_word_timing",
                    word_index = index,
                    start = word.start,
                    end = word.end,
                    previous_start = previous,
                    duration = self.duration,
                    valid_kind = matches!(word.kind.as_str(), "word" | "spacing" | "audio_event"),
                    "audio analysis rejected"
                );
                return Err(invalid());
            }
            previous = word.start;
            if word.kind != "word" {
                continue;
            }
            let token = normalized(&word.text);
            if !token.is_empty() {
                if word.end <= word.start {
                    tracing::warn!(
                        validation_reason = "transcription_word_duration",
                        word_index = index,
                        start = word.start,
                        end = word.end,
                        "audio analysis rejected"
                    );
                    return Err(invalid());
                }
                let prefix_end = word.text.find(char::is_alphanumeric).ok_or_else(invalid)?;
                words.push((
                    transcript.len(),
                    word.start,
                    word.end,
                    &word.text[..prefix_end],
                ));
                transcript.push_str(&token);
            }
        }
        if transcript != normalized(&out.text) || (words.is_empty() && !out.text.trim().is_empty())
        {
            tracing::warn!(
                validation_reason = "transcription_word_text_mismatch",
                words = words.len(),
                normalized_word_bytes = transcript.len(),
                normalized_text_bytes = normalized(&out.text).len(),
                "audio analysis rejected"
            );
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
            let next_content_byte = *positions.get(&next.0).ok_or_else(invalid)?;
            // Leading quotes belong to their provider word, rather than the
            // previous phrase. Only move a prefix that matches the original text.
            let next_byte = out.text[..next_content_byte]
                .strip_suffix(next.3)
                .map_or(next_content_byte, str::len);
            let between = &out.text[prior_byte..next_byte];
            let (line_byte, line_time) = *starts.last().ok_or_else(invalid)?;
            if between
                .trim_end_matches(|c: char| {
                    c.is_whitespace()
                        || matches!(
                            c,
                            '"' | '\''
                                | '”'
                                | '’'
                                | '»'
                                | '›'
                                | '」'
                                | '』'
                                | ')'
                                | '）'
                                | ']'
                                | '}'
                        )
                })
                .ends_with(['.', '?', '!', '。', '？', '！'])
                || out.text[prior_byte..next_content_byte].contains(is_line_break)
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
            // A provider word can itself contain a paragraph break. Keep its known
            // time and flatten that internal break rather than emitting an untimed line.
            let text: String = out.text[byte..end]
                .trim()
                .chars()
                .map(|c| if is_line_break(c) { ' ' } else { c })
                .collect();
            let ticks = (time * 100.0).floor() as u64;
            synced.push(format!(
                "[{:02}:{:02}.{:02}]{}",
                ticks / 6000,
                ticks / 100 % 60,
                ticks % 100,
                text
            ));
            plain.push(text);
        }
        let plain_lyrics = plain.join("\n");
        // Phrase separators can grow the transcript beyond the raw provider text.
        // Never cache a derived result that the iPhone cannot accept.
        if plain_lyrics.len() > MAX_TEXT_BYTES {
            tracing::warn!(
                validation_reason = "transcription_derived_text_limit",
                text_bytes = plain_lyrics.len(),
                "audio analysis rejected"
            );
            return Err(invalid());
        }
        Ok(Transcription {
            plain_lyrics,
            synced_lyrics: synced.join("\n"),
            audio_sha256: digest(&self.audio),
            duration: self.duration,
            model_id: MODEL_ID.into(),
            language_code: out.language_code,
            words: out
                .words
                .into_iter()
                .filter(|word| word.kind == "word" && !normalized(&word.text).is_empty())
                .map(|word| TranscriptionWord {
                    text: word.text,
                    start: word.start,
                    end: word.end,
                })
                .collect(),
        })
    }
}

// Match Foundation's newline characters: these delimit lyric lines on the iPhone.
fn is_line_break(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

// Literal LRC timing/offset tags in a transcript would be interpreted as controls
// by the reader. Reject them before the derived result becomes an immutable cache hit.
fn contains_lrc_control(text: &str) -> bool {
    let digits = |s: &str| !s.is_empty() && s.chars().all(char::is_numeric);
    let mut start = None;
    for (byte, c) in text.char_indices() {
        if c == '[' {
            start = Some(byte + 1);
        } else if c == ']' {
            let Some(begin) = start.take() else { continue };
            let Some((prefix, value)) = text[begin..byte].split_once(':') else {
                continue;
            };
            // Foundation's case-insensitive offset regex also folds long s and
            // ligatures. Expand Unicode uppercase mappings to match that behavior.
            if prefix
                .chars()
                .flat_map(char::to_uppercase)
                .eq("OFFSET".chars())
            {
                if digits(value.strip_prefix(['+', '-']).unwrap_or(value)) {
                    return true;
                }
                continue;
            }
            let (seconds, fraction) = value
                .split_once(['.', ':'])
                .map_or((value, None), |(s, f)| (s, Some(f)));
            if prefix.chars().count() <= 3
                && digits(prefix)
                && seconds.chars().count() == 2
                && digits(seconds)
                && fraction.is_none_or(|f| f.chars().count() <= 3 && digits(f))
            {
                return true;
            }
        }
    }
    false
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

#[cfg(test)]
mod review_tests {
    use super::*;
    #[test]
    fn derived_transcription_retains_word_times_for_cached_lyric_repairs() {
        let words = serde_json::json!([
            {"text":"Hello","type":"word","start":0.1,"end":0.5},
            {"text":"again","type":"word","start":1.1,"end":1.5}
        ]);
        let result = input()
            .transcribed(&serde_json::json!({"text":"Hello again", "words":words}))
            .unwrap();
        let cached = serde_json::to_value(result).unwrap();
        assert_eq!(
            cached["words"],
            serde_json::json!([
                {"text":"Hello","start":0.1,"end":0.5},
                {"text":"again","start":1.1,"end":1.5}
            ])
        );
    }
    fn input() -> TranscriptionInput {
        TranscriptionInput {
            audio: Bytes::new(),
            duration: 2.0,
        }
    }
    #[test]
    fn all_line_separators_produce_complete_lrc_lines() {
        for separator in [
            "\n", "\r", "\r\n", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}",
        ] {
            let value = serde_json::json!({"text":format!("Hello{separator}Again"), "words":[
                {"text":"Hello","type":"word","start":0.1,"end":0.5},
                {"text":"Again","type":"word","start":1.1,"end":1.5}]});
            let result = input().transcribed(&value).unwrap();
            assert_eq!(
                result.synced_lyrics, "[00:00.10]Hello\n[00:01.10]Again",
                "{separator:?}"
            );
        }
        let result = input()
            .transcribed(&serde_json::json!({"text":"Hello\nAgain", "words":[
                {"text":"Hello","type":"word","start":0.1,"end":0.5},
                {"text":"\nAgain","type":"word","start":0.6,"end":1.0}]}))
            .unwrap();
        assert_eq!(result.synced_lyrics, "[00:00.10]Hello\n[00:00.60]Again");
    }
    #[test]
    fn line_breaks_inside_a_provider_word_cannot_create_untimed_lines() {
        let result = input()
            .transcribed(&serde_json::json!({"text":"Hello\nAgain", "words":[
            {"text":"Hello\nAgain","type":"word","start":0.1,"end":1.5}]}))
            .unwrap();
        assert_eq!(result.synced_lyrics, "[00:00.10]Hello Again");
    }
    #[test]
    fn phrase_grouping_cannot_exceed_the_client_text_limit() {
        // Valid source text below the limit grows when CJK sentences gain newlines.
        let count = MAX_TEXT_BYTES / "啊。".len();
        let text = "啊。".repeat(count);
        assert!(text.len() <= MAX_TEXT_BYTES);
        let words: Vec<_> = (0..count)
            .map(|i| {
                serde_json::json!({
                    "text":"啊。", "type":"word", "start":i as f64 * 0.05,
                    "end":i as f64 * 0.05 + 0.025
                })
            })
            .collect();
        let input = TranscriptionInput {
            audio: Bytes::new(),
            duration: 600.0,
        };
        assert!(
            input
                .transcribed(&serde_json::json!({"text":text,"words":words}))
                .is_err()
        );
    }
    #[test]
    fn quotation_marks_stay_with_their_phrase_and_do_not_hide_sentence_endings() {
        for (text, first, second) in [
            ("Hello. “Again!”", "Hello.", "“Again!”"),
            ("“Hello!” Again.", "“Hello!”", "Again."),
            ("你好。「世界！」", "你好。", "「世界！」"),
        ] {
            let result = input()
                .transcribed(&serde_json::json!({"text":text,"words":[
                {"text":first,"type":"word","start":0.1,"end":0.5},
                {"text":second,"type":"word","start":0.6,"end":1.0}]}))
                .unwrap();
            assert_eq!(
                result.synced_lyrics,
                format!("[00:00.10]{first}\n[00:00.60]{second}")
            );
        }
    }
    #[test]
    fn provider_text_cannot_inject_lrc_timestamps_or_global_offsets() {
        for text in [
            "Hello [00:01] Again",
            "Hello [99:90] Again",
            "Hello [٠٠:٠١] Again",
            "Hello [offset:-3000] Again",
            "Hello [offſet:-3000] Again",
            "Hello [oﬀset:-3000] Again",
            "Hello [oﬀſet:-3000] Again",
        ] {
            assert!(
                input()
                    .transcribed(&serde_json::json!({"text":text,"words":[
                {"text":text,"type":"word","start":0.1,"end":1.5}]}))
                    .is_err(),
                "accepted LRC control in {text:?}"
            );
        }
    }
    #[test]
    fn bracketed_lyrics_without_lrc_controls_are_preserved() {
        let text = "Hello [Chorus] [off-set:-3000] Again";
        let result = input()
            .transcribed(&serde_json::json!({"text":text,"words":[
            {"text":text,"type":"word","start":0.1,"end":1.5}]}))
            .unwrap();
        assert_eq!(
            result.synced_lyrics,
            "[00:00.10]Hello [Chorus] [off-set:-3000] Again"
        );
    }
}
