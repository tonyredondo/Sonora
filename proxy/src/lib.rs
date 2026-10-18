//! Sonora's metadata and opt-in lyric alignment service. File access and tag writes stay on the device.

pub mod alignment;
pub mod api;
pub mod cache;
pub mod config;
pub mod jobs;
pub mod providers;
mod scheduler;
