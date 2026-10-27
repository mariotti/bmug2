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
pub fn default_paths(home_dir: &Path) -> DefaultPaths {
    let sync_dir = home_dir.join("Backups").join("rsyncBackup");
    let backup_dir_str = format!("{}-BP", sync_dir.display());
    let index_dir = sync_dir.join(".locate.dir");
    let install_dir = home_dir.join("usr").join("bmu");
    DefaultPaths {
        sync_dir: sync_dir.display().to_string(),
        backup_dir: backup_dir_str,
        index_dir: index_dir.display().to_string(),
        install_dir: install_dir.display().to_string(),
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct InstallOutcome {
    pub bin_dir: String,
    pub log: String,
}

/// "Use an existing install": validate, persist, done - no download.
pub fn use_existing(app_data_dir: &Path, bin_dir: &str) -> Result<InstallOutcome, String> {
    let path = Path::new(bin_dir);
    if !config::looks_installed(path) {
        return Err(format!(
            "{bin_dir} doesn't look like a bmug2 install (missing backmeup.sh or \
             backmeup.setup.sh - run install.sh there first)."
        ));
    }
    crate::version::check_compatible(path)?;
    config::save(app_data_dir, bin_dir)?;
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

pub fn find_existing_installs(home_dir: &Path) -> Vec<String> {
    find_existing_installs_under(home_dir)
}

// Builds, e.g. for search_root=/home/alex:
//   find /home/alex -maxdepth 6 ( -name .git -o -name node_modules -o
//     ... ) -prune -o -name backmeup.sh -print
// find's -prune/-o semantics are easy to get backwards: the parenthesized
// group matches any PRUNE_DIRS name and prunes it (skips descending into
// it entirely); anything not pruned falls through to "-o -name
// backmeup.sh -print", which prints matching files without pruning them.
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
    tag_name: Option<String>,
    tarball_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ReleaseItem {
    tag_name: Option<String>,
    prerelease: bool,
}

#[derive(Debug)]
struct RunOutput {
    log: String,
    ok: bool,
}

fn run(cmd: &mut Command) -> Result<RunOutput, String> {
    let name = format!("{:?}", cmd);
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run {name}: {e}"))?;
    let mut log = String::new();
    log.push_str(&String::from_utf8_lossy(&output.stdout));
    log.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok(RunOutput {
        log,
        ok: output.status.success(),
    })
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

/// Downloads the latest stable bmug2 release and runs its install.sh
/// non-interactively with the four given paths. First-run entry point;
/// never installs an experimental release (that path is only reachable
/// from Settings → apply_update, which passes an explicit tag the user
/// chose).
pub fn install_new(
    app_data_dir: &Path,
    sync_dir: &str,
    backup_dir: &str,
    index_dir: &str,
    install_dir: &str,
) -> Result<InstallOutcome, String> {
    let work_dir = std::env::temp_dir().join(format!("bmug2-install-{}", std::process::id()));
    std::fs::create_dir_all(&work_dir)
        .map_err(|e| format!("cannot create {}: {e}", work_dir.display()))?;

    let result = install_new_into(&work_dir, sync_dir, backup_dir, index_dir, install_dir, None);
    let _ = std::fs::remove_dir_all(&work_dir); // best-effort cleanup either way

    let outcome = result?;
    config::save(app_data_dir, install_dir_bin(install_dir).as_str())?;
    Ok(outcome)
}

fn install_dir_bin(install_dir: &str) -> String {
    // Matches install.sh's own copy destination: "${BMU_INSTDIR}/bin".
    format!("{install_dir}/bin")
}

#[derive(Debug)]
struct InstalledDirs {
    sync_dir: String,
    backup_dir: String,
    index_dir: String,
    install_dir: String,
}

/// Reads BMU_DIRRSYNC/BMU_DIRBACKUPS/BMU_DIRDBLOCATE/BMU_INSTDIR back
/// out of bin_dir/backmeup.setup.sh - the base install dir, NOT the
/// bin/ subdirectory (install_dir_bin derives that the same way
/// install_new does). Same "duplicate the tiny line-scan locally" idiom
/// as version.rs::read_installed_version, ignore.rs::read_setup_var,
/// and schedule.rs's own equivalent - this file gets its own copy
/// rather than sharing one, matching the existing convention.
fn read_installed_dirs(bin_dir: &Path) -> Result<InstalledDirs, String> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh"))
        .map_err(|e| format!("cannot read {}/backmeup.setup.sh: {e}", bin_dir.display()))?;
    let read_var = |key: &str| -> Option<String> {
        let prefix = format!("{key}=\"");
        contents.lines().find_map(|line| {
            line.trim()
                .strip_prefix(prefix.as_str())
                .and_then(|rest| rest.strip_suffix('"'))
                .map(str::to_string)
        })
    };
    Ok(InstalledDirs {
        sync_dir: read_var("BMU_DIRRSYNC").ok_or("BMU_DIRRSYNC not found in backmeup.setup.sh")?,
        backup_dir: read_var("BMU_DIRBACKUPS")
            .ok_or("BMU_DIRBACKUPS not found in backmeup.setup.sh")?,
        index_dir: read_var("BMU_DIRDBLOCATE")
            .ok_or("BMU_DIRDBLOCATE not found in backmeup.setup.sh")?,
        install_dir: read_var("BMU_INSTDIR").ok_or("BMU_INSTDIR not found in backmeup.setup.sh")?,
    })
}

/// Odd minor or odd patch means an experimental build per this
/// project's versioning policy (see README.md's "Versioning" section).
pub fn is_experimental(version: (u32, u32, u32)) -> bool {
    let (_major, minor, patch) = version;
    minor % 2 != 0 || patch % 2 != 0
}

/// The running GUI binary's own compile-time version. Used to decide
/// whether to surface experimental CLI releases even when the installed
/// CLI itself is stable (an experimental GUI installed via a .dmg/.deb/
/// .AppImage left the user with no path to upgrade the CLI from Settings
/// before — see issue #154) and to cap offered experimental CLI
/// releases at the GUI's own version, since a newer CLI may rely on GUI
/// changes this build doesn't have yet. CARGO_PKG_VERSION is baked in
/// at build time from Cargo.toml, which the version-bump recipe keeps
/// in lockstep with BMU_VERSION.
pub fn gui_version() -> (u32, u32, u32) {
    crate::version::parse_version(env!("CARGO_PKG_VERSION"))
        .expect("CARGO_PKG_VERSION must parse as X.Y.Z")
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UpdateInfo {
    pub current: (u32, u32, u32),
    /// Newer stable release than installed, if one exists.
    pub latest_stable: Option<String>,
    /// Newer experimental release than installed, if one exists and the
    /// installed version is itself experimental - never surfaced to a
    /// stable-track user.
    pub latest_experimental: Option<String>,
}

/// Compares the installed CLI's version against GitHub releases.
/// Always fetches /releases/latest (stable). When EITHER the installed
/// CLI OR the running GUI is experimental (odd minor or odd patch),
/// also fetches /releases?per_page=10 to find the newest pre-release
/// tag, capped at the GUI's own version so a newer-than-GUI
/// experimental CLI is never paired with this GUI. Read-only - never
/// downloads or installs anything; apply_update is the only function
/// that mutates the install, and is never called implicitly from here.
pub fn check_for_update(bin_dir: &Path) -> Result<UpdateInfo, String> {
    let current = crate::version::read_installed_version(bin_dir)
        .ok_or_else(|| format!("{} has no BMU_VERSION marker", bin_dir.display()))?;
    let gui = gui_version();

    let stable_api = run(Command::new("curl").args([
        "-sL",
        "https://api.github.com/repos/mariotti/bmug2/releases/latest",
    ]))?;
    if !stable_api.ok {
        return Err(format!(
            "Failed to query GitHub releases API.\n{}",
            stable_api.log
        ));
    }
    let latest_stable_ver = parse_latest_version(&stable_api.log).ok_or_else(|| {
        format!(
            "Could not find a tag_name in the releases API response.\n{}",
            stable_api.log
        )
    })?;

    let latest_stable = if latest_stable_ver > current {
        Some(format!(
            "v{}.{}.{}",
            latest_stable_ver.0, latest_stable_ver.1, latest_stable_ver.2
        ))
    } else {
        None
    };

    let latest_experimental = if is_experimental(current) || is_experimental(gui) {
        fetch_latest_experimental(current, gui)
    } else {
        None
    };

    Ok(UpdateInfo {
        current,
        latest_stable,
        latest_experimental,
    })
}

/// Fetches /releases?per_page=10 and returns the tag of the newest
/// pre-release that is strictly newer than `current` and no newer than
/// `max` (the running GUI's version — see gui_version()), or None.
/// Best-effort: any network or parse failure silently returns None
/// rather than surfacing an error to the user.
fn fetch_latest_experimental(
    current: (u32, u32, u32),
    max: (u32, u32, u32),
) -> Option<String> {
    let api = run(Command::new("curl").args([
        "-sL",
        "https://api.github.com/repos/mariotti/bmug2/releases?per_page=10",
    ]))
    .ok()?;
    if !api.ok {
        return None;
    }
    find_newest_experimental_tag(&api.log, current, max)
}

/// Parses a GitHub releases list JSON response and returns the tag name
/// of the newest pre-release entry strictly newer than `current` and
/// no newer than `max`. Strips the leading "v" before comparing
/// versions, same as parse_latest_version. The "-experimental" suffix
/// is stripped before numeric comparison since parse_version only
/// handles X.Y.Z.
pub fn find_newest_experimental_tag(
    api_response: &str,
    current: (u32, u32, u32),
    max: (u32, u32, u32),
) -> Option<String> {
    let items: Vec<ReleaseItem> = serde_json::from_str(api_response).ok()?;
    items
        .into_iter()
        .filter(|r| r.prerelease)
        .filter_map(|r| {
            let tag = r.tag_name?;
            let stripped = tag.strip_prefix('v').unwrap_or(&tag);
            let bare = stripped.split('-').next().unwrap_or(stripped);
            let ver = crate::version::parse_version(bare)?;
            if ver > current && ver <= max {
                Some((ver, tag))
            } else {
                None
            }
        })
        .max_by_key(|(ver, _)| *ver)
        .map(|(_, tag)| tag)
}

/// Re-downloads the latest release and re-runs install.sh IN PLACE
/// against this exact install's own existing sync/backup/index/install
/// directories (read back via read_installed_dirs), never caller-
/// supplied ones. Passing different directory values here would
/// relocate the install rather than refresh it - that's why this
/// function derives them from the current config instead of accepting
/// them as parameters, unlike install_new.
///
/// Must only ever be invoked after the caller has already obtained an
/// explicit, separate user confirmation - this function itself performs
/// no confirmation of its own and is never called automatically.
pub fn apply_update(
    app_data_dir: &Path,
    bin_dir: &Path,
    tag: &str,
) -> Result<InstallOutcome, String> {
    let dirs = read_installed_dirs(bin_dir)?;

    let work_dir = std::env::temp_dir().join(format!("bmug2-update-{}", std::process::id()));
    std::fs::create_dir_all(&work_dir)
        .map_err(|e| format!("cannot create {}: {e}", work_dir.display()))?;

    let result = install_new_into(
        &work_dir,
        &dirs.sync_dir,
        &dirs.backup_dir,
        &dirs.index_dir,
        &dirs.install_dir,
        Some(tag),
    );
    let _ = std::fs::remove_dir_all(&work_dir); // best-effort cleanup either way

    let outcome = result?;
    config::save(app_data_dir, install_dir_bin(&dirs.install_dir).as_str())?;
    Ok(outcome)
}

fn install_new_into(
    work_dir: &Path,
    sync_dir: &str,
    backup_dir: &str,
    index_dir: &str,
    install_dir: &str,
    tag: Option<&str>,
) -> Result<InstallOutcome, String> {
    // Only install.sh's own output (the chatty, human-relevant one) joins
    // `log` on the success path below - api/dl/tar's curl/tar invocations
    // use silent flags (-sL, no -v) and produce nothing on stdout/stderr
    // when they succeed, so there's normally nothing useful to append.
    // Their captured output is still used, just on the Err paths, where
    // it's exactly the diagnostic a failure needs.
    let mut log = String::new();

    let api_url = match tag {
        Some(t) => {
            log.push_str(&format!("Looking up release {t}...\n"));
            format!("https://api.github.com/repos/mariotti/bmug2/releases/tags/{t}")
        }
        None => {
            log.push_str("Looking up the latest release...\n");
            "https://api.github.com/repos/mariotti/bmug2/releases/latest".to_string()
        }
    };
    let api = run(Command::new("curl").args(["-sL", &api_url]))?;
    if !api.ok {
        return Err(format!("{log}Failed to query GitHub releases API.\n{}", api.log));
    }
    let tarball_url = parse_tarball_url(&api.log)
        .ok_or_else(|| format!("{log}Could not find a tarball_url in the releases API response.\n{}", api.log))?;

    log.push_str(&format!("Downloading {tarball_url}...\n"));
    let archive_path = work_dir.join("bmug2.tar.gz");
    let dl = run(Command::new("curl").args([
        "-sL",
        &tarball_url,
        "-o",
        archive_path.to_str().ok_or("temp path is not valid UTF-8")?,
    ]))?;
    if !dl.ok {
        return Err(format!("{log}Download failed.\n{}", dl.log));
    }

    log.push_str("Extracting...\n");
    let tar = run(Command::new("tar").args([
        "-xzf",
        archive_path.to_str().ok_or("temp path is not valid UTF-8")?,
        "-C",
        work_dir.to_str().ok_or("temp path is not valid UTF-8")?,
    ]))?;
    if !tar.ok {
        return Err(format!("{log}Extraction failed.\n{}", tar.log));
    }

    let extracted = find_extracted_dir(work_dir).map_err(|e| format!("{log}{e}"))?;
    let install_script = extracted.join("install.sh");

    log.push_str("Running install.sh...\n");
    let install = run(Command::new(&install_script)
        .arg(format!("--sync-dir={sync_dir}"))
        .arg(format!("--backup-dir={backup_dir}"))
        .arg(format!("--index-dir={index_dir}"))
        .arg(format!("--install-dir={install_dir}"))
        .stdin(Stdio::null()))?;
    log.push_str(&install.log);
    if !install.ok {
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

/// Strips a leading "v" (GitHub tags here are "v2.15.0") and reuses
/// version::parse_version - the releases API's tag_name is the only
/// place bmug2's released version is expressed outside a real install.
fn parse_latest_version(api_response: &str) -> Option<(u32, u32, u32)> {
    let release: LatestRelease = serde_json::from_str(api_response).ok()?;
    let tag = release.tag_name?;
    let stripped = tag.strip_prefix('v').unwrap_or(&tag);
    crate::version::parse_version(stripped)
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
    fn parses_latest_version_from_real_shaped_response() {
        let json = r#"{"tag_name":"v2.15.0","tarball_url":"https://..."}"#;
        assert_eq!(parse_latest_version(json), Some((2, 15, 0)));
    }

    #[test]
    fn parses_latest_version_without_v_prefix_too() {
        let json = r#"{"tag_name":"2.15.0","tarball_url":"https://..."}"#;
        assert_eq!(parse_latest_version(json), Some((2, 15, 0)));
    }

    #[test]
    fn missing_tag_name_yields_no_latest_version() {
        let json = r#"{"tarball_url":"https://..."}"#;
        assert_eq!(parse_latest_version(json), None);
    }

    #[test]
    fn reads_installed_dirs_from_a_real_shaped_setup_file() {
        let dir = std::env::temp_dir().join(format!("bmug2-dirs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            "BMU_DIRRSYNC=\"/home/alex/Backups/rsyncBackup\"\n\
             BMU_DIRBACKUPS=\"/home/alex/Backups/rsyncBackup-BP\"\n\
             BMU_DIRDBLOCATE=\"/home/alex/Backups/rsyncBackup/.locate.dir\"\n\
             BMU_INSTDIR=\"/home/alex/usr/bmu\"\n",
        )
        .unwrap();
        let dirs = read_installed_dirs(&dir).unwrap();
        assert_eq!(dirs.install_dir, "/home/alex/usr/bmu");
        assert_eq!(dirs.sync_dir, "/home/alex/Backups/rsyncBackup");
        assert_eq!(dirs.backup_dir, "/home/alex/Backups/rsyncBackup-BP");
        assert_eq!(dirs.index_dir, "/home/alex/Backups/rsyncBackup/.locate.dir");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_dir_var_errors_clearly() {
        let dir =
            std::env::temp_dir().join(format!("bmug2-dirs-missing-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("backmeup.setup.sh"), "BMU_DIRRSYNC=\"/x\"\n").unwrap();
        assert!(read_installed_dirs(&dir).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }

    // The other 3 vars' own ok_or(...)? each return a distinct error
    // only reachable if every var that's checked before it is already
    // present - missing_dir_var_errors_clearly above only ever reaches
    // BMU_DIRBACKUPS's. These walk one var further each time so every
    // one of the 4 actually gets exercised, not just the first.
    #[test]
    fn missing_index_dir_var_errors_clearly() {
        let dir =
            std::env::temp_dir().join(format!("bmug2-dirs-missing-index-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            "BMU_DIRRSYNC=\"/x\"\nBMU_DIRBACKUPS=\"/x-BP\"\n",
        )
        .unwrap();
        let err = read_installed_dirs(&dir).unwrap_err();
        assert!(err.contains("BMU_DIRDBLOCATE"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_install_dir_var_errors_clearly() {
        let dir = std::env::temp_dir()
            .join(format!("bmug2-dirs-missing-install-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            "BMU_DIRRSYNC=\"/x\"\nBMU_DIRBACKUPS=\"/x-BP\"\nBMU_DIRDBLOCATE=\"/x/.locate.dir\"\n",
        )
        .unwrap();
        let err = read_installed_dirs(&dir).unwrap_err();
        assert!(err.contains("BMU_INSTDIR"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn read_installed_dirs_errors_clearly_when_setup_file_is_missing_entirely() {
        let dir = std::env::temp_dir()
            .join(format!("bmug2-dirs-no-setup-file-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        let err = read_installed_dirs(&dir).unwrap_err();
        assert!(err.contains("backmeup.setup.sh"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn install_dir_bin_appends_bin_matching_install_sh() {
        assert_eq!(install_dir_bin("/home/alex/usr/bmu"), "/home/alex/usr/bmu/bin");
    }

    #[test]
    fn run_reports_success_for_a_zero_exit_command() {
        let result = run(&mut Command::new("true")).unwrap();
        assert!(result.ok);
    }

    #[test]
    fn run_reports_failure_for_a_nonzero_exit_command_without_erroring() {
        // A command that RAN but failed is a clean Ok(RunOutput{ok:false,..}),
        // not an Err - Err is reserved for failing to even start the process.
        let result = run(&mut Command::new("false")).unwrap();
        assert!(!result.ok);
    }

    #[test]
    fn run_captures_combined_stdout_and_stderr() {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", "echo out; echo err 1>&2"]);
        let result = run(&mut cmd).unwrap();
        assert!(result.ok);
        assert!(result.log.contains("out"));
        assert!(result.log.contains("err"));
    }

    #[test]
    fn run_errors_clearly_when_the_binary_does_not_exist() {
        let err = run(&mut Command::new("bmug2-definitely-not-a-real-binary")).unwrap_err();
        assert!(err.contains("bmug2-definitely-not-a-real-binary"));
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

    // Distinct from errors_on_zero_extracted_dirs above: that one is a
    // real, existing-but-empty directory (read_dir succeeds, the match
    // on dirs.len() hits the 0 arm); this one is read_dir itself
    // failing because extract_dir doesn't exist at all.
    #[test]
    fn errors_clearly_when_extract_dir_itself_does_not_exist() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-missing-{}", std::process::id()));
        std::fs::remove_dir_all(&tmp).ok();
        let err = find_extracted_dir(&tmp).unwrap_err();
        assert!(err.contains(&tmp.display().to_string()));
    }

    #[test]
    fn errors_on_multiple_extracted_dirs() {
        let tmp = std::env::temp_dir().join(format!("bmug2-test-multi-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("a")).unwrap();
        std::fs::create_dir_all(tmp.join("b")).unwrap();
        assert!(find_extracted_dir(&tmp).is_err());
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
            None,
        );

        assert!(result.is_ok(), "install_new_into failed: {:?}", result.err());
        let outcome = result.unwrap();
        assert!(Path::new(&outcome.bin_dir).join("backmeup.sh").is_file());

        std::fs::remove_dir_all(&base).ok();
    }

    /// Real end-to-end verification against the live GitHub API - same
    /// reasoning/convention as install_new_into_works_end_to_end_for_real
    /// above. Run explicitly with `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn check_for_update_fetches_a_real_latest_version() {
        let dir = std::env::temp_dir().join(format!("bmug2-update-check-e2e-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            "BMU_DIRRSYNC=\"/tmp/x\"\nBMU_VERSION=\"0.0.1\"\n",
        )
        .unwrap();
        let result = check_for_update(&dir);
        assert!(result.is_ok(), "check_for_update failed: {:?}", result.err());
        let info = result.unwrap();
        assert!(
            info.latest_stable.is_some(),
            "0.0.1 should always be behind the real latest stable release"
        );
        std::fs::remove_dir_all(&dir).ok();
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

    /// Regression test for the original bug that started this feature -
    /// picking an old install used to sail straight through to a
    /// confusing JSON-parse failure instead of stopping here with a
    /// clear message. Now calls use_existing directly (it no longer
    /// needs an AppHandle - see the config.rs decoupling) rather than
    /// just reconstructing its pre-save sequence by hand.
    #[test]
    fn an_old_but_real_install_is_rejected_before_it_would_be_saved() {
        let dir = std::env::temp_dir().join(format!("bmug2-old-install-test-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("backmeup.sh"), "").unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            "BMU_DIRRSYNC=\"/tmp/x\"\nBMU_VERSION=\"2.3.0\"\n",
        )
        .unwrap();
        let app_data_dir =
            std::env::temp_dir().join(format!("bmug2-old-install-appdata-{}", std::process::id()));
        std::fs::remove_dir_all(&app_data_dir).ok();

        let err = use_existing(&app_data_dir, dir.to_str().unwrap()).unwrap_err();
        assert!(err.contains("2.3.0"), "message should name the found version: {err}");
        assert!(
            err.contains(&crate::version::MIN_COMPATIBLE_VERSION.0.to_string()),
            "message should name the required major version: {err}"
        );
        assert!(config::load(&app_data_dir).is_none(), "a rejected install must not be saved");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_real_compatible_install_is_accepted_and_saved() {
        let dir = std::env::temp_dir().join(format!("bmug2-existing-install-test-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("backmeup.sh"), "").unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            format!(
                "BMU_DIRRSYNC=\"/tmp/x\"\nBMU_VERSION=\"{}.{}.0\"\n",
                crate::version::MIN_COMPATIBLE_VERSION.0,
                crate::version::MIN_COMPATIBLE_VERSION.1
            ),
        )
        .unwrap();
        let app_data_dir =
            std::env::temp_dir().join(format!("bmug2-existing-install-appdata-{}", std::process::id()));
        std::fs::remove_dir_all(&app_data_dir).ok();

        let outcome = use_existing(&app_data_dir, dir.to_str().unwrap()).unwrap();
        assert_eq!(outcome.bin_dir, dir.to_str().unwrap());
        let cfg = config::load(&app_data_dir).expect("use_existing should have saved a config");
        assert_eq!(cfg.bin_dir, dir.to_str().unwrap());

        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&app_data_dir).ok();
    }

    #[test]
    fn use_existing_rejects_a_dir_that_does_not_look_installed() {
        let dir = std::env::temp_dir().join(format!("bmug2-not-installed-test-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        let app_data_dir =
            std::env::temp_dir().join(format!("bmug2-not-installed-appdata-{}", std::process::id()));

        let err = use_existing(&app_data_dir, dir.to_str().unwrap()).unwrap_err();
        assert!(err.contains("doesn't look like a bmug2 install"), "{err}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn default_paths_derives_the_standard_layout_from_home() {
        let home = Path::new("/home/alex");
        let defaults = default_paths(home);
        assert_eq!(defaults.sync_dir, "/home/alex/Backups/rsyncBackup");
        assert_eq!(defaults.backup_dir, "/home/alex/Backups/rsyncBackup-BP");
        assert_eq!(defaults.index_dir, "/home/alex/Backups/rsyncBackup/.locate.dir");
        assert_eq!(defaults.install_dir, "/home/alex/usr/bmu");
    }

    #[test]
    fn find_existing_installs_delegates_to_the_real_search() {
        let base = std::env::temp_dir().join(format!("bmug2-suggest-delegate-{}", std::process::id()));
        std::fs::create_dir_all(base.join("usr/bmu/bin")).unwrap();
        std::fs::write(base.join("usr/bmu/bin/backmeup.sh"), "").unwrap();
        std::fs::write(base.join("usr/bmu/bin/backmeup.setup.sh"), "").unwrap();

        assert_eq!(
            find_existing_installs(&base),
            vec![base.join("usr/bmu/bin").display().to_string()],
        );
        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn empty_dir_yields_no_suggestions() {
        let base = std::env::temp_dir().join(format!("bmug2-suggest-empty-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        assert!(find_existing_installs_under(&base).is_empty());
        std::fs::remove_dir_all(&base).ok();
    }

    // --- is_experimental ---

    #[test]
    fn stable_version_is_not_experimental() {
        assert!(!is_experimental((2, 18, 0)));
        assert!(!is_experimental((2, 16, 4)));
        assert!(!is_experimental((3, 0, 0)));
    }

    #[test]
    fn odd_minor_is_experimental() {
        assert!(is_experimental((2, 17, 0)));
        assert!(is_experimental((2, 19, 2)));
    }

    #[test]
    fn odd_patch_is_experimental() {
        assert!(is_experimental((2, 18, 1)));
        assert!(is_experimental((2, 18, 7)));
    }

    #[test]
    fn odd_minor_and_odd_patch_is_experimental() {
        assert!(is_experimental((2, 17, 3)));
    }

    // --- find_newest_experimental_tag ---

    fn releases_json(items: &[(&str, bool)]) -> String {
        let entries: Vec<String> = items
            .iter()
            .map(|(tag, prerelease)| {
                format!(r#"{{"tag_name":"{tag}","prerelease":{prerelease}}}"#)
            })
            .collect();
        format!("[{}]", entries.join(","))
    }

    // All of these use (99, 99, 99) as the max so the pre-#154 behavior
    // (no upper cap) is preserved for the baseline cases - the cap
    // itself is covered by caps_experimental_at_max_version below.
    const UNCAPPED: (u32, u32, u32) = (99, 99, 99);

    #[test]
    fn finds_newest_prerelease_newer_than_current() {
        // Both pre-releases are newer; v2.18.7 wins.
        let json = releases_json(&[
            ("v2.18.7-experimental", true),
            ("v2.18.5-experimental", true),
            ("v2.18.0", false),
        ]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 0), UNCAPPED),
            Some("v2.18.7-experimental".to_string()),
        );
    }

    #[test]
    fn returns_none_when_no_prerelease_is_newer_than_current() {
        // Installed is already at v2.18.7-experimental.
        let json = releases_json(&[
            ("v2.18.7-experimental", true),
            ("v2.18.5-experimental", true),
        ]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 7), UNCAPPED),
            None
        );
    }

    #[test]
    fn returns_none_when_list_has_only_stable_releases() {
        let json = releases_json(&[("v2.18.0", false), ("v2.16.0", false)]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 0), UNCAPPED),
            None
        );
    }

    #[test]
    fn returns_none_for_invalid_json() {
        assert_eq!(
            find_newest_experimental_tag("not json", (2, 18, 0), UNCAPPED),
            None
        );
    }

    // --- cap at max (issue #154) ---

    #[test]
    fn caps_experimental_at_max_version() {
        // A newer experimental exists but the GUI is older - we must
        // not offer a CLI release the GUI can't guarantee compat with.
        let json = releases_json(&[
            ("v2.18.11-experimental", true),
            ("v2.18.9-experimental", true),
            ("v2.18.7-experimental", true),
        ]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 0), (2, 18, 9)),
            Some("v2.18.9-experimental".to_string()),
        );
    }

    #[test]
    fn allows_experimental_exactly_at_max_version() {
        let json = releases_json(&[("v2.18.9-experimental", true)]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 0), (2, 18, 9)),
            Some("v2.18.9-experimental".to_string()),
        );
    }

    #[test]
    fn returns_none_when_only_experimental_exceeds_max() {
        let json = releases_json(&[("v2.18.11-experimental", true)]);
        assert_eq!(
            find_newest_experimental_tag(&json, (2, 18, 0), (2, 18, 9)),
            None
        );
    }

    // --- gui_version ---

    #[test]
    fn gui_version_parses_cargo_pkg_version() {
        // Just checks the compile-time env! and parse succeed - the exact
        // version floats with every version bump, so we don't pin it.
        let (major, _minor, _patch) = gui_version();
        assert!(major >= 2);
    }

    // --- check_for_update: error when bin_dir lacks version marker ---

    fn sandbox_with_bmu_version(version: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bmug2-update-info-{}-{}",
            std::process::id(),
            {
                static C: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                C.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            }
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("backmeup.setup.sh"),
            format!("BMU_DIRRSYNC=\"/tmp/x\"\nBMU_VERSION=\"{version}\"\n"),
        )
        .unwrap();
        dir
    }

    #[test]
    fn check_for_update_errors_clearly_when_bin_dir_has_no_version_marker() {
        let dir = sandbox_with_bmu_version("");
        // A missing/blank version marker means read_installed_version returns None.
        let err = check_for_update(&dir).unwrap_err();
        assert!(err.contains("BMU_VERSION"), "error should mention missing marker: {err}");
        std::fs::remove_dir_all(&dir).ok();
    }
}
