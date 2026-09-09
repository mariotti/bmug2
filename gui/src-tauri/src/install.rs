// The first-run install flow: either point at an existing bmug2
// install, or download the latest release and run its install.sh
// non-interactively (bin/backmeup.configure.sh's --sync-dir= etc.
// flags). Fetches via `curl`/`tar` subprocesses rather than a Rust
// HTTP crate - see gui/README.md for why (same "shell out, don't grow
// a Python-sized dependency tree" reasoning as the bridge to the
// scripts themselves).
use crate::config;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefaultPaths {
    pub sync_dir: String,
    pub backup_dir: String,
    pub index_dir: String,
    pub install_dir: String,
}

/// Mirrors bin/backmeup.setup.sh.template's own formulas exactly:
///   BMU_DIRRSYNC="${HOME}/Backups/rsyncBackup"
///   BMU_DIRBACKUPS="${BMU_DIRRSYNC}-BP"
///   BMU_DIRDBLOCATE="${BMU_DIRRSYNC}/.locate.dir"
///   BMU_INSTDIR="${HOME}/usr/bmu"
/// No separate "base install path" field - configure.sh used to ask
/// for one too, but it was write-only (persisted, never read again by
/// any script) and, once install-dir became independently editable,
/// had zero effect on where bmug2 actually installs. Dropped from
/// both sides together rather than just hidden here.
pub fn default_paths(app: &AppHandle) -> Result<DefaultPaths, String> {
    let home = app
        .path()
        .home_dir()
        .map_err(|e| format!("cannot resolve home directory: {e}"))?;
    let sync_dir = home.join("Backups").join("rsyncBackup");
    let backup_dir_str = format!("{}-BP", sync_dir.display());
    let index_dir = sync_dir.join(".locate.dir");
    let install_dir = home.join("usr").join("bmu");
    Ok(DefaultPaths {
        sync_dir: sync_dir.display().to_string(),
        backup_dir: backup_dir_str,
        index_dir: index_dir.display().to_string(),
        install_dir: install_dir.display().to_string(),
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct InstallOutcome {
    pub bin_dir: String,
    pub log: String,
}

/// "Use an existing install": validate, persist, done - no download.
pub fn use_existing(app: &AppHandle, bin_dir: &str) -> Result<InstallOutcome, String> {
    let path = Path::new(bin_dir);
    if !config::looks_installed(path) {
        return Err(format!(
            "{bin_dir} doesn't look like a bmug2 install (missing backmeup.sh or \
             backmeup.setup.sh - run install.sh there first)."
        ));
    }
    config::save(app, bin_dir)?;
    Ok(InstallOutcome {
        bin_dir: bin_dir.to_string(),
        log: format!("Using existing install at {bin_dir}."),
    })
}

/// Suggests likely existing installs by shelling out to `find` (same
/// "shell out to a real system tool, don't grow a dependency" pattern
/// as curl/tar above - `find` is exactly bmug2's own philosophy for
/// this job, see backmeup.locate.sh's own archived-filelist fallback).
/// Bounded to depth 6 under $HOME and pruning conventionally-huge/
/// irrelevant directories for speed (confirmed real: ~0.2s against a
/// real home directory with several GB of node_modules/Cargo/Library
/// content). Best-effort: any failure (find missing, home dir
/// unresolvable) yields an empty list rather than an error - this is
/// a convenience on top of the always-available manual path input/
/// browse button, not a required step.
const PRUNE_DIRS: &[&str] = &[
    ".git",
    "node_modules",
    "target",
    "Library",
    ".cargo",
    ".rustup",
    ".npm",
    ".cache",
    "Applications",
];

pub fn find_existing_installs(app: &AppHandle) -> Vec<String> {
    match app.path().home_dir() {
        Ok(home) => find_existing_installs_under(&home),
        Err(_) => Vec::new(),
    }
}

fn find_existing_installs_under(search_root: &Path) -> Vec<String> {
    let mut prune_args: Vec<String> = Vec::new();
    for (i, name) in PRUNE_DIRS.iter().enumerate() {
        if i > 0 {
            prune_args.push("-o".to_string());
        }
        prune_args.push("-name".to_string());
        prune_args.push((*name).to_string());
    }
    let output = Command::new("find")
        .arg(search_root)
        .arg("-maxdepth")
        .arg("6")
        .arg("(")
        .args(&prune_args)
        .arg(")")
        .arg("-prune")
        .arg("-o")
        .arg("-name")
        .arg("backmeup.sh")
        .arg("-print")
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };

    let mut candidates: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| Path::new(line).parent().map(|p| p.to_path_buf()))
        .filter(|dir| config::looks_installed(dir))
        .map(|dir| dir.display().to_string())
        .collect();
    candidates.sort();
    candidates.dedup();
    candidates
}

#[derive(Debug, Deserialize)]
struct LatestRelease {
    tarball_url: Option<String>,
}

fn run(cmd: &mut Command) -> Result<(String, bool), String> {
    let name = format!("{:?}", cmd);
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run {name}: {e}"))?;
    let mut log = String::new();
    log.push_str(&String::from_utf8_lossy(&output.stdout));
    log.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok((log, output.status.success()))
}

/// Finds the single top-level directory a freshly-extracted GitHub
/// tarball produced (named like "mariotti-bmug2-<shortsha>/") - errors
/// out rather than guessing if the shape isn't exactly one directory.
fn find_extracted_dir(extract_dir: &Path) -> Result<PathBuf, String> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(extract_dir)
        .map_err(|e| format!("cannot read {}: {e}", extract_dir.display()))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    match dirs.len() {
        1 => Ok(dirs.remove(0)),
        0 => Err(format!(
            "extracted archive at {} contains no directory - unexpected tarball shape",
            extract_dir.display()
        )),
        n => Err(format!(
            "extracted archive at {} contains {n} directories, expected exactly 1",
            extract_dir.display()
        )),
    }
}

/// Downloads the latest bmug2 release and runs its install.sh
/// non-interactively with the four given paths.
pub fn install_new(
    app: &AppHandle,
    sync_dir: &str,
    backup_dir: &str,
    index_dir: &str,
    install_dir: &str,
) -> Result<InstallOutcome, String> {
    let base_tmp = app
        .path()
        .temp_dir()
        .map_err(|e| format!("cannot resolve temp directory: {e}"))?;
    let work_dir = base_tmp.join(format!("bmug2-install-{}", std::process::id()));
    std::fs::create_dir_all(&work_dir)
        .map_err(|e| format!("cannot create {}: {e}", work_dir.display()))?;

    let result = install_new_into(&work_dir, sync_dir, backup_dir, index_dir, install_dir);
    let _ = std::fs::remove_dir_all(&work_dir); // best-effort cleanup either way

    let outcome = result?;
    config::save(app, install_dir_bin(install_dir).as_str())?;
    Ok(outcome)
}

fn install_dir_bin(install_dir: &str) -> String {
    // Matches install.sh's own copy destination: "${BMU_INSTDIR}/bin".
    format!("{install_dir}/bin")
}

fn install_new_into(
    work_dir: &Path,
    sync_dir: &str,
    backup_dir: &str,
    index_dir: &str,
    install_dir: &str,
) -> Result<InstallOutcome, String> {
    let mut log = String::new();

    log.push_str("Looking up the latest release...\n");
    let (api_log, api_ok) = run(Command::new("curl").args([
        "-sL",
        "https://api.github.com/repos/mariotti/bmug2/releases/latest",
    ]))?;
    if !api_ok {
        return Err(format!("{log}Failed to query GitHub releases API.\n{api_log}"));
    }
    let tarball_url = parse_tarball_url(&api_log)
        .ok_or_else(|| format!("{log}Could not find a tarball_url in the releases API response.\n{api_log}"))?;

    log.push_str(&format!("Downloading {tarball_url}...\n"));
    let archive_path = work_dir.join("bmug2.tar.gz");
    let (dl_log, dl_ok) = run(Command::new("curl").args([
        "-sL",
        &tarball_url,
        "-o",
        archive_path.to_str().ok_or("temp path is not valid UTF-8")?,
    ]))?;
    if !dl_ok {
        return Err(format!("{log}Download failed.\n{dl_log}"));
    }

    log.push_str("Extracting...\n");
    let (tar_log, tar_ok) = run(Command::new("tar").args([
        "-xzf",
        archive_path.to_str().ok_or("temp path is not valid UTF-8")?,
        "-C",
        work_dir.to_str().ok_or("temp path is not valid UTF-8")?,
    ]))?;
    if !tar_ok {
        return Err(format!("{log}Extraction failed.\n{tar_log}"));
    }

    let extracted = find_extracted_dir(work_dir).map_err(|e| format!("{log}{e}"))?;
    let install_script = extracted.join("install.sh");

    log.push_str("Running install.sh...\n");
    let (install_log, install_ok) = run(Command::new(&install_script)
        .arg(format!("--sync-dir={sync_dir}"))
        .arg(format!("--backup-dir={backup_dir}"))
        .arg(format!("--index-dir={index_dir}"))
        .arg(format!("--install-dir={install_dir}"))
        .stdin(Stdio::null()))?;
    log.push_str(&install_log);
    if !install_ok {
        return Err(log);
    }

    Ok(InstallOutcome {
        bin_dir: install_dir_bin(install_dir),
        log,
    })
}

fn parse_tarball_url(api_response: &str) -> Option<String> {
    let release: LatestRelease = serde_json::from_str(api_response).ok()?;
    release.tarball_url
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tarball_url_from_real_shaped_response() {
        let json = r#"{"tag_name":"v2.4.0","tarball_url":"https://api.github.com/repos/mariotti/bmug2/tarball/v2.4.0"}"#;
        assert_eq!(
            parse_tarball_url(json),
            Some("https://api.github.com/repos/mariotti/bmug2/tarball/v2.4.0".to_string())
        );
    }

    #[test]
    fn missing_tarball_url_field_is_none() {
        let json = r#"{"tag_name":"v2.4.0"}"#;
        assert_eq!(parse_tarball_url(json), None);
    }

    #[test]
    fn invalid_json_is_none() {
        assert_eq!(parse_tarball_url("not json"), None);
    }

    #[test]
    fn finds_single_extracted_dir() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-single-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("mariotti-bmug2-abc1234")).unwrap();
        let found = find_extracted_dir(&tmp).unwrap();
        assert_eq!(found, tmp.join("mariotti-bmug2-abc1234"));
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn errors_on_zero_extracted_dirs() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-zero-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        assert!(find_extracted_dir(&tmp).is_err());
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn errors_on_multiple_extracted_dirs() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-multi-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("a")).unwrap();
        std::fs::create_dir_all(tmp.join("b")).unwrap();
        assert!(find_extracted_dir(&tmp).is_err());
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn validate_existing_style_check_requires_both_files() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-valid-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        assert!(!config::looks_installed(&tmp));
        std::fs::write(tmp.join("backmeup.sh"), "").unwrap();
        assert!(!config::looks_installed(&tmp));
        std::fs::write(tmp.join("backmeup.setup.sh"), "").unwrap();
        assert!(config::looks_installed(&tmp));
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    /// Real end-to-end verification: real GitHub download, real tar
    /// extraction, real install.sh run. Not run by default `cargo
    /// test` (needs network) - run explicitly with
    /// `cargo test -- --ignored`, same reasoning the shell suite
    /// already applies to skipping tool-dependent tests.
    #[test]
    #[ignore]
    fn install_new_into_works_end_to_end_for_real() {
        let base = std::env::temp_dir().join(format!("bmug2-e2e-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let work_dir = base.join("work");
        std::fs::create_dir_all(&work_dir).unwrap();

        let sync_dir = base.join("data/sync");
        let backup_dir = base.join("data/sync-BP");
        let index_dir = base.join("data/sync/.locate.dir");
        let install_dir = base.join("data/usr/bmu");

        let result = install_new_into(
            &work_dir,
            sync_dir.to_str().unwrap(),
            backup_dir.to_str().unwrap(),
            index_dir.to_str().unwrap(),
            install_dir.to_str().unwrap(),
        );

        assert!(result.is_ok(), "install_new_into failed: {:?}", result.err());
        let outcome = result.unwrap();
        assert!(Path::new(&outcome.bin_dir).join("backmeup.sh").is_file());

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn finds_a_real_install_and_ignores_a_bare_checkout() {
        let base = std::env::temp_dir().join(format!("bmug2-suggest-test-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();

        // a real, configured install
        let real_install = base.join("usr/bmu/bin");
        std::fs::create_dir_all(&real_install).unwrap();
        std::fs::write(real_install.join("backmeup.sh"), "").unwrap();
        std::fs::write(real_install.join("backmeup.setup.sh"), "").unwrap();

        // a bare checkout: has backmeup.sh, never configured
        let bare_checkout = base.join("GIT/bmug2/bin");
        std::fs::create_dir_all(&bare_checkout).unwrap();
        std::fs::write(bare_checkout.join("backmeup.sh"), "").unwrap();

        // a directory that should be pruned entirely
        let pruned = base.join("node_modules/somepkg/bin");
        std::fs::create_dir_all(&pruned).unwrap();
        std::fs::write(pruned.join("backmeup.sh"), "").unwrap();
        std::fs::write(pruned.join("backmeup.setup.sh"), "").unwrap();

        let found = find_existing_installs_under(&base);
        assert_eq!(found, vec![real_install.display().to_string()]);

        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn empty_dir_yields_no_suggestions() {
        let base = std::env::temp_dir().join(format!("bmug2-suggest-empty-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        assert!(find_existing_installs_under(&base).is_empty());
        std::fs::remove_dir_all(&base).ok();
    }
}
