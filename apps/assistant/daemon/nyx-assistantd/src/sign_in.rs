//! A person confirms with the computer's own sign-in before the Assistant uses a secret.
//!
//! A key press approves a request, but any program running as the user can reach the
//! control socket and press it too. For secrets, the approval also has to pass Nyx
//! Biometrics' sign-in broker (`nyx-authd`): it knows the Assistant from its bus connection,
//! applies the `app-action` policy, shows the system prompt (face, fingerprint, security
//! key or password, as the computer is set up) and keeps an audit line. An older Nyx
//! Biometrics without the broker gets the same prompt from polkit directly. Where Nyx
//! Biometrics isn't installed, the key press stands on its own, as before.

use std::process::Command;

const ACTION: &str = "io.github.design_nexus.nyx.auth.app-action";
const ACTIONS: &str = "share/polkit-1/actions/io.github.design_nexus.nyx.auth.unlock.policy";
const PKCHECK: &str = "bin/pkcheck";

/// The system's own copy of a file: under /usr, or the system profile on NixOS. Both
/// belong to root; PATH isn't searched.
fn system_file(relative: &str) -> Option<std::path::PathBuf> {
    ["/usr", "/run/current-system/sw"].iter().map(|prefix| std::path::Path::new(prefix).join(relative)).find(|p| p.exists())
}

fn available() -> bool {
    system_file(ACTIONS).and_then(|p| std::fs::read_to_string(p).ok()).is_some_and(|t| t.contains(ACTION))
}

/// "pid,start-time,uid" for this process, so polkit can't be pointed at a reused pid.
fn subject() -> Option<String> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let start: u64 = stat[stat.rfind(')')? + 1..].split_whitespace().nth(19)?.parse().ok()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    Some(format!("{},{start},{uid}", std::process::id()))
}

/// Whether the person confirmed. Without Nyx Biometrics there's nothing more to ask.
pub(crate) async fn confirm() -> bool {
    if !available() {
        return true;
    }
    match broker().await {
        Ok(reply) => reply.outcome == nyx_auth_proto::Outcome::Granted,
        Err(_) => polkit().await,
    }
}

async fn broker() -> zbus::Result<nyx_auth_proto::Reply> {
    use nyx_auth_proto::{Request, Surface};
    let conn = zbus::Connection::session().await?;
    nyx_auth_proto::connect(&conn)
        .await?
        .authenticate(Request {
            action: "io.github.design_nexus.nyx.assistant.secrets".into(),
            purpose: "Let the Assistant use a saved password".into(),
            surface: Surface::AppAction,
            grant_secs: 0,
        })
        .await
}

/// Polkit lets only root pass a message of its own, so the dialog shows the action's
/// ("Confirm it's you to allow this"); the Assistant's approval already named the request.
async fn polkit() -> bool {
    let (Some(subject), Some(pkcheck)) = (subject(), system_file(PKCHECK)) else { return false };
    tokio::task::spawn_blocking(move || {
        Command::new(pkcheck)
            .args(["--action-id", ACTION, "--process", &subject, "--allow-user-interaction"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    })
    .await
    .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    #[test]
    fn subject_names_this_process() {
        let s = super::subject().unwrap();
        assert!(s.starts_with(&format!("{},", std::process::id())));
        assert_eq!(s.split(',').count(), 3);
    }
}
