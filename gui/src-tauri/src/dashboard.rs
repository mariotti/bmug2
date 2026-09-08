// Status + search: thin wrappers around backmeup.status.sh --json /
// backmeup.locate.sh --json. Unlike install.rs's run() helper (which
// deliberately merges stdout+stderr for a human-readable progress
// log), stdout is captured separately here and parsed directly - both
// --json branches already keep stdout JSON-clean (backmeup.locate.sh's
// own ${BMU_CMDLOCATE} calls redirect stderr internally in that
// branch), so no merging/stripping is needed.
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StatusProject {
    pub name: String,
    pub last_run: Option<String>,
    pub last_change: Option<String>,
    pub snapshot_count: u64,
    pub mirror_size_kb: u64,
    pub history_size_kb: Option<u64>,
    pub old_layout: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StatusResult {
    pub sync_dir: String,
    pub history_dir: String,
    pub projects: Vec<StatusProject>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocateCounts {
    pub index: u64,
    pub archived_filelist: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocateHit {
    pub path: String,
    /// "index" or "archived_filelist" - kept as a plain string rather
    /// than an enum since it's display-only data for the frontend.
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocateResult {
    pub patterns: Vec<String>,
    pub indexed: bool,
    pub counts: LocateCounts,
    pub results: Vec<LocateHit>,
}

fn run_json<T: for<'de> Deserialize<'de>>(cmd: &mut Command, what: &str) -> Result<T, String> {
    let name = format!("{:?}", cmd);
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run {what} ({name}): {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "{what} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    serde_json::from_slice(&output.stdout).map_err(|e| {
        format!(
            "{what} produced output this GUI couldn't understand ({e}) - is the \
             installed bmug2 version compatible? stdout was: {}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

pub fn get_status(bin_dir: &str) -> Result<StatusResult, String> {
    run_json(
        Command::new(Path::new(bin_dir).join("backmeup.status.sh")).arg("--json"),
        "backmeup.status.sh --json",
    )
}

pub fn search(bin_dir: &str, patterns: &[String]) -> Result<LocateResult, String> {
    run_json(
        Command::new(Path::new(bin_dir).join("backmeup.locate.sh"))
            .arg("--json")
            .args(patterns),
        "backmeup.locate.sh --json",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured from a real run against a real sandbox (backmeup.sh run
    // twice, backmeup.updatedb.sh run once) - not hand-typed guesses.
    const REAL_STATUS_JSON: &str = r#"{"sync_dir":"/tmp/bmudashboard_fixtures/sync","history_dir":"/tmp/bmudashboard_fixtures/sync-BP","projects":[{"name":"proj1","last_run":"2026-09-08 22:04:12","last_change":"20260908-220412","snapshot_count":1,"mirror_size_kb":4,"history_size_kb":16,"old_layout":false}]}"#;
    const REAL_LOCATE_JSON: &str = r#"{"patterns":["file1"],"indexed":true,"counts":{"index":2,"archived_filelist":0},"results":[{"path":"/tmp/bmudashboard_fixtures/sync/proj1/file1.txt","source":"index"},{"path":"/tmp/bmudashboard_fixtures/sync-BP/proj1/B-20260908-220412/file1.txt","source":"index"}]}"#;

    #[test]
    fn parses_real_status_json() {
        let parsed: StatusResult = serde_json::from_str(REAL_STATUS_JSON).unwrap();
        assert_eq!(parsed.projects.len(), 1);
        let p = &parsed.projects[0];
        assert_eq!(p.name, "proj1");
        assert_eq!(p.snapshot_count, 1);
        assert_eq!(p.mirror_size_kb, 4);
        assert_eq!(p.history_size_kb, Some(16));
        assert!(!p.old_layout);
    }

    #[test]
    fn parses_real_locate_json() {
        let parsed: LocateResult = serde_json::from_str(REAL_LOCATE_JSON).unwrap();
        assert!(parsed.indexed);
        assert_eq!(parsed.counts.index, 2);
        assert_eq!(parsed.counts.archived_filelist, 0);
        assert_eq!(parsed.results.len(), 2);
        assert_eq!(parsed.results[0].source, "index");
    }

    #[test]
    fn parses_null_fields_as_none() {
        let json = r#"{"name":"fresh","last_run":null,"last_change":null,"snapshot_count":0,"mirror_size_kb":0,"history_size_kb":null,"old_layout":false}"#;
        let parsed: StatusProject = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.last_run, None);
        assert_eq!(parsed.last_change, None);
        assert_eq!(parsed.history_size_kb, None);
    }

    #[test]
    fn malformed_json_is_a_clear_error_not_a_panic() {
        let result: Result<StatusResult, _> = serde_json::from_str("not json");
        assert!(result.is_err());
    }

    /// Real end-to-end: builds a real bmug2 sandbox (copies this repo's
    /// own bin/, runs backmeup.sh for real), then calls get_status/
    /// search against it for real. No network needed (unlike
    /// install.rs's equivalent test), fast enough to run by default -
    /// same "real commands, not mocks" philosophy as the rest of this
    /// project's test suites.
    #[test]
    fn get_status_and_search_work_end_to_end_for_real() {
        let repo_bin = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bin")
            .canonicalize()
            .expect("repo bin/ dir should exist");

        let base = std::env::temp_dir().join(format!("bmug2-dashboard-test-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        let bin_dir = base.join("bin");
        let sync_dir = base.join("sync");
        let backup_dir = base.join("sync-BP");
        std::fs::create_dir_all(sync_dir.join(".locate.dir")).unwrap();
        std::fs::create_dir_all(&backup_dir).unwrap();
        copy_dir(&repo_bin, &bin_dir);

        let template = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh.template")).unwrap();
        let setup = template.replace(
            "${HOME}/Backups/rsyncBackup",
            sync_dir.to_str().unwrap(),
        );
        std::fs::write(bin_dir.join("backmeup.setup.sh"), setup).unwrap();

        let src = base.join("src/proj1");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("hello.txt"), "hello dashboard test").unwrap();

        let backup_status = Command::new(bin_dir.join("backmeup.sh"))
            .arg(&src)
            .output()
            .expect("backmeup.sh should run");
        assert!(
            backup_status.status.success(),
            "backmeup.sh failed: {}",
            String::from_utf8_lossy(&backup_status.stderr)
        );

        let status = get_status(bin_dir.to_str().unwrap()).expect("get_status should succeed");
        assert_eq!(status.projects.len(), 1);
        assert_eq!(status.projects[0].name, "proj1");
        assert_eq!(status.projects[0].snapshot_count, 0); // first run archives nothing

        let found = search(bin_dir.to_str().unwrap(), &["hello.txt".to_string()])
            .expect("search should succeed");
        // no locate/updatedb run in this test - archived-filelist path
        // only, which is fine: this exercises the real subprocess +
        // JSON contract, not backmeup.locate.sh's own search logic
        // (already covered by tests/test_backmeup.sh).
        assert_eq!(found.patterns, vec!["hello.txt".to_string()]);

        std::fs::remove_dir_all(&base).ok();
    }

    fn copy_dir(src: &Path, dst: &Path) {
        std::fs::create_dir_all(dst).unwrap();
        for entry in std::fs::read_dir(src).unwrap() {
            let entry = entry.unwrap();
            let dst_path = dst.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                copy_dir(&entry.path(), &dst_path);
            } else {
                std::fs::copy(entry.path(), &dst_path).unwrap();
                let perms = std::fs::metadata(entry.path()).unwrap().permissions();
                std::fs::set_permissions(&dst_path, perms).unwrap();
            }
        }
    }
}
