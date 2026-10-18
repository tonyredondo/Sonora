//! Shared scheduling and immutable cache identities for opt-in paid audio work.
use crate::{
    alignment::{AlignmentInput, MAX_AUDIO_BYTES, digest},
    config::Provider,
    providers::Error,
    transcription::{MODEL_ID, TranscriptionInput},
};
use bytes::Bytes;
use sha2::{Digest, Sha256};

#[derive(Clone)]
pub(crate) enum AudioJob {
    Alignment(AlignmentInput),
    Transcription(TranscriptionInput),
}
impl AudioJob {
    pub fn update_key(&self, hash: &mut Sha256) {
        match self {
            Self::Alignment(input) => {
                // Retain the existing alignment key so previous analyses remain reusable.
                hash.update(b"\0alignment-v1\0");
                hash.update(digest(&input.audio));
                hash.update(digest(input.text.as_bytes()));
            }
            Self::Transcription(input) => {
                hash.update(b"\0transcription-lines-v2\0");
                hash.update(MODEL_ID);
                hash.update(b"\0word\0no-events\0no-diarization\0");
                hash.update(digest(&input.audio));
            }
        }
    }
    pub fn form(&self) -> Result<reqwest::multipart::Form, Error> {
        let audio = match self {
            Self::Alignment(input) => &input.audio,
            Self::Transcription(input) => &input.audio,
        };
        let part = reqwest::multipart::Part::bytes(audio.to_vec())
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|_| Error::Configuration)?;
        let form = reqwest::multipart::Form::new().part("file", part);
        Ok(match self {
            Self::Alignment(input) => form.text("text", input.text.clone()),
            Self::Transcription(_) => form
                .text("model_id", MODEL_ID)
                .text("timestamps_granularity", "word")
                .text("tag_audio_events", "false")
                .text("diarize", "false"),
        })
    }
    pub fn derive(&self, value: &serde_json::Value) -> Result<Bytes, Error> {
        let result = match self {
            Self::Alignment(input) => serde_json::to_vec(&input.aligned(value)?),
            Self::Transcription(input) => serde_json::to_vec(&input.transcribed(value)?),
        };
        result
            .map(Bytes::from)
            .map_err(|_| Error::InvalidResponse(Provider::Elevenlabs))
    }
}

pub(crate) fn pcm_duration(audio: &[u8]) -> Result<f64, Error> {
    let bad = || Error::InvalidInput("audio must be a 1-600 second mono 16 kHz PCM16 WAV");
    if audio.len() < 44
        || audio.len() > MAX_AUDIO_BYTES
        || &audio[..4] != b"RIFF"
        || &audio[8..16] != b"WAVEfmt "
        || audio[16..36]
            != [
                16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0,
            ]
        || &audio[36..40] != b"data"
    {
        return Err(bad());
    }
    let size = audio.len() - 44;
    if size < 32000
        || size % 2 != 0
        || audio[4..8] != ((size + 36) as u32).to_le_bytes()
        || audio[40..44] != (size as u32).to_le_bytes()
    {
        return Err(bad());
    }
    Ok(size as f64 / 32000.0)
}
