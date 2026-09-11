mod config;
mod dashboard;
mod install;
mod run;
mod sources;
mod version;

use config::BackupSource;
use dashboard::{LocateResult, StatusResult};
use install::{DefaultPaths, InstallOutcome};
use run::RunOutput;
use serde::Deserialize;
use tauri::AppHandle;

#[tauri::command]
fn check_existing_install(app: AppHandle) -> Option<String> {
    let cfg = config::load(&app)?;
    let path = std::path::Path::new(&cfg.bin_dir);
    // An incompatible saved install is treated the same as a missing
    // one (falls through to the setup screen) rather than proceeding
    // into a dashboard that's guaranteed to fail on its first
    // get_status call.
    if config::looks_installed(path) && version::check_compatible(path).is_ok() {
        Some(cfg.bin_dir)
    } else {
        None
    }
}

#[tauri::command]
fn get_default_paths(app: AppHandle) -> Result<DefaultPaths, String> {
    install::default_paths(&app)
}

#[tauri::command]
fn find_existing_installs(app: AppHandle) -> Vec<String> {
    install::find_existing_installs(&app)
}

#[derive(Debug, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
enum InstallRequest {
    New {
        sync_dir: String,
        backup_dir: String,
        index_dir: String,
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
            install_dir,
        } => install::install_new(&app, &sync_dir, &backup_dir, &index_dir, &install_dir),
        InstallRequest::Existing { bin_dir } => install::use_existing(&app, &bin_dir),
    }
}

#[tauri::command]
fn get_status(bin_dir: String) -> Result<StatusResult, String> {
    dashboard::get_status(&bin_dir)
}

#[tauri::command]
fn search(bin_dir: String, patterns: Vec<String>) -> Result<LocateResult, String> {
    dashboard::search(&bin_dir, &patterns)
}

#[tauri::command]
fn list_sources(app: AppHandle) -> Vec<BackupSource> {
    sources::list(&app)
}

#[tauri::command]
fn add_source(app: AppHandle, path: String, name: Option<String>) -> Result<BackupSource, String> {
    sources::add(&app, &path, name.as_deref())
}

#[tauri::command]
fn remove_source(app: AppHandle, path: String) -> Result<(), String> {
    sources::remove(&app, &path)
}

#[tauri::command]
fn run_backup_now(bin_dir: String, source_path: String) -> Result<RunOutput, String> {
    run::run_backup_now(&bin_dir, &source_path)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            check_existing_install,
            get_default_paths,
            find_existing_installs,
            install_bmug2,
            get_status,
            search,
            list_sources,
            add_source,
            remove_source,
            run_backup_now
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
