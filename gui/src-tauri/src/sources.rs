// Backup Sources: a GUI-owned list of "these are the folders I back
// up," persisted via config.rs. bmug2 itself has no equivalent - a
// backmeup.sh run takes a directory argument and doesn't remember it,
// and backmeup.status.sh only reports projects already backed up at
// least once (by scanning SYNC_DIR), with no record of their original
// source path. Run Now (run.rs) and, later, scheduling both need a
// name->source-path list to operate on, so this is where it lives.
use crate::config::{self, BackupSource};
use crate::schedule;
use std::path::Path;
use tauri::AppHandle;

// Reconciles each source's schedule field against the installed
// launchd/systemd artifact (the real source of truth - see
// schedule.rs's own module doc) rather than trusting config.json
// blindly, self-healing drift (e.g. a schedule removed outside the
// app) and persisting the correction. A raw config::load without
// reconciliation would be cheaper but could show a schedule as "on"
// when nothing is actually installed to run it.
pub fn list(app: &AppHandle) -> Vec<BackupSource> {
    let mut sources = config::load(app).map(|cfg| cfg.sources).unwrap_or_default();
    let mut changed = false;
    for source in sources.iter_mut() {
        let actual = schedule::status(&schedule::source_label(&source.path));
        if actual != source.schedule {
            source.schedule = actual;
            changed = true;
        }
    }
    if changed {
        let _ = config::save_sources(app, &sources);
    }
    sources
}

pub fn add(app: &AppHandle, path: &str, name: Option<&str>) -> Result<BackupSource, String> {
    let mut sources = list(app);
    let source = build_source(&sources, path, name)?;
    sources.push(source.clone());
    config::save_sources(app, &sources)?;
    Ok(source)
}

pub fn remove(app: &AppHandle, path: &str) -> Result<(), String> {
    let mut sources = list(app);
    let before = sources.len();
    // Best-effort: a launchctl/systemctl hiccup shouldn't block the
    // user from removing a folder they no longer want tracked - an
    // orphaned job left behind by a failed uninstall is a smaller
    // problem than "Remove doesn't work," and list()'s reconciliation
    // above will keep self-correcting the displayed status regardless.
    let _ = schedule::uninstall(&schedule::source_label(path));
    sources.retain(|s| s.path != path);
    if sources.len() == before {
        return Err(format!("no backup source tracked at {path}"));
    }
    config::save_sources(app, &sources)
}

// AppHandle-independent by design, mirroring install.rs's
// find_existing_installs/find_existing_installs_under split - lets
// the validation/dedup/naming logic be tested directly without
// constructing a real Tauri app context.
fn build_source(
    existing: &[BackupSource],
    path: &str,
    name: Option<&str>,
) -> Result<BackupSource, String> {
    let p = Path::new(path);
    if !p.is_absolute() {
        return Err(format!("path must be absolute: {path}"));
    }
    if !p.is_dir() {
        return Err(format!("not a directory: {path}"));
    }
    if existing.iter().any(|s| s.path == path) {
        return Err(format!("already tracked as a backup source: {path}"));
    }
    let name = match name {
        Some(n) if !n.trim().is_empty() => n.trim().to_string(),
        _ => p
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .ok_or_else(|| format!("cannot derive a name from path: {path}"))?,
    };
    Ok(BackupSource {
        name,
        path: path.to_string(),
        schedule: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(label: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bmug2-sources-test-{label}-{}",
            std::process::id()
        ));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn rejects_relative_path() {
        let err = build_source(&[], "relative/path", None).unwrap_err();
        assert!(err.contains("absolute"), "{err}");
    }

    #[test]
    fn rejects_missing_directory() {
        let path = std::env::temp_dir()
            .join("bmug2-sources-test-does-not-exist")
            .display()
            .to_string();
        let err = build_source(&[], &path, None).unwrap_err();
        assert!(err.contains("not a directory"), "{err}");
    }

    #[test]
    fn defaults_name_to_basename() {
        let dir = tmp_dir("basename");
        let source = build_source(&[], dir.to_str().unwrap(), None).unwrap();
        assert_eq!(source.name, dir.file_name().unwrap().to_str().unwrap());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn explicit_name_overrides_basename() {
        let dir = tmp_dir("explicit-name");
        let source = build_source(&[], dir.to_str().unwrap(), Some("My Documents")).unwrap();
        assert_eq!(source.name, "My Documents");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_duplicate_path() {
        let dir = tmp_dir("dup");
        let existing = vec![BackupSource {
            name: "already-here".to_string(),
            path: dir.to_str().unwrap().to_string(),
            schedule: None,
        }];
        let err = build_source(&existing, dir.to_str().unwrap(), None).unwrap_err();
        assert!(err.contains("already tracked"), "{err}");
        std::fs::remove_dir_all(&dir).ok();
    }
}
