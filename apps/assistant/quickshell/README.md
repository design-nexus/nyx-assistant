# Nyx Assistant HUD

Standalone Quickshell overlay. It does not go in `shell.json`.
`nyx-assistantd.service` starts the HUD and Parakeet speech services. Stopping
or restarting the daemon applies to both helpers; they do not start independently
at login. Do not also run `hud.sh` while the HUD unit is active.

```bash
systemctl --user status nyx-assistant-hud
# manual fallback if the unit is not enabled:
./scripts/hud.sh
```

`shell.qml` runs `nyx-assistant listen` and shows:

- Listening / Transcribing / Thinking / Executing / Speaking / Error
- capture level while listening
- transcript and assistant text
- Omarchy theme colors from `~/.local/state/omarchy/current/theme/colors.toml`
- Omarchy font (`monospace` alias + `[font] base-size` from shell.toml)

The HUD hides completely when the assistant is disabled or disconnected and reconnects automatically when it returns. The card hides 2.5 s after idle. Clicks pass through the overlay. While she is
busy, the overlay takes Exclusive keyboard focus so Escape cancels her without
a Hyprland bind. Idle: no grab, apps get Escape.

HUD enablement follows `settings.hud_enabled`; tool approvals show exact JSON arguments with Y/N controls and expiry. Installed assets are in `~/.local/share/nyx-assistant/quickshell`.


The HUD shows conversation/follow-up countdowns, dictation targets and retained drafts, and tool progress. Follow-up and dictation capture release keyboard focus so you can keep using the selected app. Approval prompts show exact arguments and accept Y/N or spoken approve/deny. Browser challenges can be handled with `nyx-assistant browser-takeover`, followed by `browser-resume`.

## Aura (`Aura/Main.qml`)

The Aura as a component of Nyx Shell's Quickshell runtime (`nyx-shell-qs`): on NyxOS with
Shell Core, on Omarchy with the runtime's standalone mode (`install.sh` links it into
`~/.local/share/nyx-shell/components` when the runtime is installed). A `presentation`
overlay that never takes input, hidden while the session is locked and on a screen with a
fullscreen window, on the screens `[ui] aura_monitors` or `aura_monitor_mode` name. It
draws as the GTK Aura does: Full Aura or Edge Flow (`[ui] aura_style`, or the voice
profile's), the state's colour from the theme's swatches tinted by the voice profile,
breathing and following the voice's level, faint while idle in a conversation
(`[ui] aura_visibility = "persistent"`), green for a finished reply, amber for an
approval, still under reduced motion. It reads the daemon's events from
`nyx-assistant listen` and draws only when `[ui] aura_renderer = "quickshell"`; with
`gtk` (the default) `nyx-assistant-visual` draws it, as before. Canvas stays in
`nyx-assistant-visual` either way.

States: `idle`, `activating` (waiting for Nyx AI Core to load the model), `listening`,
`transcribing`, `thinking`, `executing`, `speaking`, `error`, `unavailable` (Nyx AI Core
can't be reached); an approval waiting shows as attention.

Test on a virtual output: `NYX_AURA_TEST_STATE=listening NYX_AURA_TEST_STYLE=edge-flow`
fixes the state and style without the daemon.
