// Browsing a Google Drive rclone remote for the replication editor's
// "Browse..." picker - direct rclone CLI calls, independent of
// whether replication is configured/saved yet, same reasoning as
// proton_browse.rs. rclone's own JSON interfaces (listremotes/lsjson)
// are uniform across every backend it supports, but this module only
// ever surfaces remotes of type "drive" - scoped to Google Drive
// specifically, since that's what was asked for, not a general
// "browse any rclone remote" feature.
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Same search order as bin/backmeup.shellfunctions.sh's
/// bmuDetectRclone: bare name (via PATH) first, then the Homebrew/
/// system fallback locations.
fn detect_rclone() -> Option<String> {
    for candidate in [
        "rclone",
        "/opt/homebrew/bin/rclone",
        "/usr/local/bin/rclone",
        "/usr/bin/rclone",
    ] {
        let works = Command::new(candidate)
            .arg("version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if works {
            return Some(candidate.to_string());
        }
    }
    None
}

pub fn available() -> bool {
    detect_rclone().is_some()
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct RemoteEntry {
    pub name: String,
    pub is_folder: bool,
}

#[derive(serde::Deserialize)]
struct RawRemote {
    name: String,
    #[serde(rename = "type")]
    kind: String,
}

#[derive(serde::Deserialize)]
struct RawItem {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "IsDir")]
    is_dir: bool,
}

/// rclone prints a one-time "shared client_id is being retired" NOTICE
/// on stderr for remotes using its default OAuth app - unrelated to
/// whether the call actually succeeded or failed, so it's stripped
/// before showing an error to the user rather than left to read like
/// part of the failure. Falls back to the raw text if stripping would
/// leave nothing (never hide a real error with no explanation).
fn clean_stderr(stderr: &str) -> String {
    let cleaned: String = stderr
        .lines()
        .filter(|line| !line.contains(" NOTICE: "))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    if cleaned.is_empty() {
        stderr.trim().to_string()
    } else {
        cleaned
    }
}

fn parse_remotes(json: &str) -> Result<Vec<RawRemote>, String> {
    serde_json::from_str(json).map_err(|e| format!("could not parse rclone's output: {e}\n{json}"))
}

/// Shared by list_drive_remotes and create_drive_remote's collision
/// check - confirmed exact field shape
/// ({"name":"x","type":"drive","source":"file","description":""}) by
/// probing `rclone listremotes --json` against a throwaway config file
/// with placeholder, non-functional credentials, never this machine's
/// real rclone.conf. Reading the config list is local/offline; unlike
/// list_folder/create_folder below, this never touches the network.
fn fetch_remotes(bin: &str) -> Result<Vec<RawRemote>, String> {
    let output = Command::new(bin)
        .args(["listremotes", "--json"])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    if !output.status.success() {
        return Err(clean_stderr(&String::from_utf8_lossy(&output.stderr)));
    }
    parse_remotes(&String::from_utf8_lossy(&output.stdout))
}

/// Names (without the trailing ':') of every configured remote whose
/// type is "drive".
pub fn list_drive_remotes() -> Result<Vec<String>, String> {
    let bin = detect_rclone()
        .ok_or("rclone was not found on this machine - install it from rclone.org/install")?;
    let raw = fetch_remotes(&bin)?;
    let mut names: Vec<String> = raw.into_iter().filter(|r| r.kind == "drive").map(|r| r.name).collect();
    names.sort();
    Ok(names)
}

fn parse_entries(json: &str) -> Result<Vec<RemoteEntry>, String> {
    let raw: Vec<RawItem> =
        serde_json::from_str(json).map_err(|e| format!("could not parse rclone's output: {e}\n{json}"))?;
    let mut entries: Vec<RemoteEntry> = raw
        .into_iter()
        .map(|i| RemoteEntry {
            name: i.name,
            is_folder: i.is_dir,
        })
        .collect();
    entries.sort_by(|a, b| b.is_folder.cmp(&a.is_folder).then(a.name.cmp(&b.name)));
    Ok(entries)
}

/// Lists the immediate children of a full rclone path (e.g.
/// "mydrive:" or "mydrive:Taxes"). A stale/expired Google token
/// surfaces here as rclone's own "couldn't fetch token: ... try
/// refreshing with \"rclone config reconnect mydrive:\"" message -
/// already specific and actionable, so it's passed straight through
/// (NOTICE lines stripped) rather than replaced with a generic one.
pub fn list_folder(path: &str) -> Result<Vec<RemoteEntry>, String> {
    let bin = detect_rclone()
        .ok_or("rclone was not found on this machine - install it from rclone.org/install")?;
    let output = Command::new(&bin)
        .args(["lsjson", path])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    if !output.status.success() {
        return Err(clean_stderr(&String::from_utf8_lossy(&output.stderr)));
    }
    parse_entries(&String::from_utf8_lossy(&output.stdout))
}

/// Creates a folder at a full rclone path. rclone's own mkdir is
/// already idempotent ("make the path if it doesn't already exist") -
/// unlike proton-drive's create-folder, no separate existence check is
/// needed here.
pub fn create_folder(path: &str) -> Result<(), String> {
    let bin = detect_rclone().ok_or("rclone was not found on this machine")?;
    let output = Command::new(&bin)
        .args(["mkdir", path])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(clean_stderr(&String::from_utf8_lossy(&output.stderr)))
    }
}

#[derive(serde::Deserialize)]
struct ConfigOption {
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "DefaultStr")]
    default_str: String,
}

#[derive(serde::Deserialize)]
struct ConfigStep {
    #[serde(rename = "State")]
    state: String,
    #[serde(rename = "Option")]
    option: Option<ConfigOption>,
    #[serde(rename = "Error")]
    error: String,
}

/// Picks the answer for one question in rclone's non-interactive
/// `config create`/`config update --continue` state machine (confirmed
/// live, against a throwaway config, never this machine's real
/// rclone.conf - see create_drive_remote's own doc comment). Only two
/// questions get a fixed override - everything else (e.g. the
/// team/shared-drive question, whose exact Option.Name wasn't
/// confirmed live since reaching it requires completing real Google
/// sign-in) falls back to rclone's own proposed default, which is
/// always "no"/restrictive for anything this picker doesn't have a
/// specific opinion about.
fn answer_for(option: &ConfigOption) -> String {
    match option.name.as_str() {
        // Always proceed with rclone's shared OAuth client - the same
        // choice the manual `rclone config` walkthrough already gives.
        "config_shared_client_id" => "true".to_string(),
        // Always use the local browser flow - this app always runs on
        // the same machine as the browser that completes sign-in.
        "config_is_local" => "true".to_string(),
        _ => option.default_str.clone(),
    }
}

fn parse_config_step(output: &Output) -> Result<ConfigStep, String> {
    if !output.status.success() {
        return Err(clean_stderr(&String::from_utf8_lossy(&output.stderr)));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("could not parse rclone's output: {e}\n{}", String::from_utf8_lossy(&output.stdout)))
}

/// Runs one `config update --continue` step with a wall-clock timeout,
/// for the one step (answering config_is_local with "true") that makes
/// rclone itself open the system browser and block waiting for the
/// Google OAuth redirect to come back on a local port. Without this, a
/// user who closes that browser tab (or never finishes signing in)
/// would hang the GUI's "Connecting..." state forever - Tauri has no
/// built-in way to cancel an in-flight command, so the timeout is the
/// only way this ever resolves on its own.
///
/// Reads stdout/stderr only after the child exits rather than
/// draining them concurrently (the usual pipe-deadlock risk with a
/// manual spawn) - safe here specifically because every step of this
/// protocol only ever prints one small JSON object, never enough to
/// fill the OS pipe buffer before exiting.
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
            return Err("timed out waiting for Google sign-in - try again".to_string());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

const MAX_CONFIG_STEPS: u32 = 10;
const OAUTH_TIMEOUT: Duration = Duration::from_secs(300);

fn run_create_flow(bin: &str, name: &str) -> Result<(), String> {
    let output = Command::new(bin)
        .args(["config", "create", name, "drive", "scope=drive", "--non-interactive"])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    let mut step = parse_config_step(&output)?;

    let mut steps_taken = 0;
    while !step.state.is_empty() {
        if !step.error.is_empty() {
            return Err(step.error);
        }
        steps_taken += 1;
        if steps_taken > MAX_CONFIG_STEPS {
            return Err("rclone's setup asked more questions than expected - finish it manually via `rclone config`".to_string());
        }
        let option = step
            .option
            .as_ref()
            .ok_or("rclone's setup returned a question with no details")?;
        let answer = answer_for(option);
        let is_oauth_step = option.name == "config_is_local" && answer == "true";
        let args = [
            "config",
            "update",
            name,
            "--continue",
            "--state",
            &step.state,
            "--result",
            &answer,
            "--non-interactive",
        ];

        let next_output = if is_oauth_step {
            run_with_timeout(bin, &args, OAUTH_TIMEOUT)?
        } else {
            Command::new(bin)
                .args(args)
                .output()
                .map_err(|e| format!("failed to run {bin}: {e}"))?
        };
        step = parse_config_step(&next_output)?;
    }
    if !step.error.is_empty() {
        return Err(step.error);
    }

    // Belt-and-suspenders: confirm it actually landed as a drive
    // remote rather than trusting the state machine's "done" signal
    // blindly.
    if !list_drive_remotes()?.iter().any(|n| n == name) {
        return Err("setup finished but the new remote isn't showing up as a Google Drive remote".to_string());
    }
    Ok(())
}

/// Adds a new Google Drive remote by driving rclone's own
/// non-interactive setup protocol (`rclone config create ...
/// --non-interactive`, stepped via `rclone config update --continue`
/// until its own State comes back empty) - confirmed live against a
/// throwaway config, never this machine's real rclone.conf. The one
/// question this can't answer on its own is the actual Google sign-in:
/// answering config_is_local with "true" makes rclone itself open the
/// system browser and block waiting for the OAuth redirect, which is
/// exactly the one step that has to stay a real human action.
///
/// `rclone config create` does *not* error on an existing name - it
/// silently starts overwriting it (confirmed live) - so the up-front
/// existence check below is a real safety requirement, not just
/// defensive. Also confirmed live: an abandoned/timed-out attempt
/// leaves a broken, token-less stub remote behind under `name`, which
/// is why any failure path here rolls that back via `config delete`
/// rather than leaving a retry under the same name permanently
/// blocked by the same collision check.
pub fn create_drive_remote(name: &str) -> Result<(), String> {
    let bin = detect_rclone()
        .ok_or("rclone was not found on this machine - install it from rclone.org/install")?;

    let existing = fetch_remotes(&bin)?;
    if existing.iter().any(|r| r.name == name) {
        return Err(format!("a remote named \"{name}\" already exists - pick a different name"));
    }

    let result = run_create_flow(&bin, name);
    if result.is_err() {
        let _ = Command::new(&bin).args(["config", "delete", name]).output();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exact shape confirmed by probing `rclone listremotes --json`
    // against a throwaway config file with two placeholder remotes
    // (one drive, one s3) - never this machine's real rclone.conf.
    const REMOTES_RESPONSE: &str = r#"[
{"name":"mydrive","type":"drive","source":"file","description":""},
{"name":"mys3","type":"s3","source":"file","description":""}
]"#;

    #[test]
    fn filters_to_drive_type_remotes_only() {
        let names = {
            let raw = parse_remotes(REMOTES_RESPONSE).unwrap();
            let mut names: Vec<String> = raw.into_iter().filter(|r| r.kind == "drive").map(|r| r.name).collect();
            names.sort();
            names
        };
        assert_eq!(names, vec!["mydrive".to_string()]);
    }

    #[test]
    fn invalid_remotes_json_is_an_error() {
        assert!(parse_remotes("not json").is_err());
    }

    // Shape per rclone's own `rclone lsjson --help` documentation
    // (PascalCase fields, unlike proton-drive's lowercase JSON).
    const LSJSON_RESPONSE: &str = r#"[
{"Name":"Taxes","Path":"Taxes","IsDir":true,"Size":-1},
{"Name":"file1.txt","Path":"file1.txt","IsDir":false,"Size":6},
{"Name":"bmug2","Path":"bmug2","IsDir":true,"Size":-1}
]"#;

    #[test]
    fn parses_lsjson_response_into_entries() {
        let entries = parse_entries(LSJSON_RESPONSE).unwrap();
        assert_eq!(entries.len(), 3);
        assert!(entries.iter().any(|e| e.name == "Taxes" && e.is_folder));
        assert!(entries.iter().any(|e| e.name == "file1.txt" && !e.is_folder));
    }

    #[test]
    fn sorts_folders_before_files_then_alphabetically() {
        let entries = parse_entries(LSJSON_RESPONSE).unwrap();
        assert_eq!(
            entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            vec!["Taxes", "bmug2", "file1.txt"]
        );
    }

    #[test]
    fn invalid_lsjson_is_an_error() {
        assert!(parse_entries("not json").is_err());
    }

    #[test]
    fn strips_shared_client_id_notice_but_keeps_the_real_error() {
        let stderr = "2026/10/04 17:47:21 NOTICE: mydrive: This remote uses rclone's shared Google Drive client_id, which is being retired and will stop working during 2026. Create your own client_id to avoid interruption: https://rclone.org/drive/#making-your-own-client-id\n2026/10/04 17:47:21 CRITICAL: Failed to create file system for \"mydrive:\": couldn't find root directory ID: couldn't fetch token: invalid_grant: maybe token expired? - try refreshing with \"rclone config reconnect mydrive:\"";
        let cleaned = clean_stderr(stderr);
        assert!(!cleaned.contains("shared Google Drive client_id"));
        assert!(cleaned.contains("rclone config reconnect"));
    }

    #[test]
    fn falls_back_to_raw_text_if_nothing_survives_stripping() {
        let stderr = "2026/10/04 17:47:21 NOTICE: just a notice, nothing else";
        assert_eq!(clean_stderr(stderr), stderr.trim());
    }

    /// Real end-to-end verification - requires at least one Google
    /// Drive remote actually configured in this machine's rclone.conf
    /// (none is, on the machine this was developed on - `rclone
    /// listremotes` came back empty). Run explicitly once a real
    /// remote exists: `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn lists_a_real_drive_remote_for_real() {
        let remotes = list_drive_remotes().expect("list_drive_remotes failed");
        assert!(!remotes.is_empty(), "no Google Drive remote configured to test against");
        let result = list_folder(&format!("{}:", remotes[0]));
        assert!(result.is_ok(), "list_folder failed: {:?}", result.err());
    }

    // Exact shapes confirmed live by probing `rclone config create
    // <name> drive scope=drive --non-interactive` (and its --continue
    // follow-up) against a throwaway config - never this machine's
    // real rclone.conf, and never completing the real OAuth step.
    const CLIENT_ID_WARNING_STEP: &str = r#"{
"State": "client_id_warning",
"Option": {"Name": "config_shared_client_id", "DefaultStr": "false"},
"Error": ""
}"#;
    const CONFIG_IS_LOCAL_STEP: &str = r#"{
"State": "*oauth-islocal,teamdrive,oauth,",
"Option": {"Name": "config_is_local", "DefaultStr": "true"},
"Error": ""
}"#;
    const DONE_STEP: &str = r#"{"State": "", "Error": ""}"#;
    const ERROR_STEP: &str = r#"{"State": "", "Error": "name already in use"}"#;

    #[test]
    fn overrides_client_id_and_local_browser_questions_to_true() {
        let step: ConfigStep = serde_json::from_str(CLIENT_ID_WARNING_STEP).unwrap();
        assert_eq!(answer_for(step.option.as_ref().unwrap()), "true");

        let step: ConfigStep = serde_json::from_str(CONFIG_IS_LOCAL_STEP).unwrap();
        assert_eq!(answer_for(step.option.as_ref().unwrap()), "true");
    }

    #[test]
    fn falls_back_to_rclones_own_default_for_unknown_questions() {
        let option = ConfigOption {
            name: "team_drive".to_string(),
            default_str: "false".to_string(),
        };
        assert_eq!(answer_for(&option), "false");
    }

    #[test]
    fn parses_a_done_step_with_no_option() {
        let step: ConfigStep = serde_json::from_str(DONE_STEP).unwrap();
        assert!(step.state.is_empty());
        assert!(step.option.is_none());
        assert!(step.error.is_empty());
    }

    #[test]
    fn parses_an_error_step() {
        let step: ConfigStep = serde_json::from_str(ERROR_STEP).unwrap();
        assert_eq!(step.error, "name already in use");
    }
}
