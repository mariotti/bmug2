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
use tauri::{AppHandle, LogicalSize, Manager};

// config.rs/sources.rs/install.rs no longer touch AppHandle at all -
// they take a plain app_data_dir/home_dir path instead, so their
// logic is testable with an ordinary tmp dir rather than needing
// Tauri's test machinery (which has no safe way to sandbox
// app_data_dir() - see the project notes on why MockRuntime was
// ruled out for this). This is the one place that resolution happens
// for real, mirroring config_path's former error message exactly.
fn resolve_app_data_dir(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    app.path()
        .app_data_dir()
        .map_err(|e| format!("cannot resolve app data directory: {e}"))
}

#[tauri::command]
fn check_existing_install(app: AppHandle) -> Option<String> {
    let app_data_dir = resolve_app_data_dir(&app).ok()?;
    let cfg = config::load(&app_data_dir)?;
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
    let home = app.path().home_dir().map_err(|e| format!("cannot resolve home directory: {e}"))?;
    Ok(install::default_paths(&home))
}

#[tauri::command]
fn find_existing_installs(app: AppHandle) -> Vec<String> {
    match app.path().home_dir() {
        Ok(home) => install::find_existing_installs(&home),
        Err(_) => Vec::new(),
    }
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
    let app_data_dir = resolve_app_data_dir(&app)?;
    match request {
        InstallRequest::New {
            sync_dir,
            backup_dir,
            index_dir,
            install_dir,
        } => install::install_new(&app_data_dir, &sync_dir, &backup_dir, &index_dir, &install_dir),
        InstallRequest::Existing { bin_dir } => install::use_existing(&app_data_dir, &bin_dir),
    }
}

#[tauri::command]
fn check_for_update(bin_dir: String) -> Result<UpdateCheck, String> {
    install::check_for_update(std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn apply_update(app: AppHandle, bin_dir: String) -> Result<InstallOutcome, String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    install::apply_update(&app_data_dir, std::path::Path::new(&bin_dir))
}

#[tauri::command]
fn get_status(bin_dir: String) -> Result<StatusResult, String> {
    dashboard::get_status(&bin_dir)
}

// Same bug class already fixed for run_backup_now/run_housekeeping_now
// above: a plain (non-async) command runs on Tauri's main thread, so a
// slow backmeup.locate.sh call (an unselective single-letter pattern
// against a large install) froze the whole app, not just this one
// panel - confirmed real by the user. No live-progress events needed
// here, unlike those two, so this is just async + spawn_blocking with
// nothing emitted.
#[tauri::command]
async fn search(bin_dir: String, patterns: Vec<String>) -> Result<LocateResult, String> {
    tauri::async_runtime::spawn_blocking(move || dashboard::search(&bin_dir, &patterns))
        .await
        .map_err(|e| format!("background task panicked: {e}"))?
}

#[tauri::command]
fn list_sources(app: AppHandle) -> Vec<BackupSource> {
    match resolve_app_data_dir(&app) {
        Ok(dir) => sources::list(&dir),
        Err(_) => Vec::new(),
    }
}

#[tauri::command]
fn add_source(app: AppHandle, path: String, name: Option<String>) -> Result<BackupSource, String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    sources::add(&app_data_dir, &path, name.as_deref())
}

#[tauri::command]
fn remove_source(app: AppHandle, path: String) -> Result<(), String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    sources::remove(&app_data_dir, &path)
}

// A plain (non-async) #[tauri::command] runs on Tauri's main thread - run_step's
// blocking child-process read loop would sit there for the whole job, freezing
// window repaints and event handling the entire time (the macOS "system
// spinner" + a blank window on app-switch a real run surfaced, not caught by
// any test here since cargo test calls run.rs directly, with no Tauri dispatch
// involved, and every frontend test mocks invoke entirely). spawn_blocking
// moves the actual blocking work onto Tauri's dedicated blocking-thread pool,
// matching Tauri's own documented pattern for this exact situation.
#[tauri::command]
async fn run_backup_now(app: AppHandle, bin_dir: String, source_path: String) -> Result<RunOutput, String> {
    use tauri::Emitter;
    tauri::async_runtime::spawn_blocking(move || {
        run::run_backup_now(&bin_dir, &source_path, move |line| {
            let _ = app.emit("backup-progress", line);
        })
    })
    .await
    .map_err(|e| format!("background task panicked: {e}"))?
}

#[tauri::command]
async fn run_housekeeping_now(app: AppHandle, bin_dir: String) -> Result<RunOutput, String> {
    use tauri::Emitter;
    tauri::async_runtime::spawn_blocking(move || {
        run::run_housekeeping_now(&bin_dir, move |line| {
            let _ = app.emit("housekeeping-progress", line);
        })
    })
    .await
    .map_err(|e| format!("background task panicked: {e}"))?
}

#[tauri::command]
fn set_source_schedule(
    app: AppHandle,
    bin_dir: String,
    source_path: String,
    schedule: Schedule,
) -> Result<(), String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    let label = schedule::source_label(&source_path);
    let hint = schedule::source_file_hint(&source_path);
    let wrapper = schedule::build_source_wrapper(&bin_dir, &source_path);
    schedule::install(&label, &wrapper, &schedule, &format!("bmug2 backup ({source_path})"), &hint)?;
    config::set_source_schedule(&app_data_dir, &source_path, Some(schedule))
}

#[tauri::command]
fn clear_source_schedule(app: AppHandle, source_path: String) -> Result<(), String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    schedule::uninstall(&schedule::source_label(&source_path), &schedule::source_file_hint(&source_path))?;
    config::set_source_schedule(&app_data_dir, &source_path, None)
}

#[tauri::command]
fn get_housekeeping_schedule() -> Option<Schedule> {
    schedule::status(schedule::HOUSEKEEPING_LABEL, "")
}

#[tauri::command]
fn set_housekeeping_schedule(app: AppHandle, bin_dir: String, schedule: Schedule) -> Result<(), String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    let wrapper = schedule::build_housekeeping_wrapper(&bin_dir);
    schedule::install(
        schedule::HOUSEKEEPING_LABEL,
        &wrapper,
        &schedule,
        "bmug2 housekeeping (updatedb/replicate)",
        "",
    )?;
    config::set_housekeeping_schedule(&app_data_dir, Some(schedule))
}

#[tauri::command]
fn has_full_disk_access() -> bool {
    schedule::has_full_disk_access()
}

#[tauri::command]
fn clear_housekeeping_schedule(app: AppHandle) -> Result<(), String> {
    let app_data_dir = resolve_app_data_dir(&app)?;
    schedule::uninstall(schedule::HOUSEKEEPING_LABEL, "")?;
    config::set_housekeeping_schedule(&app_data_dir, None)
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

#[tauri::command]
fn find_gdrive_mount() -> Option<String> {
    replication::find_gdrive_mount()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        // tauri.conf.json's static 800x600 is just a fallback for when
        // this fails - real sizing is a fraction of whichever monitor
        // the window actually opens on, not one fixed pixel size that
        // happens to look right on a single screen. Best-effort: a
        // missing monitor (e.g. a weird CI/headless environment) just
        // keeps the static fallback instead of failing the whole app.
        .setup(|app| {
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(Some(monitor)) = window.current_monitor() {
                    let physical = monitor.size();
                    let scale = monitor.scale_factor();
                    let width = physical.width as f64 / scale * 0.7;
                    let height = physical.height as f64 / scale * 0.7;
                    let _ = window.set_size(LogicalSize::new(width, height));
                    let _ = window.center();
                }
            }
            Ok(())
        })
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
            create_drive_remote,
            find_gdrive_mount
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    // A bin_dir that was never set up at all - every wrapper below is
    // expected to error cleanly against it (no backmeup.setup.sh to read a
    // version marker, BMU_DIRBACKUPS, or a replicate backend from), never
    // panic or fall through to a real subprocess call. One fresh directory
    // per call so parallel test threads never collide.
    fn bogus_bin_dir(label: &str) -> String {
        let dir = std::env::temp_dir().join(format!("bmug2-libtest-{label}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir.to_str().unwrap().to_string()
    }

    // These wrappers are one-line delegations to already-thoroughly-tested
    // modules (dashboard.rs 91%, ignore.rs 96%, replication.rs 99%) - the
    // point here isn't re-proving that business logic, it's covering the
    // delegation line itself and confirming args/errors actually pass
    // through lib.rs's own command boundary intact.

    #[test]
    fn get_status_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        assert!(get_status(bogus_bin_dir("get-status")).is_err());
    }

    #[test]
    fn search_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        // search is now async (spawn_blocking, same as run_backup_now/
        // run_housekeeping_now) - block_on drives it inline without
        // pulling in a new async-test dependency; it's the same
        // runtime the production code already depends on.
        let result = tauri::async_runtime::block_on(search(
            bogus_bin_dir("search"),
            vec!["x".to_string()],
        ));
        assert!(result.is_err());
    }

    #[test]
    fn get_ignore_settings_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        assert!(get_ignore_settings(bogus_bin_dir("ignore-get"), "/tmp/proj1".to_string()).is_err());
    }

    #[test]
    fn set_ignore_settings_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        let settings = ignore::IgnoreSettingsInput {
            gitignore: true,
            bmuignore: false,
            bmuignore_content: String::new(),
        };
        assert!(set_ignore_settings(bogus_bin_dir("ignore-set"), "/tmp/proj1".to_string(), settings).is_err());
    }

    // get_replication_status is documented as "always safe to call, even
    // against an install that predates this feature entirely" - it never
    // errors, just reads back Off for an unconfigured bin_dir.
    #[test]
    fn get_replication_status_reads_off_for_an_unset_up_bin_dir() {
        assert_eq!(get_replication_status(bogus_bin_dir("repl-status")), ReplicationStatus::Off);
    }

    #[test]
    fn get_replication_capability_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        assert!(get_replication_capability(bogus_bin_dir("repl-cap")).is_err());
    }

    // set/clear_replication both call check_flags_supported first, which
    // errors on a missing version marker before ever shelling out to
    // backmeup.configure.sh - so these exercise the real error path without
    // risking a real subprocess call against a bin_dir with no real script.
    #[test]
    fn set_replication_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        let request = ReplicationRequest::Proton { remote: None };
        assert!(set_replication(bogus_bin_dir("repl-set"), request).is_err());
    }

    #[test]
    fn clear_replication_propagates_a_clean_error_for_an_unset_up_bin_dir() {
        assert!(clear_replication(bogus_bin_dir("repl-clear")).is_err());
    }

    // check_for_update reads the version marker before ever reaching its
    // curl call to GitHub's API - a bogus bin_dir errors out first, so this
    // never makes a real network request.
    #[test]
    fn check_for_update_propagates_a_clean_error_for_an_unset_up_bin_dir_without_any_network_call() {
        assert!(check_for_update(bogus_bin_dir("check-update")).is_err());
    }

    // Pure read-only system/CLI-presence checks with no inputs to vary -
    // the real result depends on this machine's actual state (real
    // launchd agents, real Full Disk Access grant, real proton-drive/
    // rclone installs), so there's nothing meaningful to assert beyond
    // "calling the wrapper doesn't panic and returns the expected type".
    #[test]
    fn get_housekeeping_schedule_does_not_panic() {
        let _: Option<Schedule> = get_housekeeping_schedule();
    }

    #[test]
    fn has_full_disk_access_does_not_panic() {
        let _: bool = has_full_disk_access();
    }

    #[test]
    fn proton_drive_available_does_not_panic() {
        let _: bool = proton_drive_available();
    }

    #[test]
    fn proton_drive_signed_in_does_not_panic() {
        let _: bool = proton_drive_signed_in();
    }

    #[test]
    fn rclone_available_does_not_panic() {
        let _: bool = rclone_available();
    }

    // run_backup_now/run_housekeeping_now once regressed to a plain
    // (non-async) fn, which silently moved their blocking child-process
    // work back onto Tauri's main thread and froze the whole app for the
    // job's duration (see the comment above run_backup_now). No real test
    // catches that directly: cargo test calling run.rs's functions involves
    // no Tauri dispatch at all, every frontend test mocks invoke entirely,
    // and Tauri's own MockRuntime test harness has no window or event loop
    // to observe a freeze in even if these commands were rewritten
    // runtime-generic to use it (confirmed by reading tauri's own source -
    // AppHandle here concretely resolves to the real Wry runtime via its
    // #[default_runtime] macro, not substitutable with MockRuntime without
    // a bigger signature change). This is a blunt source-text guard
    // instead: it can't prove the app stays responsive, but it does fail
    // loudly the moment someone reverts the async fn + spawn_blocking shape
    // that fixes it.
    fn command_source(name: &str) -> String {
        let src = include_str!("lib.rs");
        let start = src.find(&format!("async fn {name}(")).unwrap_or_else(|| {
            panic!(
                "`{name}` is no longer declared `async fn` - this regresses the \
                 main-thread-freeze fix, see the comment above run_backup_now in lib.rs"
            )
        });
        src[start..].lines().take(15).collect::<Vec<_>>().join("\n")
    }

    #[test]
    fn run_backup_now_stays_async_and_offloaded() {
        assert!(
            command_source("run_backup_now").contains("spawn_blocking"),
            "run_backup_now is async but no longer uses spawn_blocking - this regresses the main-thread-freeze fix"
        );
    }

    #[test]
    fn run_housekeeping_now_stays_async_and_offloaded() {
        assert!(
            command_source("run_housekeeping_now").contains("spawn_blocking"),
            "run_housekeeping_now is async but no longer uses spawn_blocking - this regresses the main-thread-freeze fix"
        );
    }
}
