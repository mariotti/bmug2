// Skeleton command proving the JS <-> Rust bridge works end to end -
// not calling into bmug2 yet. The next phase replaces/adds commands
// that shell out to the installed backmeup.status.sh --json /
// backmeup.locate.sh --json (see bin/, docs/MANUAL.md) and drive
// backmeup.configure.sh's non-interactive flags for first-run setup.
#[tauri::command]
fn bridge_check() -> String {
    "bmug2 GUI: Rust backend reachable from the frontend.".to_string()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![bridge_check])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
