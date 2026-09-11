// On-demand backup runs: shells out to backmeup.sh directly, no
// caching or state beyond what the call itself returns. Kept separate
// from dashboard.rs (read-only status/search) and sources.rs
// (persistence) - one module per concern, same split as the rest of
// this crate.
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RunOutput {
    pub log: String,
    pub ok: bool,
}

// Same merged-stdout+stderr-into-one-log shape as install.rs's own
// (private) run() helper - duplicated rather than shared across
// modules since it's three fields and each caller's doc-comment
// reasoning differs (install progress log vs. a backup run's log).
// backmeup.sh has no --json mode (only status/locate do), so a plain
// human-readable log is the right shape here, not structured JSON.
pub fn run_backup_now(bin_dir: &str, source_path: &str) -> Result<RunOutput, String> {
    let mut cmd = Command::new(Path::new(bin_dir).join("backmeup.sh"));
    cmd.arg(source_path);
    let name = format!("{cmd:?}");
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run {name}: {e}"))?;
    let mut log = String::new();
    log.push_str(&String::from_utf8_lossy(&output.stdout));
    log.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok(RunOutput {
        log,
        ok: output.status.success(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Real end-to-end, same shape as dashboard.rs's own
    /// get_status_and_search_work_end_to_end_for_real: build a real
    /// sandbox, run a real backup through run_backup_now, and assert
    /// the file actually landed in the mirror on disk - not just that
    /// the command exited 0.
    #[test]
    fn run_backup_now_actually_copies_the_file_for_real() {
        let repo_bin = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bin")
            .canonicalize()
            .expect("repo bin/ dir should exist");

        let base = std::env::temp_dir().join(format!("bmug2-run-test-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        let bin_dir = base.join("bin");
        let sync_dir = base.join("sync");
        let backup_dir = base.join("sync-BP");
        std::fs::create_dir_all(sync_dir.join(".locate.dir")).unwrap();
        std::fs::create_dir_all(&backup_dir).unwrap();
        copy_dir(&repo_bin, &bin_dir);

        let template = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh.template")).unwrap();
        let setup = template.replace("${HOME}/Backups/rsyncBackup", sync_dir.to_str().unwrap());
        std::fs::write(bin_dir.join("backmeup.setup.sh"), setup).unwrap();

        let src = base.join("src/proj1");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("hello.txt"), "hello run-now test").unwrap();

        let result = run_backup_now(bin_dir.to_str().unwrap(), src.to_str().unwrap())
            .expect("run_backup_now should succeed");
        assert!(result.ok, "backup should have succeeded: {}", result.log);

        let mirrored = sync_dir.join("proj1/hello.txt");
        assert!(
            mirrored.is_file(),
            "expected {} to exist after a real run",
            mirrored.display()
        );
        assert_eq!(
            std::fs::read_to_string(&mirrored).unwrap(),
            "hello run-now test"
        );

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn run_backup_now_surfaces_a_real_failure() {
        let base =
            std::env::temp_dir().join(format!("bmug2-run-fail-test-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        std::fs::create_dir_all(&base).unwrap();
        // no backmeup.sh at all under this bin_dir - Command::output()
        // itself fails to spawn, exercising the "failed to run" path.
        let result = run_backup_now(base.to_str().unwrap(), "/tmp");
        assert!(result.is_err());
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
