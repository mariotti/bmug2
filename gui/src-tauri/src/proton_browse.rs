// Browsing a Proton Drive remote path for the replication editor's
// "Browse..." picker - direct proton-drive CLI calls, independent of
// whether replication is configured/saved yet (replication.rs only
// ever learns the resolved binary from BMU_REPLICATE_PROTON_BIN
// *after* a save; this needs it before). Never writes
// backmeup.setup.sh or touches configure.sh - purely a picker aid.
use std::process::Command;

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
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
