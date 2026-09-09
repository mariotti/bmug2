// A real, checkable bmug2 version, so an incompatible install fails
// with a clear message instead of a confusing JSON-parse failure the
// first time a --json call hits code that predates it. Two real
// incidents this session had exactly that shape (v2.4.0 lacking the
// --json/non-interactive flags, v2.5.0 lacking the simplified
// install-dir question) before there was any way to detect it.
use std::path::Path;

/// Bumped whenever the GUI starts depending on a newer bmug2 flag or
/// behavior - kept in sync with bin/backmeup.configure.sh's own
/// BMU_VERSION literal at release time (see gui/README.md).
pub const MIN_COMPATIBLE_VERSION: (u32, u32, u32) = (2, 6, 0);

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

    // No real random crate here (would be a new dependency for a test
    // helper) - a nanosecond-based suffix is unique enough to avoid
    // collisions between tests run in the same process.
    fn rand_suffix() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
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
        let dir = sandbox_with_version(Some("2.6.0"));
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
            err.contains("2.6.0"),
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
}
