//! A person confirms with the computer's own sign-in before the Assistant uses a secret.
//!
//! A key press approves a request, but any program running as the user can reach the
//! control socket and press it too. For secrets, the approval also has to pass a polkit
//! "authenticate as yourself" check (Nyx Biometrics' `app-action`), which shows on screen
//! and takes the face, fingerprint, security key or password the computer is set up for.
//! Where Nyx Biometrics isn't installed, the key press stands on its own, as before.

use std::process::Command;

const ACTION: &str = "io.github.design_nexus.nyx.auth.app-action";
const ACTIONS: &str = "/usr/share/polkit-1/actions/io.github.design_nexus.nyx.auth.unlock.policy";
const PKCHECK: &str = "/usr/bin/pkcheck";

fn available() -> bool {
    std::fs::read_to_string(ACTIONS).is_ok_and(|t| t.contains(ACTION))
}

/// "pid,start-time,uid" for this process, so polkit can't be pointed at a reused pid.
fn subject() -> Option<String> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let start: u64 = stat[stat.rfind(')')? + 1..].split_whitespace().nth(19)?.parse().ok()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    Some(format!("{},{start},{uid}", std::process::id()))
}

/// One short, plain line for the system prompt.
fn message(summary: &str) -> String {
    let clean: String = summary.chars().filter(|c| !c.is_control()).take(100).collect();
    format!("Allow the Assistant to {}", clean.trim())
}

/// Whether the person confirmed. Without Nyx Biometrics there's nothing more to ask.
pub(crate) async fn confirm(summary: &str) -> bool {
    if !available() {
        return true;
    }
    let Some(subject) = subject() else { return false };
    let msg = message(summary);
    tokio::task::spawn_blocking(move || {
        Command::new(PKCHECK)
            .args(["--action-id", ACTION, "--process", &subject, "--allow-user-interaction", "--detail", "polkit.message", &msg])
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
    fn messages_are_one_short_line() {
        assert_eq!(super::message("copy the password for github.com"), "Allow the Assistant to copy the password for github.com");
        let long = super::message(&format!("{}\nINJECTED", "x".repeat(200)));
        assert!(!long.contains('\n'));
        assert!(long.len() <= 130);
    }

    #[test]
    fn subject_names_this_process() {
        let s = super::subject().unwrap();
        assert!(s.starts_with(&format!("{},", std::process::id())));
        assert_eq!(s.split(',').count(), 3);
    }
}
