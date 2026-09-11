// Persisted app config: just the installed bin directory. Hand-rolled
// (serde + std::fs) rather than pulling in tauri-plugin-store for one
// key - matches this GUI's whole "shell out, minimal dependencies"
// stance already established for the install flow itself.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupSource {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub bin_dir: String,
    // Missing in any config.json written before this field existed -
    // defaults to empty rather than failing to parse the rest of an
    // otherwise-valid saved config.
    #[serde(default)]
    pub sources: Vec<BackupSource>,
}

fn config_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("cannot resolve app data directory: {e}"))?;
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("cannot create app data directory {}: {e}", dir.display()))?;
    Ok(dir.join("config.json"))
}

// Collapses three different causes (no config file yet, app data dir
// unresolvable, or a corrupt/unparseable config.json) into one None -
// deliberately: every caller's response to "no usable saved config" is
// identical (fall back to the setup screen), so there's nothing a
// caller could do differently by distinguishing them.
pub fn load(app: &AppHandle) -> Option<Config> {
    let path = config_path(app).ok()?;
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

pub fn save(app: &AppHandle, bin_dir: &str) -> Result<(), String> {
    // Preserves any already-saved sources rather than wiping them -
    // this runs on both first install and "use an existing install",
    // and a user re-pointing at the same bin_dir shouldn't lose their
    // tracked backup sources.
    let sources = load(app).map(|cfg| cfg.sources).unwrap_or_default();
    write(
        app,
        &Config {
            bin_dir: bin_dir.to_string(),
            sources,
        },
    )
}

// Sources are a separate concern from the install-flow's bin_dir -
// this rewrites only that slice of the saved config, loading whatever
// bin_dir is already there. Callers only reach this after install has
// already run (the frontend has no UI path to it before that), so a
// missing config here means something upstream is broken, not a
// state this needs to paper over.
pub fn save_sources(app: &AppHandle, sources: &[BackupSource]) -> Result<(), String> {
    let mut cfg = load(app).ok_or("no bmug2 install configured yet")?;
    cfg.sources = sources.to_vec();
    write(app, &cfg)
}

fn write(app: &AppHandle, cfg: &Config) -> Result<(), String> {
    let path = config_path(app)?;
    let data = serde_json::to_string_pretty(cfg)
        .map_err(|e| format!("cannot serialize config: {e}"))?;
    std::fs::write(&path, data)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// A bin dir "looks like" a real bmug2 install if it has both the
/// entry-point script and a configure.sh-generated setup file - the
/// exact same check mcp/src/bmug2_mcp/config.py's load_config already
/// makes (mirrored, not shared code, since this is Rust not Python).
pub fn looks_installed(bin_dir: &Path) -> bool {
    bin_dir.join("backmeup.sh").is_file() && bin_dir.join("backmeup.setup.sh").is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_installed_requires_both_files() {
        let tmp = std::env::temp_dir().join(format!("bmug2-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        assert!(!looks_installed(&tmp));
        std::fs::write(tmp.join("backmeup.sh"), "").unwrap();
        assert!(!looks_installed(&tmp));
        std::fs::write(tmp.join("backmeup.setup.sh"), "").unwrap();
        assert!(looks_installed(&tmp));
        std::fs::remove_dir_all(&tmp).unwrap();
    }
}
