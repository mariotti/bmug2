mod config;
mod dashboard;
mod ignore;
mod install;
mod proton_browse;
mod rclone_browse;
mod replication;
mod run;
mod schedule;
mod sources;
mod version;

use config::{BackupSource, Schedule};
use dashboard::{LocateResult, StatusResult};
use install::{DefaultPaths, InstallOutcome, UpdateCheck};
use proton_browse::RemoteEntry;
use rclone_browse::RemoteEntry as RcloneRemoteEntry;
use replication::{ReplicationRequest, ReplicationStatus};
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
fn check_for_update(bin_dir: String) -> Result<UpdateCheck, String> {
    install::check_for_update(std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn apply_update(app: AppHandle, bin_dir: String) -> Result<InstallOutcome, String> {
    install::apply_update(&app, std::path::Path::new(&bin_dir))
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

#[tauri::command]
fn run_housekeeping_now(bin_dir: String) -> Result<RunOutput, String> {
    run::run_housekeeping_now(&bin_dir)
}

#[tauri::command]
fn set_source_schedule(
    app: AppHandle,
    bin_dir: String,
    source_path: String,
    schedule: Schedule,
) -> Result<(), String> {
    let label = schedule::source_label(&source_path);
    let wrapper = schedule::build_source_wrapper(&bin_dir, &source_path);
    schedule::install(&label, &wrapper, &schedule, &format!("bmug2 backup ({source_path})"))?;
    config::set_source_schedule(&app, &source_path, Some(schedule))
}

#[tauri::command]
fn clear_source_schedule(app: AppHandle, source_path: String) -> Result<(), String> {
    schedule::uninstall(&schedule::source_label(&source_path))?;
    config::set_source_schedule(&app, &source_path, None)
}

#[tauri::command]
fn get_housekeeping_schedule() -> Option<Schedule> {
    schedule::status(schedule::HOUSEKEEPING_LABEL)
}

#[tauri::command]
fn set_housekeeping_schedule(app: AppHandle, bin_dir: String, schedule: Schedule) -> Result<(), String> {
    let wrapper = schedule::build_housekeeping_wrapper(&bin_dir);
    schedule::install(
        schedule::HOUSEKEEPING_LABEL,
        &wrapper,
        &schedule,
        "bmug2 housekeeping (updatedb/replicate)",
    )?;
    config::set_housekeeping_schedule(&app, Some(schedule))
}

#[tauri::command]
fn has_full_disk_access() -> bool {
    schedule::has_full_disk_access()
}

#[tauri::command]
fn clear_housekeeping_schedule(app: AppHandle) -> Result<(), String> {
    schedule::uninstall(schedule::HOUSEKEEPING_LABEL)?;
    config::set_housekeeping_schedule(&app, None)
}

#[tauri::command]
fn get_ignore_settings(bin_dir: String, source_path: String) -> Result<ignore::IgnoreSettings, String> {
    ignore::get(std::path::Path::new(&bin_dir), &source_path)
}

#[tauri::command]
fn set_ignore_settings(
    bin_dir: String,
    source_path: String,
    settings: ignore::IgnoreSettingsInput,
) -> Result<(), String> {
    ignore::set(std::path::Path::new(&bin_dir), &source_path, settings)
}

#[tauri::command]
fn get_replication_status(bin_dir: String) -> ReplicationStatus {
    replication::get_status(std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn get_replication_capability(bin_dir: String) -> Result<(), String> {
    replication::check_flags_supported(std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn set_replication(bin_dir: String, request: ReplicationRequest) -> Result<(), String> {
    replication::set(std::path::Path::new(&bin_dir), request)
}

#[tauri::command]
fn clear_replication(bin_dir: String) -> Result<(), String> {
    replication::clear(std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn proton_drive_available() -> bool {
    proton_browse::available()
}

#[tauri::command]
fn proton_drive_signed_in() -> bool {
    proton_browse::signed_in()
}

#[tauri::command]
fn list_proton_folder(path: String) -> Result<Vec<RemoteEntry>, String> {
    proton_browse::list_folder(&path)
}

#[tauri::command]
fn create_proton_folder(parent: String, name: String) -> Result<(), String> {
    proton_browse::create_folder(&parent, &name)
}

#[tauri::command]
fn proton_drive_login() -> Result<(), String> {
    proton_browse::login()
}

#[tauri::command]
fn rclone_available() -> bool {
    rclone_browse::available()
}

#[tauri::command]
fn list_drive_remotes() -> Result<Vec<String>, String> {
    rclone_browse::list_drive_remotes()
}

#[tauri::command]
fn list_rclone_folder(path: String) -> Result<Vec<RcloneRemoteEntry>, String> {
    rclone_browse::list_folder(&path)
}

#[tauri::command]
fn create_rclone_folder(path: String) -> Result<(), String> {
    rclone_browse::create_folder(&path)
}

#[tauri::command]
fn create_drive_remote(name: String) -> Result<(), String> {
    rclone_browse::create_drive_remote(&name)
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
            run_backup_now,
            run_housekeeping_now,
            set_source_schedule,
            clear_source_schedule,
            get_housekeeping_schedule,
            set_housekeeping_schedule,
            clear_housekeeping_schedule,
            has_full_disk_access,
            get_ignore_settings,
            set_ignore_settings,
            get_replication_status,
            get_replication_capability,
            set_replication,
            clear_replication,
            check_for_update,
            apply_update,
            proton_drive_available,
            proton_drive_signed_in,
            list_proton_folder,
            create_proton_folder,
            proton_drive_login,
            rclone_available,
            list_drive_remotes,
            list_rclone_folder,
            create_rclone_folder,
            create_drive_remote
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
