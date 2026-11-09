//! The Assistant's audio: Nyx Voice's engine (PipeWire capture and playback, echo
//! cancelling, ducking, voice activity), linked into the daemon so barge-in and
//! listening while speaking keep their latency.

pub use nyx_voice_engine::{
    aec_barge_threshold, f32_24k_to_i16_16k, record_until, record_until_vad, AudioEngine, EnergyVad, PlayQueue, PlayedTo,
    Silero, SileroState, StreamingVad, VadDecision, VadGate, UNTAGGED,
};

/// Whose folders and PipeWire names the engine uses (`paths::set_app`).
pub use nyx_voice_engine::paths;
