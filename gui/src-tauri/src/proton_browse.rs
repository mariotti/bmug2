// Browsing a Proton Drive remote path for the replication editor's
// "Browse..." picker - direct proton-drive CLI calls, independent of
// whether replication is configured/saved yet (replication.rs only
// ever learns the resolved binary from BMU_REPLICATE_PROTON_BIN
// *after* a save; this needs it before). Never writes
// backmeup.setup.sh or touches configure.sh - purely a picker aid.
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Same search order as bin/backmeup.shellfunctions.sh's
/// bmuDetectProton: bare name (via PATH) first, then the Homebrew/
/// system fallback locations. "--version" exiting 0 is the simplest
/// real signal this is a working binary, not just a file that exists.
fn detect_proton_drive() -> Option<String> {
    for candidate in [
        "proton-drive",
        "/opt/homebrew/bin/proton-drive",
        "/usr/local/bin/proton-drive",
        "/usr/bin/proton-drive",
    ] {
        let works = Command::new(candidate)
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if works {
            return Some(candidate.to_string());
        }
    }
    None
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct RemoteEntry {
    pub name: String,
    pub is_folder: bool,
}

#[derive(serde::Deserialize)]
struct RawName {
    value: Option<String>,
}

#[derive(serde::Deserialize)]
struct RawEntry {
    name: RawName,
    #[serde(rename = "type")]
    kind: String,
}

pub fn available() -> bool {
    detect_proton_drive().is_some()
}

/// Exact text proton-drive (v0.8.0) prints to stderr, exit 1, for every
/// data command (list/info/create-folder/...) when there's no active
/// session - confirmed by probing it with HOME pointed at an empty
/// directory, never by touching this machine's real session.
const LOGIN_REQUIRED_MARKER: &str = "You need to login first";

const NOT_SIGNED_IN_MESSAGE: &str =
    "Not signed in to Proton Drive - run `proton-drive auth login` in a terminal, then try again.";

/// Cheap, read-only signal for gating the Browse button before the user
/// clicks it: "is there a session right now", via the same info call
/// list_folder/create_folder would hit anyway. Never writes anything.
pub fn signed_in() -> bool {
    let Some(bin) = detect_proton_drive() else {
        return false;
    };
    Command::new(&bin)
        .args(["filesystem", "info", "/my-files"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Runs a command with a wall-clock timeout, for `auth login`'s own
/// blocking wait on the real browser-based sign-in - same reasoning
/// and same manual spawn + try_wait() polling pattern as
/// rclone_browse.rs's run_with_timeout (duplicated rather than shared;
/// the two modules are already independent by design, same precedent
/// as their separate detect_* binary-search helpers). Without this, a
/// user who closes the browser tab (or never finishes signing in)
/// would hang the GUI's "signing in..." state forever - Tauri has no
/// built-in way to cancel an in-flight command.
///
/// Reads stdout/stderr only after the child exits, not concurrently -
/// safe here since `auth login` only ever prints a small amount of
/// status text, never enough to fill the OS pipe buffer before
/// exiting.
fn run_with_timeout(bin: &str, args: &[&str], timeout: Duration) -> Result<Output, String> {
    let mut child = Command::new(bin)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;

    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|e| format!("failed to wait for {bin}: {e}"))? {
            use std::io::Read;
            let mut stdout = Vec::new();
            let mut stderr = Vec::new();
            if let Some(mut out) = child.stdout.take() {
                let _ = out.read_to_end(&mut stdout);
            }
            if let Some(mut err) = child.stderr.take() {
                let _ = err.read_to_end(&mut stderr);
            }
            return Ok(Output { status, stdout, stderr });
        }
        if start.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err("timed out waiting for sign-in - try again".to_string());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

/// Triggers `proton-drive auth login`, which opens the system browser
/// itself and blocks until the user finishes signing in (or the
/// process is killed). Short-circuits if already signed in - no need
/// to touch the browser at all in that case.
pub fn login() -> Result<(), String> {
    if signed_in() {
        return Ok(());
    }
    let bin = detect_proton_drive().ok_or("proton-drive was not found on this machine")?;
    let output = run_with_timeout(&bin, &["auth", "login"], LOGIN_TIMEOUT)?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    if !signed_in() {
        return Err("sign-in did not complete - try again".to_string());
    }
    Ok(())
}

fn parse_entries(json: &str) -> Result<Vec<RemoteEntry>, String> {
    let raw: Vec<RawEntry> =
        serde_json::from_str(json).map_err(|e| format!("could not parse proton-drive's output: {e}\n{json}"))?;
    let mut entries: Vec<RemoteEntry> = raw
        .into_iter()
        .filter_map(|e| {
            // Skip undecryptable/conflicting names (name.ok: false, or
            // no value at all) rather than showing a blank/broken row.
            let name = e.name.value?;
            Some(RemoteEntry {
                name,
                is_folder: e.kind == "folder",
            })
        })
        .collect();
    entries.sort_by(|a, b| b.is_folder.cmp(&a.is_folder).then(a.name.cmp(&b.name)));
    Ok(entries)
}

/// Lists the immediate children of path. Folders and files both come
/// back (so a future version could show file counts etc.) but the
/// frontend only renders/navigates into folders - picking a
/// destination folder is all this is for.
pub fn list_folder(path: &str) -> Result<Vec<RemoteEntry>, String> {
    let bin = detect_proton_drive().ok_or(
        "proton-drive was not found on this machine - install it from proton.me/download/drive/cli",
    )?;
    let output = Command::new(&bin)
        .args(["filesystem", "list", "-j", path])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains(LOGIN_REQUIRED_MARKER) {
            return Err(NOT_SIGNED_IN_MESSAGE.to_string());
        }
        return Err(format!("{text}{stderr}"));
    }
    parse_entries(&text)
}

/// Ensures a folder exists at parent/name, tolerating the "already
/// exists" case (checked via a real filesystem info call, not
/// create-folder's own exit code - same verified-safe pattern already
/// used by bin/backmeup.replicate.proton.sh's bmuProtonEnsureFolder).
pub fn create_folder(parent: &str, name: &str) -> Result<(), String> {
    let bin = detect_proton_drive().ok_or("proton-drive was not found on this machine")?;
    let full_path = format!("{}/{}", parent.trim_end_matches('/'), name);
    let already_exists = Command::new(&bin)
        .args(["filesystem", "info", &full_path])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if already_exists {
        return Ok(());
    }
    let output = Command::new(&bin)
        .args(["filesystem", "create-folder", parent, name])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains(LOGIN_REQUIRED_MARKER) {
            Err(NOT_SIGNED_IN_MESSAGE.to_string())
        } else {
            Err(stderr.to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    // detect_proton_drive() tries the bare "proton-drive" name first,
    // which Command::new resolves via PATH - so prepending a tmp dir
    // holding a fake, same-named executable to PATH is enough to
    // redirect every function in this file to it, with zero changes
    // to the real code. Mutates the process-wide PATH/env vars, same
    // category of global-state hazard replication.rs's own
    // fake_configure_script already documents for this same test
    // binary (hence this crate's `cargo test -- --test-threads=1` in
    // CI) - not a new risk, the same accepted one, just via PATH/env
    // instead of a shared file path. Drop always restores both.
    struct FakeProtonDrive {
        dir: PathBuf,
        old_path: String,
    }

    impl FakeProtonDrive {
        fn new(script: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("bmug2-fake-proton-{}", std::process::id()));
            std::fs::remove_dir_all(&dir).ok();
            std::fs::create_dir_all(&dir).unwrap();
            let bin_path = dir.join("proton-drive");
            std::fs::write(&bin_path, script).unwrap();
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&bin_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&bin_path, perms).unwrap();

            let old_path = std::env::var("PATH").unwrap_or_default();
            std::env::set_var("PATH", format!("{}:{old_path}", dir.display()));
            FakeProtonDrive { dir, old_path }
        }
    }

    impl Drop for FakeProtonDrive {
        fn drop(&mut self) {
            std::env::set_var("PATH", &self.old_path);
            std::fs::remove_dir_all(&self.dir).ok();
            for var in ["FAKE_PROTON_INFO_OK", "FAKE_PROTON_LIST_JSON", "FAKE_PROTON_CREATE_OK"] {
                std::env::remove_var(var);
            }
        }
    }

    // Responds to every call this file ever makes: --version (for
    // detect_proton_drive), filesystem info/list/create-folder (for
    // signed_in/list_folder/create_folder), each independently
    // controlled by its own env var so one script covers every test.
    const FAKE_PROTON_SCRIPT: &str = r#"#!/bin/sh
case "$1" in
  --version) exit 0 ;;
esac
if [ "$1" = "filesystem" ]; then
  case "$2" in
    info)
      if [ "$FAKE_PROTON_INFO_OK" = "1" ]; then exit 0; else echo "You need to login first" >&2; exit 1; fi
      ;;
    list)
      if [ -n "$FAKE_PROTON_LIST_JSON" ]; then echo "$FAKE_PROTON_LIST_JSON"; exit 0; else echo "You need to login first" >&2; exit 1; fi
      ;;
    create-folder)
      if [ "$FAKE_PROTON_CREATE_OK" = "1" ]; then exit 0; else echo "You need to login first" >&2; exit 1; fi
      ;;
  esac
fi
exit 1
"#;

    #[test]
    fn detect_and_available_are_true_when_a_working_binary_is_on_path() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        assert!(available());
    }

    // Deliberately no "available()/login() is false/errors with no
    // binary present" test: detect_proton_drive()'s fallback candidates
    // include hardcoded absolute paths (e.g. /usr/local/bin/proton-drive)
    // that can genuinely exist on a real dev machine (confirmed on the
    // one this was written on) regardless of PATH - making "not found"
    // unreliable to assert rather than something this file's own logic
    // controls.

    #[test]
    fn signed_in_reflects_the_fake_binarys_info_call() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        assert!(!signed_in());
        std::env::set_var("FAKE_PROTON_INFO_OK", "1");
        assert!(signed_in());
    }

    #[test]
    fn login_short_circuits_when_already_signed_in() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        std::env::set_var("FAKE_PROTON_INFO_OK", "1");
        // If login() didn't short-circuit, it would call "auth login"
        // next, which this fake script doesn't handle (falls through
        // to `exit 1`) - so this only passes if signed_in()'s own
        // check was enough to return Ok without going further.
        assert!(login().is_ok());
    }

    #[test]
    fn list_folder_parses_the_fake_binarys_real_shaped_output() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        std::env::set_var("FAKE_PROTON_LIST_JSON", REAL_SHAPED_RESPONSE);
        let entries = list_folder("/my-files").unwrap();
        assert_eq!(entries.len(), 3);
    }

    #[test]
    fn list_folder_surfaces_the_not_signed_in_message() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        let err = list_folder("/my-files").unwrap_err();
        assert_eq!(err, NOT_SIGNED_IN_MESSAGE);
    }

    #[test]
    fn create_folder_skips_the_real_call_when_it_already_exists() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        std::env::set_var("FAKE_PROTON_INFO_OK", "1");
        // FAKE_PROTON_CREATE_OK is deliberately left unset - if
        // create_folder didn't skip the real create-folder call after
        // the existence check succeeds, this would fail instead.
        assert!(create_folder("/my-files", "Taxes").is_ok());
    }

    #[test]
    fn create_folder_creates_it_for_real_when_it_does_not_exist_yet() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        std::env::set_var("FAKE_PROTON_CREATE_OK", "1");
        assert!(create_folder("/my-files", "Taxes").is_ok());
    }

    #[test]
    fn create_folder_surfaces_the_not_signed_in_message() {
        let _fake = FakeProtonDrive::new(FAKE_PROTON_SCRIPT);
        let err = create_folder("/my-files", "Taxes").unwrap_err();
        assert_eq!(err, NOT_SIGNED_IN_MESSAGE);
    }

    // Exact shape confirmed by live probing against the real CLI
    // (v0.8.0) - see proton_browse.rs's own module doc / the plan this
    // was built from.
    const REAL_SHAPED_RESPONSE: &str = r#"[
{"uid":"abc","parentUid":"root","name":{"ok":true,"value":"Taxes"},"type":"folder","isShared":false,"folder":{"isImported":false}},
{"uid":"def","parentUid":"root","name":{"ok":true,"value":"file1.txt"},"type":"file","mediaType":"text/plain"},
{"uid":"ghi","parentUid":"root","name":{"ok":true,"value":"bmug2"},"type":"folder","isShared":false,"folder":{"isImported":false}}
]"#;

    #[test]
    fn parses_real_shaped_response_into_entries() {
        let entries = parse_entries(REAL_SHAPED_RESPONSE).unwrap();
        assert_eq!(entries.len(), 3);
        assert!(entries.iter().any(|e| e.name == "Taxes" && e.is_folder));
        assert!(entries.iter().any(|e| e.name == "file1.txt" && !e.is_folder));
        assert!(entries.iter().any(|e| e.name == "bmug2" && e.is_folder));
    }

    #[test]
    fn sorts_folders_before_files_then_alphabetically() {
        let entries = parse_entries(REAL_SHAPED_RESPONSE).unwrap();
        assert_eq!(
            entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            vec!["Taxes", "bmug2", "file1.txt"]
        );
    }

    #[test]
    fn skips_entries_with_undecryptable_names() {
        let json = r#"[
{"uid":"abc","parentUid":"root","name":{"ok":false,"value":null},"type":"folder"},
{"uid":"def","parentUid":"root","name":{"ok":true,"value":"readable"},"type":"folder","folder":{"isImported":false}}
]"#;
        let entries = parse_entries(json).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "readable");
    }

    #[test]
    fn invalid_json_is_an_error() {
        assert!(parse_entries("not json").is_err());
    }

    #[test]
    fn login_required_marker_matches_the_real_cli_text() {
        // Confirmed verbatim by probing the real CLI with HOME pointed
        // at an empty directory (never by logging out this machine's
        // real session) - exit 1, this exact line on stderr.
        assert!("You need to login first\n".contains(LOGIN_REQUIRED_MARKER));
    }

    /// Real end-to-end verification against the live, already-
    /// authenticated proton-drive CLI on this machine - same
    /// reasoning/convention as install.rs's own #[ignore]d real-
    /// network tests. Run explicitly with `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn lists_my_files_for_real() {
        let result = list_folder("/my-files");
        assert!(result.is_ok(), "list_folder failed: {:?}", result.err());
    }

    #[test]
    #[ignore]
    fn signed_in_is_true_for_real() {
        assert!(signed_in());
    }
}
