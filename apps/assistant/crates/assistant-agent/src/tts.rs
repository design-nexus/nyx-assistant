//! Speech: Nyx Voice's Kokoro (and Chatterbox for a persona's cloned voice).
pub use nyx_voice_engine::tts::KokoroProvider;

use assistant_core::config::Config;

/// The reference recording of the persona's cloned voice, when it has one and no voice
/// override is set.
pub fn clone_reference(cfg: &Config) -> Option<std::path::PathBuf> {
    if !cfg.tts.voice_override.is_empty() || cfg.assistant.persona_id.is_empty() {
        return None;
    }
    assistant_core::VoiceProfile::load(&cfg.assistant.persona_id)
        .ok()
        .flatten()
        .filter(|profile| profile.provider == "chatterbox")
        .and_then(|profile| profile.reference_audio)
}
