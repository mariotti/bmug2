// One-click archive: dry-run preview + commit. Dispatches to
// backmeup.archive.sh under the hood - the shell layer is the only
// place that actually touches B-<stamp>/ directories or .tar.gz
// files; this module is just two thin wrappers + a line parser to
// produce the "N snapshots, X MB" summary the GUI shows.
//
// Phase 3 follow-up to docs/PROJECT_disk-size.md. The *only*
// destructive-producing GUI action in bmug2 (produces .tar.gz /
// .tar files in HISTORY and removes the uncompressed B-<stamp>/
// directories). That's why it has its own module instead of
// living in run.rs - lets the "first destructive GUI action"
// landing have a focused review surface + its own test suite,
// without getting mixed up with the plain run_backup_now path.
//
// Design discipline: the Rust side DOES NOT itself delete anything.
// It calls backmeup.archive.sh which already has the safety
// properties (tar count verification, per-project lock,
// .filelist generated before the dir goes away). The Rust side's
// only responsibility is: (1) run the shell command, (2) parse
// the plain-text output into something structured enough for the
// GUI to show, (3) propagate errors.

use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

/// Summary of what a dry-run would archive. Parsed from
/// `backmeup.archive.sh -n <project> <days>` output.
///
/// `candidate_count` is the number of B-<stamp>/ directories that
/// would move to .tar.gz/.tar. `total_bytes_to_archive` sums up the
/// current size of those directories (what `du -sh` reports in the
/// dry-run output). An actual archive run will often produce
/// SMALLER files because of gzip compression - the number here is
/// the pre-compression figure, so it's an upper bound on both the
/// archive size and the HISTORY-space it would free (archives
/// replace dirs 1:1).
///
/// Honest contract: when `du -sh` reports a size in a unit (M / G /
/// K), we parse and convert to bytes. When it reports a raw byte
/// count, we take it as-is. When parse fails for any row, that
/// row's bytes are treated as 0 (the count still increments) -
/// the summary is worth showing even when one row's size is weird.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct ArchivePreview {
    pub candidate_count: u64,
    pub total_bytes_to_archive: u64,
    /// The raw dry-run log, for an "advanced" UI collapse. Capped
    /// at a reasonable size by backmeup.archive.sh's own output
    /// (one line per candidate + a header + a summary).
    pub log: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct ArchiveRunOutput {
    pub archived_count: u64,
    pub log: String,
    pub ok: bool,
}

/// Validates `days` as a plain non-negative integer. backmeup.
/// archive.sh accepts any `expr`-safe integer but we're the entry
/// point from an untrusted GUI input; filter early so a user who
/// deletes "180" and types "180; rm -rf" never reaches shell.
fn validate_days(days: &str) -> Result<(), String> {
    if days.is_empty() {
        return Err("days must be non-empty".to_string());
    }
    if !days.chars().all(|c| c.is_ascii_digit()) {
        return Err(format!("days must be a plain integer, got: {days}"));
    }
    Ok(())
}

/// Project name validation: has to match what `basename` on the
/// shell side would produce. Not path, not empty, no slashes, no
/// leading dot that could hit a sidecar sibling.
fn validate_project(project: &str) -> Result<(), String> {
    if project.is_empty() {
        return Err("project must be non-empty".to_string());
    }
    if project.contains('/') || project.contains('\\') {
        return Err(format!("project must not contain a path separator: {project}"));
    }
    // Leading dot would look like a sidecar file; reject.
    if project.starts_with('.') {
        return Err(format!("project must not start with '.': {project}"));
    }
    Ok(())
}

/// Parse "would archive <name> (<size>) -> <name>.<ext>" lines
/// from `backmeup.archive.sh -n` output. Everything else is
/// ignored (header + "DRY RUN: N snapshot(s)..." summary).
fn parse_preview(stdout: &str) -> (u64, u64) {
    let mut count = 0u64;
    let mut total = 0u64;
    for line in stdout.lines() {
        let Some(after_prefix) = line.strip_prefix("would archive ") else {
            continue;
        };
        count += 1;
        // Shape: "<name> (<size>) -> <name>.<ext>"
        //                  ^-----^ parentheses carry the du -sh output
        let Some(open) = after_prefix.find('(') else { continue };
        let Some(close) = after_prefix[open..].find(')') else { continue };
        let size_str = &after_prefix[open + 1..open + close];
        total = total.saturating_add(parse_du_sh_size(size_str.trim()));
    }
    (count, total)
}

/// Parse `du -sh` output (e.g. "1.5G", "42M", "8.0K", "1024B",
/// "512") into bytes. Returns 0 for anything unparseable - this
/// is a UI estimate, we never want to crash on a weird row.
fn parse_du_sh_size(s: &str) -> u64 {
    if s.is_empty() {
        return 0;
    }
    let (num_part, unit) = s.split_at(
        s.find(|c: char| c.is_ascii_alphabetic())
            .unwrap_or(s.len()),
    );
    let Ok(num) = num_part.parse::<f64>() else {
        return 0;
    };
    let multiplier: u64 = match unit.trim().to_ascii_uppercase().as_str() {
        "" | "B" => 1,
        "K" | "KB" => 1024,
        "M" | "MB" => 1024 * 1024,
        "G" | "GB" => 1024 * 1024 * 1024,
        "T" | "TB" => 1024u64 * 1024 * 1024 * 1024,
        // Unknown unit - safer to return 0 than to pretend.
        _ => return 0,
    };
    (num * multiplier as f64) as u64
}

pub fn preview(bin_dir: &str, project: &str, days: &str) -> Result<ArchivePreview, String> {
    validate_project(project)?;
    validate_days(days)?;
    let output = Command::new(Path::new(bin_dir).join("backmeup.archive.sh"))
        .args(["-n", project, days])
        .output()
        .map_err(|e| format!("failed to run backmeup.archive.sh: {e}"))?;
    let log = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if !output.status.success() {
        return Err(log);
    }
    let (count, total) = parse_preview(&String::from_utf8_lossy(&output.stdout));
    Ok(ArchivePreview {
        candidate_count: count,
        total_bytes_to_archive: total,
        log,
    })
}

pub fn commit(bin_dir: &str, project: &str, days: &str) -> Result<ArchiveRunOutput, String> {
    validate_project(project)?;
    validate_days(days)?;
    let output = Command::new(Path::new(bin_dir).join("backmeup.archive.sh"))
        .args([project, days])
        .output()
        .map_err(|e| format!("failed to run backmeup.archive.sh: {e}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let log = format!("{stdout}{stderr}");
    let ok = output.status.success();
    // Shape: "N snapshot(s) archived." — count by re-parsing.
    let archived_count = stdout
        .lines()
        .filter(|l| l.starts_with("archived "))
        .count() as u64;
    Ok(ArchiveRunOutput {
        archived_count,
        log,
        ok,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_project_rejects_path_separator() {
        assert!(validate_project("../etc").is_err());
        assert!(validate_project("a/b").is_err());
        assert!(validate_project("a\\b").is_err());
    }

    #[test]
    fn validate_project_rejects_empty_and_leading_dot() {
        assert!(validate_project("").is_err());
        assert!(validate_project(".bmureplicate-class").is_err());
        assert!(validate_project(".").is_err());
    }

    #[test]
    fn validate_project_accepts_normal_names() {
        assert!(validate_project("myproj").is_ok());
        assert!(validate_project("DSR-frame").is_ok());
        assert!(validate_project("Steuern 2025").is_ok());
    }

    #[test]
    fn validate_days_rejects_non_digits() {
        assert!(validate_days("").is_err());
        assert!(validate_days("30 ; rm -rf").is_err());
        assert!(validate_days("30d").is_err());
        assert!(validate_days("-30").is_err());
        assert!(validate_days("3.5").is_err());
    }

    #[test]
    fn validate_days_accepts_digits_only() {
        assert!(validate_days("0").is_ok());
        assert!(validate_days("30").is_ok());
        assert!(validate_days("99999").is_ok());
    }

    #[test]
    fn parse_du_sh_size_handles_common_units() {
        assert_eq!(parse_du_sh_size("0"), 0);
        assert_eq!(parse_du_sh_size("512"), 512);
        assert_eq!(parse_du_sh_size("512B"), 512);
        assert_eq!(parse_du_sh_size("8K"), 8 * 1024);
        assert_eq!(parse_du_sh_size("8.0K"), 8 * 1024);
        assert_eq!(parse_du_sh_size("1.5M"), (1.5 * 1024.0 * 1024.0) as u64);
        assert_eq!(parse_du_sh_size("2G"), 2 * 1024 * 1024 * 1024);
        assert_eq!(parse_du_sh_size("1T"), 1024u64 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_du_sh_size_returns_zero_on_garbage() {
        // Discipline: an unrecognized unit (new du version, locale
        // quirk) should NOT crash the preview - total just under-
        // counts for that row.
        assert_eq!(parse_du_sh_size(""), 0);
        assert_eq!(parse_du_sh_size("huge"), 0);
        assert_eq!(parse_du_sh_size("1Y"), 0);  // yottabytes unused in du
        assert_eq!(parse_du_sh_size("--"), 0);
    }

    #[test]
    fn parse_preview_counts_and_sums_would_archive_lines() {
        // Captured shape from a real `backmeup.archive.sh -n` run.
        let stdout = "Archiving myproj snapshots older than 180 days (before 20250601-000000, kind=generic)\n\
                      would archive B-20250511-120000 (42M) -> B-20250511-120000.tar.gz\n\
                      would archive B-20250512-120000 (18M) -> B-20250512-120000.tar.gz\n\
                      would archive B-20250513-120000 (1.5G) -> B-20250513-120000.tar.gz\n\
                      DRY RUN: 3 snapshot(s) would be archived, nothing was changed.\n";
        let (count, total) = parse_preview(stdout);
        assert_eq!(count, 3);
        // 42 + 18 = 60 MB + 1.5 GB. Just sanity-check the magnitude
        // (exact integer math on fractional MB -> bytes rounds).
        let expected_min = 1_600_000_000u64;
        let expected_max = 1_700_000_000u64;
        assert!(
            total >= expected_min && total <= expected_max,
            "total {total} outside [{expected_min}, {expected_max}]"
        );
    }

    #[test]
    fn parse_preview_ignores_header_and_summary_lines() {
        // Zero candidates case: only a header + "No snapshots..."
        // from backmeup.archive.sh. Preview should be count=0.
        let stdout = "Archiving myproj snapshots older than 180 days (before X, kind=generic)\n\
                      No snapshots older than 180 days.\n";
        let (count, total) = parse_preview(stdout);
        assert_eq!(count, 0);
        assert_eq!(total, 0);
    }

    #[test]
    fn parse_preview_tolerates_malformed_would_archive_lines() {
        // Shape drift tolerance: a line without matching parens
        // just contributes 0 bytes but still counts.
        let stdout = "would archive B-badshape\n\
                      would archive B-20250511-120000 (42M) -> B-20250511-120000.tar.gz\n";
        let (count, total) = parse_preview(stdout);
        assert_eq!(count, 2);
        // ~42 MB from the well-formed row.
        assert!(total >= 40_000_000);
    }
}
