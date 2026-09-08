mod config;
mod install;

use install::{DefaultPaths, InstallOutcome};
use serde::Deserialize;
use tauri::AppHandle;

#[tauri::command]
fn check_existing_install(app: AppHandle) -> Option<String> {
    let cfg = config::load(&app)?;
    let path = std::path::Path::new(&cfg.bin_dir);
    if config::looks_installed(path) {
        Some(cfg.bin_dir)
    } else {
        None
    }
}

#[tauri::command]
fn get_default_paths(app: AppHandle) -> Result<DefaultPaths, String> {
    install::default_paths(&app)
}

#[derive(Debug, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
enum InstallRequest {
    New {
        sync_dir: String,
        backup_dir: String,
        index_dir: String,
        install_path: String,
        install_dir: String,
    },
    Existing {
        bin_dir: String,
    },
}

#[tauri::command]
fn install_bmug2(app: AppHandle, request: InstallRequest) -> Result<InstallOutcome, String> {
    match request {
        InstallRequest::New {
            sync_dir,
            backup_dir,
            index_dir,
            install_path,
            install_dir,
        } => install::install_new(
            &app,
            &sync_dir,
            &backup_dir,
            &index_dir,
            &install_path,
            &install_dir,
        ),
        InstallRequest::Existing { bin_dir } => install::use_existing(&app, &bin_dir),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            check_existing_install,
            get_default_paths,
            install_bmug2
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
