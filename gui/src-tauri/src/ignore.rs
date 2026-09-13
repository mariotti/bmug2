// Per-project .gitignore/.bmuignore backup-exclude settings - the GUI
// counterpart to bin/backmeup.sh's own HISTORY/<project>/.bmuconfig
// (BMU_GITIGNORE/BMU_BMUIGNORE) and <source>/.bmuignore handling. Two
// separate files in two separate locations (destination-side settings
// vs. a file that lives in the source tree itself, same place as a
// real .gitignore), treated as one combined "ignore settings" concept
// here since that's how a user thinks about them.
use std::path::{Path, PathBuf};

#[derive(serde::Serialize)]
pub struct IgnoreSettings {
    pub gitignore: bool,
    pub gitignore_exists: bool,
    pub bmuignore: bool,
    pub bmuignore_content: String,
}

#[derive(serde::Deserialize)]
pub struct IgnoreSettingsInput {
    pub gitignore: bool,
    pub bmuignore: bool,
    pub bmuignore_content: String,
}

// Same KEY="value" line-scan idiom as version.rs::read_installed_version
// (and schedule.rs::replication_configured) - not a real shell parser,
// just enough to pull one variable out of a generated setup file.
fn read_setup_var(bin_dir: &Path, key: &str) -> Option<String> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh")).ok()?;
    let prefix = format!("{key}=\"");
    for line in contents.lines() {
        if let Some(rest) = line.trim().strip_prefix(&prefix) {
            return rest.strip_suffix('"').map(str::to_string);
        }
    }
    None
}

fn project_name(source_path: &str) -> String {
    Path::new(source_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| source_path.to_string())
}

fn bmuconfig_path(bin_dir: &Path, source_path: &str) -> Result<PathBuf, String> {
    let history_dir = read_setup_var(bin_dir, "BMU_DIRBACKUPS")
        .ok_or_else(|| format!("cannot read BMU_DIRBACKUPS from {}", bin_dir.display()))?;
    Ok(Path::new(&history_dir)
        .join(project_name(source_path))
        .join(".bmuconfig"))
}

pub fn get(bin_dir: &Path, source_path: &str) -> Result<IgnoreSettings, String> {
    let cfg_path = bmuconfig_path(bin_dir, source_path)?;
    let cfg_contents = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let read_key = |key: &str| -> Option<String> {
        let prefix = format!("{key}=\"");
        cfg_contents.lines().find_map(|line| {
            line.trim()
                .strip_prefix(&prefix)
                .and_then(|rest| rest.strip_suffix('"'))
                .map(str::to_string)
        })
    };
    // Mirrors backmeup.sh's own ${BMU_GITIGNORE:-yes}/${BMU_BMUIGNORE:-no}
    // defaults exactly - unset or anything but "no" respects .gitignore,
    // unset or anything but "yes" leaves .bmuignore inert.
    let gitignore = read_key("BMU_GITIGNORE").as_deref() != Some("no");
    let bmuignore = read_key("BMU_BMUIGNORE").as_deref() == Some("yes");

    let source_dir = Path::new(source_path);
    let gitignore_exists = source_dir.join(".gitignore").is_file();
    let bmuignore_content =
        std::fs::read_to_string(source_dir.join(".bmuignore")).unwrap_or_default();

    Ok(IgnoreSettings {
        gitignore,
        gitignore_exists,
        bmuignore,
        bmuignore_content,
    })
}

pub fn set(bin_dir: &Path, source_path: &str, input: IgnoreSettingsInput) -> Result<(), String> {
    let cfg_path = bmuconfig_path(bin_dir, source_path)?;
    let parent = cfg_path
        .parent()
        .ok_or_else(|| format!("cannot determine parent directory of {}", cfg_path.display()))?;
    // The project may never have been backed up yet, so HISTORY/<project>/
    // might not exist - settings should still be persistable ahead of the
    // first run, same as scheduling already is.
    std::fs::create_dir_all(parent)
        .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    let cfg_contents = format!(
        "BMU_GITIGNORE=\"{}\"\nBMU_BMUIGNORE=\"{}\"\n",
        if input.gitignore { "yes" } else { "no" },
        if input.bmuignore { "yes" } else { "no" },
    );
    std::fs::write(&cfg_path, cfg_contents)
        .map_err(|e| format!("cannot write {}: {e}", cfg_path.display()))?;

    let bmuignore_path = Path::new(source_path).join(".bmuignore");
    std::fs::write(&bmuignore_path, &input.bmuignore_content)
        .map_err(|e| format!("cannot write {}: {e}", bmuignore_path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bmug2-ignore-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fake_bin_dir(name: &str, history_dir: &Path) -> PathBuf {
        let bin_dir = scratch(&format!("bindir-{name}"));
        std::fs::write(
            bin_dir.join("backmeup.setup.sh"),
            format!("BMU_DIRBACKUPS=\"{}\"\n", history_dir.display()),
        )
        .unwrap();
        bin_dir
    }

    #[test]
    fn defaults_when_bmuconfig_is_missing() {
        let history_dir = scratch("history-defaults");
        let bin_dir = fake_bin_dir("defaults", &history_dir);
        let source_dir = scratch("source-defaults");

        let settings = get(&bin_dir, source_dir.to_str().unwrap()).unwrap();
        assert!(settings.gitignore, "gitignore should default to respected");
        assert!(!settings.bmuignore, "bmuignore should default to inert");
        assert!(!settings.gitignore_exists);
        assert_eq!(settings.bmuignore_content, "");
    }

    #[test]
    fn set_then_get_round_trips() {
        let history_dir = scratch("history-roundtrip");
        let bin_dir = fake_bin_dir("roundtrip", &history_dir);
        let source_dir = scratch("source-roundtrip");
        std::fs::write(source_dir.join(".gitignore"), "*.log\n").unwrap();

        set(
            &bin_dir,
            source_dir.to_str().unwrap(),
            IgnoreSettingsInput {
                gitignore: false,
                bmuignore: true,
                bmuignore_content: "node_modules/\n*.tmp\n".to_string(),
            },
        )
        .unwrap();

        let settings = get(&bin_dir, source_dir.to_str().unwrap()).unwrap();
        assert!(!settings.gitignore);
        assert!(settings.bmuignore);
        assert!(settings.gitignore_exists);
        assert_eq!(settings.bmuignore_content, "node_modules/\n*.tmp\n");
    }

    #[test]
    fn set_creates_history_dir_when_project_never_ran() {
        let history_dir = scratch("history-not-yet-created");
        std::fs::remove_dir_all(&history_dir).unwrap(); // simulate: never backed up
        let bin_dir = fake_bin_dir("not-yet-created", &history_dir);
        let source_dir = scratch("source-not-yet-run");

        set(
            &bin_dir,
            source_dir.to_str().unwrap(),
            IgnoreSettingsInput {
                gitignore: true,
                bmuignore: false,
                bmuignore_content: String::new(),
            },
        )
        .unwrap();

        assert!(history_dir.join(project_name(source_dir.to_str().unwrap())).join(".bmuconfig").is_file());
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

    // Closes the actual loop this feature exists for: what the GUI
    // writes via ignore::set() is exactly what a real backmeup.sh run
    // reads and respects - not just that the two sides independently
    // agree on a file format. Same "real bmug2 sandbox, real rsync, no
    // mocks" pattern as dashboard.rs's/run.rs's own end-to-end tests.
    #[test]
    fn settings_written_by_set_are_actually_respected_by_a_real_backmeup_run() {
        let repo_bin = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../bin")
            .canonicalize()
            .expect("repo bin/ dir should exist");

        let base = std::env::temp_dir().join(format!("bmug2-ignore-e2e-test-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        let bin_dir = base.join("bin");
        let sync_dir = base.join("sync");
        let backup_dir = base.join("sync-BP");
        std::fs::create_dir_all(sync_dir.join(".locate.dir")).unwrap();
        std::fs::create_dir_all(&backup_dir).unwrap();
        copy_dir(&repo_bin, &bin_dir);

        // Unlike dashboard.rs's/run.rs's equivalent fixtures (which only
        // ever pass the setup file through to a real backmeup.sh
        // subprocess - a real shell resolves ${BMU_DIRRSYNC}-BP itself),
        // ignore.rs reads BMU_DIRBACKUPS directly in Rust via a plain
        // literal-string scan, so the template's unresolved shell
        // expression must be replaced with a real absolute path here,
        // matching what a real backmeup.configure.sh run actually
        // writes (confirmed: it persists already-resolved values, never
        // a variable reference).
        let template = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh.template")).unwrap();
        let setup = template
            .replace("${HOME}/Backups/rsyncBackup", sync_dir.to_str().unwrap())
            .replace(
                "BMU_DIRBACKUPS=\"${BMU_DIRRSYNC}-BP\"",
                &format!("BMU_DIRBACKUPS=\"{}\"", backup_dir.to_str().unwrap()),
            );
        std::fs::write(bin_dir.join("backmeup.setup.sh"), setup).unwrap();

        let src = base.join("src/e2eproj");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("keep.txt"), "keep").unwrap();
        std::fs::write(src.join("extra.dat"), "excluded via bmuignore").unwrap();

        set(
            &bin_dir,
            src.to_str().unwrap(),
            IgnoreSettingsInput {
                gitignore: true,
                bmuignore: true,
                bmuignore_content: "extra.dat\n".to_string(),
            },
        )
        .unwrap();

        let output = std::process::Command::new(bin_dir.join("backmeup.sh"))
            .arg(&src)
            .output()
            .expect("backmeup.sh should run");
        assert!(
            output.status.success(),
            "backmeup.sh failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        assert!(sync_dir.join("e2eproj/keep.txt").is_file());
        assert!(
            !sync_dir.join("e2eproj/extra.dat").exists(),
            ".bmuignore setting written by set() was not respected by the real backup run"
        );

        std::fs::remove_dir_all(&base).ok();
    }
}
