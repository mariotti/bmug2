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
pub struct DiskUsageProject {
    pub name: String,
    pub sync_kb: u64,
    pub history_kb: u64,
    /// "default" or "none" - matches the sidecar backmeup.replicate.sh
    /// reads. Kept as a plain string rather than mirroring the
    /// config::ReplicateClass enum to decouple the CLI JSON shape from
    /// internal Rust enum variants (backward compat if either side
    /// evolves independently).
    pub replicate_class: String,
    /// Per-project effective budget in bytes - sidecar override if
    /// set, else the global default. Phase 2 of the disk-size project;
    /// `#[serde(default)]` keeps older bmug2 CLI output parseable (an
    /// install predating Phase 2 won't emit this field).
    #[serde(default)]
    pub sync_warn_bytes: Option<u64>,
    #[serde(default)]
    pub history_warn_bytes: Option<u64>,
    #[serde(default)]
    pub sync_over: bool,
    #[serde(default)]
    pub history_over: bool,
}

/// Global budget totals, matching backmeup.disk.sh's `budget` object.
/// Everything optional / `#[serde(default)]` so a pre-Phase-2 CLI's
/// output still parses.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DiskUsageBudget {
    #[serde(default)]
    pub sync_warn_bytes: Option<u64>,
    #[serde(default)]
    pub history_warn_bytes: Option<u64>,
    #[serde(default)]
    pub sync_over: bool,
    #[serde(default)]
    pub history_over: bool,
}

/// Per-volume info for a SYNC/HISTORY root. `mount` is None when
/// `df -Pk` couldn't resolve the volume (missing path, external
/// drive not plugged in). Total/avail reported in KB to match
/// everything else in bmug2.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DiskUsageVolume {
    #[serde(default)]
    pub mount: Option<String>,
    #[serde(default)]
    pub total_kb: Option<u64>,
    #[serde(default)]
    pub avail_kb: Option<u64>,
}

/// Which volumes SYNC + HISTORY live on. `same_volume` is None when
/// at least one side couldn't be resolved (unknown).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct DiskUsageVolumes {
    #[serde(default)]
    pub sync: DiskUsageVolume,
    #[serde(default)]
    pub history: DiskUsageVolume,
    #[serde(default)]
    pub same_volume: Option<bool>,
}

/// Phase 1 of the disk-size project: aggregated SYNC/HISTORY totals
/// plus a local-proxy estimate of what off-site replication would
/// push. No remote call today - replicate_estimate_kb is the sum of
/// (sync_kb + history_kb) over projects whose replicate_class is NOT
/// "none" (per-source opt-out). A later phase can call `rclone size`
/// when the configured backend is rclone/pcloud.
///
/// Phase 2 added the `budget` + `volumes` sub-objects, both
/// `#[serde(default)]` so a GUI built against Phase 2 still parses
/// a pre-Phase-2 CLI's `backmeup.disk.sh --json` output.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiskUsageReport {
    pub sync_dir: String,
    pub history_dir: String,
    pub sync_total_kb: u64,
    pub history_total_kb: u64,
    pub replicate_estimate_kb: u64,
    pub projects: Vec<DiskUsageProject>,
    #[serde(default)]
    pub budget: DiskUsageBudget,
    #[serde(default)]
    pub volumes: DiskUsageVolumes,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocateCounts {
    pub index: u64,
    pub live: u64,
    pub archived_filelist: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LocateHit {
    pub path: String,
    /// "index", "live", or "archived_filelist" - kept as a plain string
    /// rather than an enum since it's display-only data for the frontend.
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

pub fn get_disk_usage(bin_dir: &str) -> Result<DiskUsageReport, String> {
    run_json(
        Command::new(Path::new(bin_dir).join("backmeup.disk.sh")).arg("--json"),
        "backmeup.disk.sh --json",
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
    const REAL_STATUS_JSON: &str = r#"{"sync_dir":"/tmp/bmudashboard_fixtures/sync","history_dir":"/tmp/bmudashboard_fixtures/sync-BP","projects":[{"name":"proj1","last_run":"2026-09-10 21:35:44","last_change":"20260910-213544","snapshot_count":1,"mirror_size_kb":4,"history_size_kb":12,"old_layout":false}]}"#;
    const REAL_LOCATE_JSON: &str = r#"{"patterns":["file1"],"indexed":true,"counts":{"index":2,"archived_filelist":0,"live":1},"results":[{"path":"/tmp/bmudashboard_fixtures/sync/proj1/file1.txt","source":"index"},{"path":"/tmp/bmudashboard_fixtures/sync-BP/proj1/B-20260910-213544/file1.txt","source":"index"},{"path":"/tmp/bmudashboard_fixtures/sync/proj1/file1.txt","source":"live"}]}"#;

    // Captured from a real `backmeup.disk.sh --json` run against the
    // same fixtures as the status JSON above: one project (proj1)
    // with a .bmureplicate-class sidecar that says "default", plus a
    // second project (lea) excluded from the estimate via "none".
    const REAL_DISK_JSON: &str = r#"{"sync_dir":"/tmp/bmudashboard_fixtures/sync","history_dir":"/tmp/bmudashboard_fixtures/sync-BP","sync_total_kb":44,"history_total_kb":12,"replicate_estimate_kb":16,"projects":[{"name":"proj1","sync_kb":4,"history_kb":12,"replicate_class":"default"},{"name":"lea","sync_kb":40,"history_kb":0,"replicate_class":"none"}]}"#;

    #[test]
    fn parses_real_status_json() {
        let parsed: StatusResult = serde_json::from_str(REAL_STATUS_JSON).unwrap();
        assert_eq!(parsed.projects.len(), 1);
        let p = &parsed.projects[0];
        assert_eq!(p.name, "proj1");
        assert_eq!(p.snapshot_count, 1);
        assert_eq!(p.mirror_size_kb, 4);
        assert_eq!(p.history_size_kb, Some(12));
        assert!(!p.old_layout);
    }

    #[test]
    fn parses_real_disk_json() {
        let parsed: DiskUsageReport = serde_json::from_str(REAL_DISK_JSON).unwrap();
        assert_eq!(parsed.sync_total_kb, 44);
        assert_eq!(parsed.history_total_kb, 12);
        // Estimate drops the lea project (replicate_class=none) but
        // keeps proj1 (default). 4 + 12 = 16, not 56.
        assert_eq!(parsed.replicate_estimate_kb, 16);
        assert_eq!(parsed.projects.len(), 2);
        let lea = parsed.projects.iter().find(|p| p.name == "lea").unwrap();
        assert_eq!(lea.replicate_class, "none");
        assert_eq!(lea.sync_kb, 40);
    }

    #[test]
    fn parses_phase1_disk_json_against_phase2_schema() {
        // Permanent regression guard: a Phase-1 install's output
        // (same bytes as REAL_DISK_JSON above - no `budget`, no
        // `volumes`, no per-project budget fields) must keep parsing
        // against the Phase-2 schema that added those sections.
        // #[serde(default)] on each new field is what makes this work;
        // a careless change dropping one of them would surface here.
        let parsed: DiskUsageReport = serde_json::from_str(REAL_DISK_JSON)
            .expect("Phase-2 schema must still parse Phase-1 output; a `#[serde(default)]` was \
                     probably dropped. Fix that, not this test.");
        assert_eq!(parsed.budget, DiskUsageBudget::default());
        assert_eq!(parsed.volumes, DiskUsageVolumes::default());
        for p in &parsed.projects {
            assert_eq!(p.sync_warn_bytes, None);
            assert_eq!(p.history_warn_bytes, None);
            assert!(!p.sync_over);
            assert!(!p.history_over);
        }
    }

    #[test]
    fn parses_phase2_disk_json_with_budget_and_volumes() {
        // Captured against a real Phase-2 CLI output: both budget
        // fields set (one over, one under), SYNC and HISTORY on the
        // same volume, per-project sidecar override on one project.
        let phase2 = r#"{"sync_dir":"/s","history_dir":"/h","sync_total_kb":100,"history_total_kb":2000,"replicate_estimate_kb":2100,"budget":{"sync_warn_bytes":1048576,"history_warn_bytes":1024,"sync_over":false,"history_over":true},"volumes":{"sync":{"mount":"/","total_kb":500000000,"avail_kb":100000000},"history":{"mount":"/","total_kb":500000000,"avail_kb":100000000},"same_volume":true},"projects":[{"name":"videos","sync_kb":80,"history_kb":1800,"replicate_class":"none","sync_warn_bytes":null,"history_warn_bytes":500,"sync_over":false,"history_over":true},{"name":"docs","sync_kb":20,"history_kb":200,"replicate_class":"default","sync_warn_bytes":null,"history_warn_bytes":null,"sync_over":false,"history_over":false}]}"#;
        let parsed: DiskUsageReport = serde_json::from_str(phase2).unwrap();
        assert_eq!(parsed.budget.sync_warn_bytes, Some(1048576));
        assert_eq!(parsed.budget.history_warn_bytes, Some(1024));
        assert!(!parsed.budget.sync_over);
        assert!(parsed.budget.history_over);
        assert_eq!(parsed.volumes.sync.mount.as_deref(), Some("/"));
        assert_eq!(parsed.volumes.same_volume, Some(true));
        let videos = parsed.projects.iter().find(|p| p.name == "videos").unwrap();
        assert_eq!(videos.history_warn_bytes, Some(500));
        assert!(videos.history_over);
    }

    #[test]
    fn parses_real_locate_json() {
        let parsed: LocateResult = serde_json::from_str(REAL_LOCATE_JSON).unwrap();
        assert!(parsed.indexed);
        assert_eq!(parsed.counts.index, 2);
        assert_eq!(parsed.counts.archived_filelist, 0);
        assert_eq!(parsed.counts.live, 1);
        assert_eq!(parsed.results.len(), 3);
        assert_eq!(parsed.results[0].source, "index");
        assert_eq!(parsed.results[2].source, "live");
    }

    // The CLI's permanent contract with any future GUI version - a
    // real bug, found by the user, that happened once already: a
    // previous change added a required "truncated" field to this
    // struct, so a GUI built against it hard-crashed against any
    // already-installed CLI whose backmeup.locate.sh predated that
    // field ("missing field `truncated`"). This exact shape (today's
    // real, minimal backmeup.locate.sh --json output) must keep
    // deserializing forever. If this test ever needs to change to
    // keep compiling, that's the signal a new LocateResult field was
    // added as required instead of #[serde(default)] - fix the field,
    // not this fixture.
    const MINIMAL_LOCATE_JSON_CONTRACT: &str =
        r#"{"patterns":["x"],"indexed":true,"counts":{"index":0,"archived_filelist":0,"live":0},"results":[]}"#;

    #[test]
    fn parses_the_minimal_locate_json_contract_forever() {
        let parsed: LocateResult =
            serde_json::from_str(MINIMAL_LOCATE_JSON_CONTRACT).expect(
                "a LocateResult field was added as required instead of #[serde(default)] - \
                 this must keep parsing an old CLI's output, not just today's",
            );
        assert!(parsed.results.is_empty());
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
        // no locate/updatedb run in this test - the live-filelist path
        // only, which is fine: this exercises the real subprocess + JSON
        // contract, not backmeup.locate.sh's own search logic (already
        // covered by tests/test_backmeup.sh). The live filelist is
        // written by backmeup.sh itself on every successful run, so this
        // finds hello.txt without ever running updatedb.
        assert_eq!(found.patterns, vec!["hello.txt".to_string()]);
        assert_eq!(found.counts.live, 1);
        assert!(found.results.iter().any(|r| r.source == "live"));
        // The real-CLI-binary version of the same contract as
        // parses_the_minimal_locate_json_contract_forever above: the
        // actual installed backmeup.locate.sh must never silently
        // drop a match - results.len() always equals the summed
        // counts, no server-side capping.
        let total_counts = found.counts.index + found.counts.archived_filelist + found.counts.live;
        assert_eq!(found.results.len() as u64, total_counts);

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
