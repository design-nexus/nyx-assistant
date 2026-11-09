mod app;
mod planner;
mod session;

use anyhow::Context;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    // The speech engine keeps the Assistant's folders and PipeWire names.
    assistant_audio::paths::set_app("nyx-assistant", "Assistant");
    let cfg = assistant_core::Config::load().context("load config")?;
    tracing::info!(name = %cfg.assistant.name, "starting nyx-assistantd");
    app::run(cfg).await
}
