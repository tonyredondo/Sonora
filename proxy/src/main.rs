use anyhow::{Context, Result};
use clap::Parser;
use sonora_proxy::{
    api,
    config::{Config, discover_config},
};
use std::path::PathBuf;

#[derive(Parser)]
#[command(version, about = "Sonora metadata, lyrics and artwork proxy")]
struct Arguments {
    /// TOML file; defaults to ~/.config/sonora-proxy/config.toml, then beside this binary.
    #[arg(long)]
    config: Option<PathBuf>,
    /// Validate configuration without opening the cache or connecting to providers.
    #[arg(long)]
    check_config: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let home = dirs::home_dir().context("home directory is unavailable")?;
    let executable = std::env::current_exe().context("executable path is unavailable")?;
    let path = discover_config(
        arguments.config.as_deref(),
        &home,
        executable
            .parent()
            .context("executable directory is unavailable")?,
    )?;
    let config = Config::load(&path)?;
    if arguments.check_config {
        println!("configuration valid");
        return Ok(());
    }
    // Restrict filtering to this crate: HTTP libraries can log query strings at debug level.
    tracing_subscriber::fmt()
        .with_env_filter("sonora_proxy=info")
        .with_target(false)
        .init();
    let address = config.server.listen;
    let app = api::router(config)?;
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .context("could not bind listener")?;
    tracing::info!(listen=%listener.local_addr()?,"Sonora proxy listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await
        .context("HTTP server failed")?;
    Ok(())
}
async fn shutdown() {
    #[cfg(unix)]
    {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut terminate) => {
                tokio::select! {_=tokio::signal::ctrl_c()=>{},_=terminate.recv()=>{}}
            }
            Err(_) => {
                let _ = tokio::signal::ctrl_c().await;
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
