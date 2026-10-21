//! Sonora's metadata and opt-in lyric alignment service. File access and tag writes stay on the device.

pub mod album_interpretation;
pub mod alignment;
pub mod api;
pub mod audio_character;
mod audio_job;
pub mod cache;
pub mod config;
mod diagnostics;
pub mod interpretation;
pub mod jobs;
pub mod metadata_archive;
pub mod providers;
mod scheduler;
pub mod transcription;
pub mod translation;
