// Per-source "kind" sidecar read/write - the authoritative state
// backmeup.archive.sh reads at run time to decide whether to run
// its tar -czf (generic) or tar -cf (media) path. Same shape as
// replication::read_source_class / set_source_class, just a
// different sidecar filename: ${BMU_DIRBACKUPS}/<project>/.bmukind,
// a plain-text one-liner ("generic" / "media"). See
// config::SourceKind for the policy itself.
use crate::config::SourceKind;
use std::path::{Path, PathBuf};

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

fn sidecar(bin_dir: &Path, source_path: &str) -> Option<PathBuf> {
    let history_dir = read_setup_var(bin_dir, "BMU_DIRBACKUPS")?;
    let project = Path::new(source_path).file_name()?.to_string_lossy().to_string();
    Some(PathBuf::from(history_dir).join(project).join(".bmukind"))
}

/// Reads `.bmukind` for a source. Returns Generic when the sidecar
/// is missing, unreadable, or contains anything other than "media"
/// (after trim). A mistyped sidecar silently falls back to current
/// behavior rather than erroring at archive time - safer default
/// than refusing to archive.
pub fn read(bin_dir: &Path, source_path: &str) -> SourceKind {
    let Some(path) = sidecar(bin_dir, source_path) else {
        return SourceKind::Generic;
    };
    match std::fs::read_to_string(&path) {
        Ok(contents) => match contents.trim() {
            "media" => SourceKind::Media,
            _ => SourceKind::Generic,
        },
        Err(_) => SourceKind::Generic,
    }
}

pub fn set(bin_dir: &Path, source_path: &str, kind: SourceKind) -> Result<(), String> {
    let path = sidecar(bin_dir, source_path).ok_or_else(|| {
        format!(
            "cannot resolve BMU_DIRBACKUPS from {} - reinstall or re-run configure.sh",
            bin_dir.display()
        )
    })?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("cannot determine parent of {}", path.display()))?;
    // Project HISTORY dir may not exist yet (new source, never backed
    // up). Settings must be persistable pre-first-backup - same
    // discipline as ignore::set and replication::set_source_class.
    std::fs::create_dir_all(parent)
        .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    let contents = match kind {
        SourceKind::Generic => "generic\n",
        SourceKind::Media => "media\n",
    };
    std::fs::write(&path, contents)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sandbox(name: &str) -> (PathBuf, PathBuf) {
        let bin = std::env::temp_dir().join(format!(
            "bmug2-sourcekind-bin-{name}-{}",
            std::process::id()
        ));
        let bp = std::env::temp_dir().join(format!(
            "bmug2-sourcekind-bp-{name}-{}",
            std::process::id()
        ));
        std::fs::remove_dir_all(&bin).ok();
        std::fs::remove_dir_all(&bp).ok();
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&bp).unwrap();
        std::fs::write(
            bin.join("backmeup.setup.sh"),
            format!("BMU_DIRBACKUPS=\"{}\"\n", bp.display()),
        )
        .unwrap();
        (bin, bp)
    }

    #[test]
    fn read_defaults_to_generic_when_sidecar_missing() {
        // Pre-this-feature install has no sidecar for any source.
        // Must map to the current behavior (Generic) or we'd silently
        // change archive output for every existing user.
        let (bin, _bp) = sandbox("read-missing");
        assert_eq!(read(&bin, "/src/proj"), SourceKind::Generic);
    }

    #[test]
    fn read_returns_media_when_sidecar_says_media() {
        let (bin, bp) = sandbox("read-media");
        let proj = bp.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::write(proj.join(".bmukind"), "media\n").unwrap();
        assert_eq!(read(&bin, "/src/proj"), SourceKind::Media);
    }

    #[test]
    fn read_treats_typo_as_generic_not_error() {
        // A mistyped sidecar (e.g. "video" instead of "media") must
        // fall back to current behavior, not fail archive at run
        // time. Same risk-free-fallback discipline as
        // replication::read_source_class.
        let (bin, bp) = sandbox("read-typo");
        let proj = bp.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::write(proj.join(".bmukind"), "video\n").unwrap();
        assert_eq!(read(&bin, "/src/proj"), SourceKind::Generic);
    }

    #[test]
    fn set_writes_the_sidecar_and_round_trips() {
        let (bin, bp) = sandbox("set-media");
        set(&bin, "/src/proj", SourceKind::Media).unwrap();
        let sc = bp.join("proj").join(".bmukind");
        assert!(sc.exists(), "sidecar must be created");
        assert_eq!(std::fs::read_to_string(&sc).unwrap().trim(), "media");
        assert_eq!(read(&bin, "/src/proj"), SourceKind::Media);
    }

    #[test]
    fn set_generic_writes_generic_explicitly() {
        // Same reasoning as replicate_class::set Default: write
        // "generic" (not delete the sidecar) so a subsequent
        // reconcile reads a concrete value.
        let (bin, bp) = sandbox("set-generic");
        set(&bin, "/src/proj", SourceKind::Generic).unwrap();
        let sc = bp.join("proj").join(".bmukind");
        assert_eq!(std::fs::read_to_string(&sc).unwrap().trim(), "generic");
    }

    #[test]
    fn set_creates_project_history_dir_if_missing() {
        // GUI may set kind on a source that's never been backed up
        // yet - HISTORY/<project>/ wouldn't exist. Must be
        // persistable pre-first-backup, same as other per-source
        // settings.
        let (bin, bp) = sandbox("set-no-dir");
        let proj = bp.join("fresh");
        assert!(!proj.exists());
        set(&bin, "/src/fresh", SourceKind::Media).unwrap();
        assert!(proj.join(".bmukind").exists());
    }
}
