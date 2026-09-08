// Persisted app config: just the installed bin directory. Hand-rolled
// (serde + std::fs) rather than pulling in tauri-plugin-store for one
// key - matches this GUI's whole "shell out, minimal dependencies"
// stance already established for the install flow itself.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub bin_dir: String,
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

pub fn load(app: &AppHandle) -> Option<Config> {
    let path = config_path(app).ok()?;
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

pub fn save(app: &AppHandle, bin_dir: &str) -> Result<(), String> {
    let path = config_path(app)?;
    let cfg = Config {
        bin_dir: bin_dir.to_string(),
    };
    let data = serde_json::to_string_pretty(&cfg)
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
