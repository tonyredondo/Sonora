//! Sonora's read-only enrichment service. File access and tag writes stay on the device.

pub mod api;
pub mod cache;
pub mod config;
pub mod jobs;
pub mod providers;
mod scheduler;
