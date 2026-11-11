pub mod hypr;

use anyhow::{Context, Result};
use tokio::process::Command;

pub async fn hyprctl(args: &[&str]) -> Result<String> {
    let out = Command::new("hyprctl")
        .args(args)
        .output()
        .await
        .context("hyprctl")?;
    if !out.status.success() {
        anyhow::bail!(
            "hyprctl {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Whether `program` is on PATH.
pub fn on_path(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| std::env::split_paths(&path).any(|d| d.join(program).is_file()))
}

/// The terminal launcher to use: `wanted` (Omarchy's `omarchy-launch-terminal` by
/// default) where it's installed, else the default terminal, `xdg-terminal-exec` (NyxOS).
pub fn terminal(wanted: &str) -> String {
    let wanted = wanted.trim();
    let wanted = if wanted.is_empty() { "omarchy-launch-terminal" } else { wanted };
    if on_path(wanted) || !wanted.starts_with("omarchy-") { wanted.to_string() } else { "xdg-terminal-exec".to_string() }
}

/// What an `omarchy …` command does where Omarchy isn't installed (NyxOS), with the
/// system's own tools: `Some((argv, in the session))`, or None where there's nothing
/// like it.
fn without_omarchy(args: &[&str]) -> Option<(Vec<&'static str>, bool)> {
    const DND: [&str; 7] = ["busctl", "--user", "call", "io.github.design_nexus.nyx.Notifications", "/io/github/design_nexus/nyx/Notifications", "io.github.design_nexus.nyx.Notifications1", "ToggleDnd"];
    let joined = args.join(" ");
    Some(match joined.as_str() {
        "system lock" => (vec!["loginctl", "lock-session"], false),
        "audio output volume raise" => (vec!["wpctl", "set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", "5%+"], false),
        "audio output volume lower" => (vec!["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"], false),
        "audio output volume mute-toggle" => (vec!["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"], false),
        "capture screenshot" | "capture screenshot region" | "capture screenshot windows" | "capture screenshot fullscreen" => (vec!["nyx-capture", "--capture"], true),
        "capture screenrecording --fullscreen" => (vec!["nyx-capture", "--record"], true),
        "capture screenrecording --stop-recording" => (vec!["nyx-capture", "--record", "--stop"], true),
        "brightness display +10%" => (vec!["brightnessctl", "set", "10%+"], false),
        "brightness display 10%-" => (vec!["brightnessctl", "set", "10%-"], false),
        "brightness keyboard up" => (vec!["brightnessctl", "-d", "*::kbd_backlight", "set", "10%+"], false),
        "brightness keyboard down" => (vec!["brightnessctl", "-d", "*::kbd_backlight", "set", "10%-"], false),
        "bluetooth power toggle" => (vec!["sh", "-c", "if bluetoothctl show | grep -q 'Powered: yes'; then bluetoothctl power off; else bluetoothctl power on; fi"], false),
        "toggle notification silencing" => (DND.to_vec(), false),
        "menu toggle root" | "menu toggle apps" => (vec!["nyx-glimpse", "--toggle"], true),
        "menu clipboard" => (vec!["nyx-clipboard"], true),
        "launch terminal" => (vec!["xdg-terminal-exec"], true),
        _ => return None,
    })
}

pub async fn omarchy(args: &[&str]) -> Result<String> {
    if args.first() == Some(&"exec") {
        let cmd = shell_join(&args[1..]);
        tracing::info!("exec via hypr");
        return hypr_exec(&cmd).await;
    }
    if !on_path("omarchy") {
        let Some((argv, session)) = without_omarchy(args) else {
            anyhow::bail!("“{}” is Omarchy's, and this system doesn't have it", args.join(" "));
        };
        if session {
            return hypr_exec(&format!("uwsm app -- {}", shell_join(&argv))).await;
        }
        let out = Command::new(argv[0]).args(&argv[1..]).output().await.with_context(|| argv[0].to_string())?;
        if !out.status.success() {
            anyhow::bail!("{} failed: {}", argv.join(" "), String::from_utf8_lossy(&out.stderr));
        }
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    if should_hypr_exec(args) {
        let cmd = format!("omarchy {}", shell_join(args));
        tracing::info!("omarchy via hypr exec");
        return hypr_exec(&cmd).await;
    }
    let out = Command::new("omarchy")
        .args(args)
        .output()
        .await
        .context("omarchy")?;
    if !out.status.success() {
        anyhow::bail!(
            "omarchy {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn should_hypr_exec(args: &[&str]) -> bool {
    matches!(
        args.first().copied(),
        Some("launch") | Some("capture") | Some("menu")
    ) || matches!(args, ["theme", "switcher", ..])
}

/// Run a command through Hyprland so GUI apps belong to the compositor, not the assistant.
pub async fn hypr_exec(cmd: &str) -> Result<String> {
    // Lua decimal escapes are unambiguous for arbitrary UTF-8 and control bytes.
    let escaped: String = cmd.bytes().map(|b| format!("\\{b:03}")).collect();
    let lua = format!(r#"hl.dispatch(hl.dsp.exec_cmd("{escaped}"))"#);
    hyprctl(&["eval", &lua]).await
}

/// Force the default capture source unmuted so a voice "mute mic" cannot brick the assistant.
pub async fn unmute_default_source() -> Result<()> {
    let out = Command::new("wpctl")
        .args(["set-mute", "@DEFAULT_AUDIO_SOURCE@", "0"])
        .output()
        .await
        .context("wpctl set-mute")?;
    if !out.status.success() {
        anyhow::bail!(
            "unmute mic failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
pub fn shell_join(args: &[&str]) -> String {
    args.iter()
        .map(|arg| shell_quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gui_commands_use_hypr_exec() {
        assert!(should_hypr_exec(&["launch", "terminal"]));
        assert!(should_hypr_exec(&["launch", "browser"]));
        assert!(should_hypr_exec(&["launch", "nautilus"]));
        assert!(should_hypr_exec(&["capture", "screenshot"]));
        assert!(should_hypr_exec(&["theme", "switcher"]));
        assert!(should_hypr_exec(&["menu", "toggle", "root"]));
        assert!(!should_hypr_exec(&["exec", "obsidian"]));
        assert!(!should_hypr_exec(&["system", "lock"]));
        assert!(!should_hypr_exec(&["audio", "output", "volume", "raise"]));
    }
}
