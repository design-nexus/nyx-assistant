//! The Assistant's language model, in Nyx AI Core (the suite's shared llama.cpp
//! runtime). AI Core loads, schedules and unloads the model; the Assistant keeps its
//! prompts, personas and conversations and sends each turn as an interactive request.
//! See nyx-ai's docs/ASSISTANT.md.
//!
//! The model is `[llm] model`: a GGUF file (its folder is offered to AI Core, which lists
//! it as a folder model, never changed), or `auto` for AI Core's `assistant` default
//! (then its `chat` default), as chosen in Nyx Settings › Local AI.

use anyhow::{anyhow, bail, Context, Result};
use assistant_core::config::Config;
use base64::Engine as _;
use nyx_ai_client::proto::{
    self, Capability, ChatRequest, Content, ErrorKind, Event, ImageUrl, Message, Part, Priority, Reply, Role, Sampling,
};
use nyx_ai_client::{Client, Item};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Mutex};

/// The Assistant's model in AI Core. The name is the old runner's, so callers read the same.
pub type LlamaCppBackend = LanguageModel;

pub struct LanguageModel {
    client: Client,
    /// `[llm] model` as configured: a file, or empty for AI Core's default.
    file: Option<PathBuf>,
    ctx: u32,
    /// AI Core's id for the model, once found.
    id: Mutex<Option<(String, bool)>>,
    loaded: Arc<AtomicBool>,
    battery: AtomicBool,
    mmproj: Option<PathBuf>,
}

/// What AI Core's errors mean for someone talking to the Assistant.
fn explain(e: proto::Error) -> anyhow::Error {
    match e.kind {
        ErrorKind::Unavailable => anyhow!("Nyx AI Core isn't running, so I can't think right now"),
        ErrorKind::UnknownModel => anyhow!("my language model isn't in Nyx AI Core: {}", e.message),
        ErrorKind::ModelLoadFailed => anyhow!("my language model couldn't load: {}", e.message),
        ErrorKind::WorkerUnavailable | ErrorKind::WorkerFailed => anyhow!("Nyx AI Core's model runner is restarting"),
        _ => anyhow!("{}", e.message),
    }
}

impl LanguageModel {
    pub fn spawn(cfg: &Config) -> Result<Self> {
        Self::spawn_with_battery(cfg, false)
    }

    /// Nothing loads yet: AI Core loads the model for the first turn.
    pub fn spawn_with_battery(cfg: &Config, battery_mode: bool) -> Result<Self> {
        let configured = cfg.llm.model.trim();
        let file = (!configured.is_empty() && configured != "auto").then(|| cfg.resolve_model_path());
        if let Some(f) = &file {
            if !f.is_file() {
                bail!("GGUF not found at {}. Set [llm].model to a local .gguf path, or to auto for Nyx AI Core's default.", f.display());
            }
        }
        let mmproj = file.as_deref().and_then(|f| cfg.vision.resolve(f));
        Ok(Self {
            client: Client::new("nyx-assistant"),
            file,
            ctx: cfg.llm.ctx,
            id: Mutex::new(None),
            loaded: Arc::new(AtomicBool::new(false)),
            battery: AtomicBool::new(battery_mode),
            mmproj,
        })
    }

    /// AI Core's id for the model, and whether it sees images.
    async fn model(&self) -> Result<(String, bool)> {
        let mut slot = self.id.lock().await;
        if let Some(found) = slot.as_ref() {
            return Ok(found.clone());
        }
        let found = match &self.file {
            Some(file) => {
                let want = std::fs::canonicalize(file).unwrap_or_else(|_| file.clone());
                let find = |models: &[proto::Model]| {
                    models
                        .iter()
                        .find(|m| m.path.as_deref().map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p))) == Some(want.clone()))
                        .map(|m| (m.id.clone(), m.has(Capability::Vision)))
                };
                let models = self.client.list_models().await.map_err(explain)?;
                match find(&models) {
                    Some(f) => f,
                    None => {
                        let dir = file.parent().context("the model file has no folder")?.display().to_string();
                        self.client.add_model_dirs(vec![dir]).await.map_err(explain)?;
                        let models = self.client.list_models().await.map_err(explain)?;
                        find(&models).ok_or_else(|| anyhow!("Nyx AI Core doesn't list {}", file.display()))?
                    }
                }
            }
            None => {
                let s = self.client.service_settings().await.map_err(explain)?;
                let id = s.defaults.get("assistant").or_else(|| s.defaults.get("chat")).cloned().ok_or_else(|| {
                    anyhow!("no model chosen: set [llm].model, or the Assistant's model in Nyx Settings › Local AI")
                })?;
                let info = self.client.model_info(&id).await.map_err(explain)?;
                (id, info.model.has(Capability::Vision))
            }
        };
        self.configure(&found.0).await;
        *slot = Some(found.clone());
        Ok(found)
    }

    /// The context length `[llm] ctx` asks for, where AI Core's differs. Untrusted on
    /// this computer it can't set it; AI Core's own then stands.
    async fn configure(&self, id: &str) {
        let Ok(current) = self.client.model_settings(id).await else { return };
        let ctx = self.ctx.to_string();
        if self.ctx > 0 && current.effective.get("ctx-size") != Some(&ctx) {
            if let Err(e) = self.client.configure_model(id, [("ctx-size".to_string(), ctx)].into()).await {
                tracing::warn!("couldn't set the model's context in Nyx AI Core: {}", e.message);
            }
        }
    }

    /// Whether the model sees images (a projector loads with it in AI Core).
    pub fn vision_loaded(&self) -> bool {
        self.loaded.load(Ordering::Relaxed) && self.id.try_lock().ok().and_then(|s| s.as_ref().map(|(_, v)| *v)).unwrap_or(false)
    }

    /// The projector next to a configured model file, for status.
    pub fn vision_model(&self) -> Option<&std::path::Path> {
        self.mmproj.as_deref()
    }

    /// The configured model file, or `nyx-ai:assistant` for AI Core's default.
    pub fn model_path(&self) -> &std::path::Path {
        self.file.as_deref().unwrap_or(std::path::Path::new("nyx-ai:assistant"))
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.load(Ordering::Relaxed)
    }

    pub fn is_battery(&self) -> bool {
        self.battery.load(Ordering::Relaxed)
    }

    /// Let AI Core unload the model when nothing else uses it.
    pub async fn unload(&self) -> Result<()> {
        if let Some((id, _)) = self.id.lock().await.as_ref() {
            self.client.unload_model(id).await.map_err(explain)?;
        }
        self.loaded.store(false, Ordering::Relaxed);
        Ok(())
    }

    /// Keep the model loaded for the Assistant (a voice conversation), or let it go.
    pub async fn keep(&self, on: bool) -> Result<()> {
        let (id, _) = self.model().await?;
        if on {
            self.client.load_model(&id, true).await.map_err(explain)?;
            self.loaded.store(true, Ordering::Relaxed);
        } else {
            self.client.unload_model(&id).await.map_err(explain)?;
        }
        Ok(())
    }

    /// On battery the Assistant answers more briefly; AI Core's battery saver decides
    /// where models run.
    pub async fn set_battery(&self, battery: bool) -> Result<()> {
        self.battery.store(battery, Ordering::Relaxed);
        Ok(())
    }

    fn sampling(&self, n_predict: i32, temperature: f32) -> Sampling {
        let mut limit = n_predict.max(1) as u32;
        if self.is_battery() {
            limit = limit.min(256);
        }
        Sampling { temperature: Some(temperature as f64), max_tokens: Some(limit), ..Default::default() }
    }

    pub async fn generate(
        &self,
        system: &str,
        history: &[(String, String)],
        user: &str,
        n_predict: i32,
        temperature: f32,
        cancel: Arc<AtomicBool>,
    ) -> Result<mpsc::Receiver<Result<String>>> {
        self.generate_with_grammar(system, history, user, n_predict, temperature, cancel, None).await
    }

    /// Stream a reply. `history` is (user, assistant) pairs; `grammar` is GBNF.
    #[allow(clippy::too_many_arguments)]
    pub async fn generate_with_grammar(
        &self,
        system: &str,
        history: &[(String, String)],
        user: &str,
        n_predict: i32,
        temperature: f32,
        cancel: Arc<AtomicBool>,
        grammar: Option<String>,
    ) -> Result<mpsc::Receiver<Result<String>>> {
        let (id, _) = self.model().await?;
        let mut messages = Vec::with_capacity(history.len() * 2 + 2);
        if !system.is_empty() {
            messages.push(Message::text(Role::System, system));
        }
        for (u, a) in history {
            messages.push(Message::text(Role::User, u));
            messages.push(Message::text(Role::Assistant, a));
        }
        messages.push(Message::text(Role::User, user));
        let request = ChatRequest {
            model: id,
            messages,
            grammar,
            sampling: self.sampling(n_predict, temperature),
            thinking: Some(false),
            priority: Priority::Interactive,
            ..Default::default()
        };
        self.stream(request, cancel).await
    }

    async fn stream(&self, request: ChatRequest, cancel: Arc<AtomicBool>) -> Result<mpsc::Receiver<Result<String>>> {
        let mut stream = self.client.chat(request).await.map_err(explain)?;
        let (tx, rx) = mpsc::channel(64);
        let loaded = self.loaded.clone();
        tokio::spawn(async move {
            loop {
                if cancel.load(Ordering::Relaxed) {
                    let _ = stream.cancel().await;
                    break;
                }
                let item = tokio::select! {
                    item = stream.next() => item,
                    _ = tokio::time::sleep(Duration::from_millis(50)) => continue,
                };
                match item {
                    None => break,
                    Some(Ok(Item::Event(Event::Started))) => loaded.store(true, Ordering::Relaxed),
                    Some(Ok(Item::Event(Event::Delta { content, .. }))) if !content.is_empty() => {
                        loaded.store(true, Ordering::Relaxed);
                        if tx.send(Ok(content)).await.is_err() {
                            let _ = stream.cancel().await;
                            break;
                        }
                    }
                    Some(Ok(Item::Event(_))) => {}
                    Some(Ok(Item::Done(Reply::Finished(_)))) => break,
                    Some(Ok(Item::Done(_))) => break,
                    Some(Err(e)) if e.kind == ErrorKind::Cancelled => break,
                    Some(Err(e)) => {
                        let _ = tx.send(Err(explain(e))).await;
                        break;
                    }
                }
            }
        });
        Ok(rx)
    }

    /// Answer `prompt` about a PNG, with a model that sees images.
    pub async fn look(&self, image: Vec<u8>, prompt: &str, n_predict: i32) -> Result<String> {
        let (id, vision) = self.model().await?;
        anyhow::ensure!(vision, "my language model can't see images; choose one with vision in Nyx Settings › Local AI");
        let url = format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(&image));
        let message = Message {
            role: Role::User,
            content: Content::Parts(vec![Part::ImageUrl { image_url: ImageUrl { url } }, Part::Text { text: prompt.into() }]),
            tool_calls: Vec::new(),
            tool_call_id: None,
        };
        let request = ChatRequest {
            model: id,
            messages: vec![message],
            sampling: self.sampling(n_predict, 0.2),
            thinking: Some(false),
            priority: Priority::Interactive,
            ..Default::default()
        };
        let out = self.client.chat(request).await.map_err(explain)?.collect_chat().await.map_err(explain)?;
        self.loaded.store(true, Ordering::Relaxed);
        Ok(out.content.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_means_ai_core_s_default() {
        let mut cfg = Config::default();
        cfg.llm.model = "auto".into();
        let m = LanguageModel::spawn(&cfg).unwrap();
        assert_eq!(m.model_path(), std::path::Path::new("nyx-ai:assistant"));
        cfg.llm.model = "/no/such/model.gguf".into();
        assert!(LanguageModel::spawn(&cfg).is_err());
    }

    #[test]
    fn battery_answers_are_shorter() {
        let m = LanguageModel::spawn_with_battery(&Config::default(), true).unwrap();
        assert_eq!(m.sampling(768, 0.7).max_tokens, Some(256));
        let m = LanguageModel::spawn_with_battery(&Config::default(), false).unwrap();
        assert_eq!(m.sampling(768, 0.7).max_tokens, Some(768));
    }
}
