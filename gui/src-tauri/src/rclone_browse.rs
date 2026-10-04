// Browsing a Google Drive rclone remote for the replication editor's
// "Browse..." picker - direct rclone CLI calls, independent of
// whether replication is configured/saved yet, same reasoning as
// proton_browse.rs. rclone's own JSON interfaces (listremotes/lsjson)
// are uniform across every backend it supports, but this module only
// ever surfaces remotes of type "drive" - scoped to Google Drive
// specifically, since that's what was asked for, not a general
// "browse any rclone remote" feature.
use std::process::Command;

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

/// Names (without the trailing ':') of every configured remote whose
/// type is "drive" - confirmed exact field shape
/// ({"name":"x","type":"drive","source":"file","description":""}) by
/// probing `rclone listremotes --json` against a throwaway config file
/// with placeholder, non-functional credentials, never this machine's
/// real rclone.conf. Reading the config list is local/offline; unlike
/// list_folder/create_folder below, this never touches the network.
pub fn list_drive_remotes() -> Result<Vec<String>, String> {
    let bin = detect_rclone()
        .ok_or("rclone was not found on this machine - install it from rclone.org/install")?;
    let output = Command::new(&bin)
        .args(["listremotes", "--json"])
        .output()
        .map_err(|e| format!("failed to run {bin}: {e}"))?;
    if !output.status.success() {
        return Err(clean_stderr(&String::from_utf8_lossy(&output.stderr)));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let raw = parse_remotes(&text)?;
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
}
