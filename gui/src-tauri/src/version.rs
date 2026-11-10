// A real, checkable bmug2 version, so an incompatible install fails
// with a clear message instead of a confusing JSON-parse failure the
// first time a --json call hits code that predates it. Two real
// incidents had exactly that shape (v2.4.0 lacking the --json/
// non-interactive flags, v2.5.0 lacking the simplified install-dir
// question) before there was any way to detect it.
use std::path::Path;

/// Bumped whenever the GUI starts depending on a newer bmug2 flag or
/// behavior - kept in sync with bin/backmeup.configure.sh's own
/// BMU_VERSION literal at release time (see gui/README.md).
///
/// 2.11.0: the GUI's Ignore settings editor (ignore.rs) writes
/// HISTORY/<project>/.bmuconfig and <source>/.bmuignore regardless of
/// the installed CLI's version - both writes always succeed, so
/// without this gate an older backmeup.sh (which never reads
/// .bmuconfig at all) would silently ignore every toggle a user sets
/// in the GUI, with no error anywhere to explain why backups keep
/// including everything. Same failure shape as the two incidents
/// above, just newly possible now that a GUI-only write can outpace
/// what the paired CLI install actually understands.
pub const MIN_COMPATIBLE_VERSION: (u32, u32, u32) = (2, 11, 0);

pub fn parse_version(s: &str) -> Option<(u32, u32, u32)> {
    let mut parts = s.trim().split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None; // more than three components - not a version we emit
    }
    Some((major, minor, patch))
}

fn format_version((major, minor, patch): (u32, u32, u32)) -> String {
    format!("{major}.{minor}.{patch}")
}

/// Reads BMU_VERSION="X.Y.Z" out of bin_dir/backmeup.setup.sh - plain
/// string matching on the same simple `KEY="value"` line convention
/// mcp/src/bmug2_mcp/config.py's _ASSIGNMENT regex already parses, not
/// a full shell source. Returns None if the file is unreadable, has no
/// BMU_VERSION line at all (any install predating this feature), or
/// the value doesn't parse as three dot-separated numbers.
pub fn read_installed_version(bin_dir: &Path) -> Option<(u32, u32, u32)> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh")).ok()?;
    for line in contents.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("BMU_VERSION=\"") {
            let value = rest.strip_suffix('"')?;
            return parse_version(value);
        }
    }
    None
}

/// Err with a clear, specific message if bin_dir's installed version is
/// missing entirely or older than MIN_COMPATIBLE_VERSION.
pub fn check_compatible(bin_dir: &Path) -> Result<(), String> {
    match read_installed_version(bin_dir) {
        None => Err(format!(
            "{} has no version marker - it predates bmug2 v{} (this GUI's \
             minimum). Reinstall via \"Install a new copy\", or upgrade the \
             CLI there and re-run backmeup.configure.sh.",
            bin_dir.display(),
            format_version(MIN_COMPATIBLE_VERSION)
        )),
        Some(found) if found < MIN_COMPATIBLE_VERSION => Err(format!(
            "{} is bmug2 v{}, which is older than what this GUI needs (v{}+). \
             Reinstall via \"Install a new copy\", or upgrade the CLI there \
             and re-run backmeup.configure.sh.",
            bin_dir.display(),
            format_version(found),
            format_version(MIN_COMPATIBLE_VERSION)
        )),
        Some(_) => Ok(()),
    }
}

/// This GUI's own semver, parsed from Cargo.toml at compile time via
/// env!("CARGO_PKG_VERSION"). Panics if Cargo.toml's version string
/// isn't three dot-separated integers, which the release-cycle 6-file
/// bump keeps lock-step; a release that broke that invariant would
/// also fail every other BMU_VERSION-dependent check, so panicking
/// here is a fine canary.
pub fn gui_version() -> (u32, u32, u32) {
    parse_version(env!("CARGO_PKG_VERSION"))
        .expect("gui/src-tauri/Cargo.toml must have a valid semver version")
}

/// Asymmetric hard-gate: refuses to proceed when the installed CLI
/// version is NEWER than this GUI's own version. The reverse
/// direction (GUI newer than CLI) is handled by check_compatible()
/// above - that one guards against calling a feature on a CLI that
/// doesn't understand it yet.
///
/// Rationale for the asymmetry (see docs/COMPATIBILITY.md): the GUI
/// isn't only a viewer, it's also the AUTHOR of on-disk artifacts -
/// schedule wrapper scripts, replication config via configure.sh
/// flags, source-ignore files, launchd/systemd units. A stale GUI
/// running against a current CLI writes STALE outputs even though
/// the CLI's own shell path works fine. Confirmed in the wild: a
/// user on GUI 2.18.17 + CLI 2.18.22 would re-install a HouseKeeping
/// schedule via "Save" in the GUI and get the pre-#186 wrapper
/// (missing the local-backend replicate.sh call) written back to
/// disk, undoing what the #197 reconcile would have fixed had the
/// GUI been current.
///
/// Debug builds skip the check: dev workflows often run the GUI
/// from source against a locally-installed older CLI, and failing
/// hard there would just block iteration. Release builds enforce
/// strictly. The underlying comparison is still reachable from
/// tests via check_cli_not_newer_inner() below.
pub fn check_cli_not_newer(bin_dir: &Path) -> Result<(), String> {
    if cfg!(debug_assertions) {
        return Ok(());
    }
    check_cli_not_newer_inner(bin_dir, gui_version())
}

/// Underlying check, decoupled from the debug-assertions gate so unit
/// tests can hit it in both directions regardless of build mode.
pub(crate) fn check_cli_not_newer_inner(
    bin_dir: &Path,
    gui: (u32, u32, u32),
) -> Result<(), String> {
    let Some(cli) = read_installed_version(bin_dir) else {
        // Missing BMU_VERSION is check_compatible's problem, not ours.
        // Returning Ok here keeps the two checks independent.
        return Ok(());
    };
    if cli > gui {
        return Err(format!(
            "bmug2 CLI at {} is v{} - newer than this GUI (v{}). The GUI \
             writes config, schedule wrappers, and replication settings \
             that must be generated by a GUI at least as new as the CLI; \
             running a stale GUI against a newer CLI silently undoes fixes \
             landed in between. Update the GUI from \
             https://github.com/mariotti/bmug2/releases.",
            bin_dir.display(),
            format_version(cli),
            format_version(gui),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_well_formed_version() {
        assert_eq!(parse_version("2.6.0"), Some((2, 6, 0)));
        assert_eq!(parse_version("10.2.33"), Some((10, 2, 33)));
    }

    #[test]
    fn rejects_garbled_or_wrong_shaped_versions() {
        assert_eq!(parse_version(""), None);
        assert_eq!(parse_version("2.6"), None);
        assert_eq!(parse_version("2.6.0.1"), None);
        assert_eq!(parse_version("v2.6.0"), None);
        assert_eq!(parse_version("2.six.0"), None);
    }

    fn sandbox_with_version(version: Option<&str>) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bmug2-version-test-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let body = match version {
            Some(v) => format!("BMU_DIRRSYNC=\"/tmp/x\"\nBMU_VERSION=\"{v}\"\n"),
            None => "BMU_DIRRSYNC=\"/tmp/x\"\n".to_string(),
        };
        std::fs::write(dir.join("backmeup.setup.sh"), body).unwrap();
        dir
    }

    // A real, reproduced CI failure (not theoretical): this used to be
    // a nanosecond timestamp, on the assumption that was unique enough
    // between tests in the same process - it isn't, on a busy/
    // virtualized runner's clock, confirmed for real by
    // check_compatible_rejects_missing_marker_with_clear_message
    // finding v2.3.0 (another test's fixture) instead of its own
    // no-marker-at-all sandbox. process::id() alone contributes
    // nothing here either - cargo test runs every test as a thread in
    // one process, not a separate process, so every call in this
    // binary already shares the same pid. A plain atomic counter is
    // the only thing actually guaranteed unique per call regardless of
    // clock resolution or thread timing.
    fn rand_suffix() -> u64 {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    #[test]
    fn reads_a_real_persisted_version() {
        let dir = sandbox_with_version(Some("2.6.0"));
        assert_eq!(read_installed_version(&dir), Some((2, 6, 0)));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_version_line_reads_as_none() {
        let dir = sandbox_with_version(None);
        assert_eq!(read_installed_version(&dir), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_compatible_accepts_matching_version() {
        let dir = sandbox_with_version(Some("2.11.0"));
        assert!(check_compatible(&dir).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_compatible_accepts_newer_version() {
        let dir = sandbox_with_version(Some("3.0.0"));
        assert!(check_compatible(&dir).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_compatible_rejects_older_version_with_clear_message() {
        let dir = sandbox_with_version(Some("2.3.0"));
        let err = check_compatible(&dir).unwrap_err();
        assert!(err.contains("2.3.0"), "message should name the found version: {err}");
        assert!(
            err.contains("2.11.0"),
            "message should name the required version: {err}"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_compatible_rejects_missing_marker_with_clear_message() {
        let dir = sandbox_with_version(None);
        let err = check_compatible(&dir).unwrap_err();
        assert!(err.contains("no version marker"), "message was: {err}");
        std::fs::remove_dir_all(&dir).ok();
    }

    //
    // check_cli_not_newer: asymmetric hard-gate against a CLI newer
    // than the GUI. Tests hit check_cli_not_newer_inner() directly
    // so the comparison runs regardless of build mode (the public
    // check_cli_not_newer() short-circuits on debug_assertions; the
    // hard-gate itself is what we need to pin, not the build-mode
    // escape hatch).
    //

    #[test]
    fn check_cli_not_newer_accepts_cli_equal_to_gui() {
        let dir = sandbox_with_version(Some("2.18.22"));
        assert!(check_cli_not_newer_inner(&dir, (2, 18, 22)).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_cli_not_newer_accepts_cli_older_than_gui() {
        // CLI < GUI is the OTHER direction - handled by check_compatible
        // in combination with the MIN_VERSION_FOR_* feature gates.
        // This function must be a silent pass for that case.
        let dir = sandbox_with_version(Some("2.18.20"));
        assert!(check_cli_not_newer_inner(&dir, (2, 18, 22)).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_cli_not_newer_rejects_cli_newer_than_gui_with_clear_message() {
        // The failure mode this check exists for.
        let dir = sandbox_with_version(Some("2.18.24"));
        let err = check_cli_not_newer_inner(&dir, (2, 18, 22)).unwrap_err();
        assert!(err.contains("2.18.24"), "message should name the CLI version: {err}");
        assert!(err.contains("2.18.22"), "message should name the GUI version: {err}");
        assert!(
            err.contains("Update the GUI"),
            "message should instruct the user what to do: {err}"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_cli_not_newer_treats_missing_version_as_silent_ok() {
        // Missing BMU_VERSION is check_compatible's problem - returning
        // Ok here keeps the two checks independent. The caller runs
        // check_compatible first anyway, so a missing marker fails
        // there with a specific message rather than here with a
        // generic one.
        let dir = sandbox_with_version(None);
        assert!(check_cli_not_newer_inner(&dir, (2, 18, 22)).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_cli_not_newer_crosses_minor_and_major_boundaries() {
        let dir = sandbox_with_version(Some("3.0.0"));
        let err = check_cli_not_newer_inner(&dir, (2, 18, 22)).unwrap_err();
        assert!(err.contains("3.0.0"));
        std::fs::remove_dir_all(&dir).ok();

        let dir = sandbox_with_version(Some("2.20.0"));
        let err = check_cli_not_newer_inner(&dir, (2, 18, 22)).unwrap_err();
        assert!(err.contains("2.20.0"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn gui_version_parses_from_cargo_toml() {
        // Sanity: env!("CARGO_PKG_VERSION") must produce a tuple that
        // matches our x.y.z shape, or every release that bumps the
        // version would panic at startup.
        let (major, _, _) = gui_version();
        assert!(major >= 2, "gui_version must be at least 2.x.x, got {major}.x.x");
    }
}
