// Budget read/write - the GUI-facing counterpart of
// bmuReadBudgetKey (in backmeup.shellfunctions.sh). Phase 3 of the
// disk-size project; Phase 2 shipped the shell-side reader +
// backmeup.sh's end-of-run WARNING. This module writes.
//
// Two scopes:
//   Global - BMU_SYNC_WARN_BYTES / BMU_HISTORY_WARN_BYTES, lines
//            in the installed backmeup.setup.sh. Rewriting those
//            lines in place matches how config.rs's own
//            setup_var/replicate flags are already persisted.
//   Per-source - a `.bmubudget` sidecar inside
//            `${BMU_DIRBACKUPS}/<project>/`, same shape as
//            `.bmukind` / `.bmureplicate-class`. One KEY=value line
//            per key, no quoting, blank/missing = "fall back to
//            global".
//
// Both scopes are idempotent: setting to `None` deletes the key
// (globally, writes an empty `KEY=""`; per-source, drops the line),
// keeping the shell's "empty = unset = silent" contract.

use std::path::{Path, PathBuf};

fn read_setup_var(bin_dir: &Path, key: &str) -> Option<String> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh")).ok()?;
    let prefix = format!("{key}=\"");
    for line in contents.lines() {
        if let Some(rest) = line.trim().strip_prefix(&prefix) {
            return rest.strip_suffix('"').map(str::to_string);
        }
    }
    None
}

/// Resolve the per-project .bmubudget path from the installed
/// setup.sh. Returns None when BMU_DIRBACKUPS can't be read - same
/// contract as `source_kind::sidecar`, lets the Tauri command
/// surface a clear "reinstall / re-run configure.sh" error.
fn sidecar_path(bin_dir: &Path, source_path: &str) -> Option<PathBuf> {
    let history_dir = read_setup_var(bin_dir, "BMU_DIRBACKUPS")?;
    let project = Path::new(source_path).file_name()?.to_string_lossy().to_string();
    Some(PathBuf::from(history_dir).join(project).join(".bmubudget"))
}

/// Which BMU_* variable a BudgetKey maps to in setup.sh for the
/// global scope. The per-source sidecar's keys (SYNC_WARN_BYTES /
/// HISTORY_WARN_BYTES) are matched directly on strings in
/// `read_source` below rather than routed through this enum - the
/// read path is a flat parse of a tiny file and gains nothing from
/// the indirection.
#[derive(Debug, Copy, Clone, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BudgetKey {
    Sync,
    History,
}

impl BudgetKey {
    fn global_var(self) -> &'static str {
        match self {
            BudgetKey::Sync => "BMU_SYNC_WARN_BYTES",
            BudgetKey::History => "BMU_HISTORY_WARN_BYTES",
        }
    }
}

/// Global budget, both keys at once. `None` means unset (shell
/// reads as "silent"); `Some(n)` is bytes.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Deserialize, serde::Serialize)]
pub struct GlobalBudget {
    #[serde(default)]
    pub sync_warn_bytes: Option<u64>,
    #[serde(default)]
    pub history_warn_bytes: Option<u64>,
}

pub fn read_global(bin_dir: &Path) -> GlobalBudget {
    GlobalBudget {
        sync_warn_bytes: read_setup_var(bin_dir, BudgetKey::Sync.global_var())
            .filter(|s| !s.is_empty())
            .and_then(|s| s.parse().ok()),
        history_warn_bytes: read_setup_var(bin_dir, BudgetKey::History.global_var())
            .filter(|s| !s.is_empty())
            .and_then(|s| s.parse().ok()),
    }
}

/// Write / clear a global budget key in setup.sh. If `bytes` is
/// `None`, the line is written as `KEY=""` (shell sees unset).
/// Rewrites exactly the one matching line; any surrounding comment
/// or other var is left untouched. If the key doesn't appear in
/// setup.sh at all (possible on an install predating Phase 2 that
/// hasn't been re-configured), we append a new line - keeps this
/// callable against older installs without forcing a reconfigure.
///
/// Atomic: writes to a tempfile in the same dir and renames, same
/// discipline config.rs uses for config.json.
pub fn set_global(bin_dir: &Path, key: BudgetKey, bytes: Option<u64>) -> Result<(), String> {
    let setup = bin_dir.join("backmeup.setup.sh");
    let contents = std::fs::read_to_string(&setup)
        .map_err(|e| format!("cannot read {}: {e}", setup.display()))?;
    let prefix = format!("{}=\"", key.global_var());
    let replacement_value = bytes.map(|b| b.to_string()).unwrap_or_default();
    let new_line = format!("{}=\"{}\"", key.global_var(), replacement_value);

    let mut rewrote = false;
    let mut new_contents = String::with_capacity(contents.len() + new_line.len());
    for line in contents.lines() {
        if !rewrote && line.trim_start().starts_with(&prefix) {
            new_contents.push_str(&new_line);
            new_contents.push('\n');
            rewrote = true;
        } else {
            new_contents.push_str(line);
            new_contents.push('\n');
        }
    }
    // Preserve trailing newline shape (lines() drops it; we added
    // one per line above, so we're correct for any input).
    if !rewrote {
        // Legacy install never saw this key; append.
        new_contents.push_str(&new_line);
        new_contents.push('\n');
    }

    let tmp = setup.with_extension("sh.budget.tmp");
    std::fs::write(&tmp, new_contents)
        .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &setup)
        .map_err(|e| format!("cannot rename {}: {e}", setup.display()))?;
    Ok(())
}

/// Per-source budget, both keys. `None` means fall back to the
/// global default (matches the shell's precedence contract).
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Deserialize, serde::Serialize)]
pub struct SourceBudget {
    #[serde(default)]
    pub sync_warn_bytes: Option<u64>,
    #[serde(default)]
    pub history_warn_bytes: Option<u64>,
}

pub fn read_source(bin_dir: &Path, source_path: &str) -> SourceBudget {
    let Some(path) = sidecar_path(bin_dir, source_path) else {
        return SourceBudget::default();
    };
    let Ok(contents) = std::fs::read_to_string(&path) else {
        return SourceBudget::default();
    };
    let mut out = SourceBudget::default();
    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let k = k.trim();
        let v = v.trim().trim_matches('"').trim_matches('\'');
        let Ok(parsed) = v.parse::<u64>() else {
            continue;
        };
        match k {
            "SYNC_WARN_BYTES" => out.sync_warn_bytes = Some(parsed),
            "HISTORY_WARN_BYTES" => out.history_warn_bytes = Some(parsed),
            _ => {}
        }
    }
    out
}

/// Write the per-source .bmubudget sidecar. Keys whose budget is
/// `None` are dropped from the file; if both end up `None` the
/// sidecar is removed entirely (keeps the directory listing clean
/// for a user who dials both back). Creates the parent dir if the
/// project has never been backed up yet, same discipline as
/// `replication::set_source_class`.
pub fn set_source(
    bin_dir: &Path,
    source_path: &str,
    budget: SourceBudget,
) -> Result<(), String> {
    let path = sidecar_path(bin_dir, source_path).ok_or_else(|| {
        format!(
            "cannot resolve BMU_DIRBACKUPS from {} - reinstall or re-run configure.sh",
            bin_dir.display()
        )
    })?;
    if budget == SourceBudget::default() {
        // Both keys unset -> drop the sidecar entirely.
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("cannot remove {}: {e}", path.display())),
        }
    } else {
        let parent = path
            .parent()
            .ok_or_else(|| format!("cannot determine parent of {}", path.display()))?;
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        let mut body = String::new();
        if let Some(v) = budget.sync_warn_bytes {
            body.push_str(&format!("SYNC_WARN_BYTES={v}\n"));
        }
        if let Some(v) = budget.history_warn_bytes {
            body.push_str(&format!("HISTORY_WARN_BYTES={v}\n"));
        }
        std::fs::write(&path, body)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn sandbox(label: &str) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let base = std::env::temp_dir().join(format!("bmug2-budget-{label}-{}-{n}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        let bin = base.join("bin");
        let bp = base.join("history");
        let src = base.join("src/myproj");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&bp).unwrap();
        std::fs::create_dir_all(&src).unwrap();
        // Minimal setup.sh with just BMU_DIRBACKUPS - enough for
        // sidecar resolution; add BMU_*_WARN_BYTES per test.
        std::fs::write(
            bin.join("backmeup.setup.sh"),
            format!("BMU_DIRBACKUPS=\"{}\"\n", bp.display()),
        )
        .unwrap();
        (bin, bp, src)
    }

    #[test]
    fn read_global_returns_none_when_setup_has_no_budget_keys() {
        let (bin, _, _) = sandbox("read-empty");
        let got = read_global(&bin);
        assert_eq!(got, GlobalBudget::default());
    }

    #[test]
    fn read_global_parses_both_keys_from_setup() {
        let (bin, _, _) = sandbox("read-both");
        let setup = bin.join("backmeup.setup.sh");
        let mut body = std::fs::read_to_string(&setup).unwrap();
        body.push_str("BMU_SYNC_WARN_BYTES=\"50000000000\"\n");
        body.push_str("BMU_HISTORY_WARN_BYTES=\"\"\n"); // empty = unset
        std::fs::write(&setup, body).unwrap();

        let got = read_global(&bin);
        assert_eq!(got.sync_warn_bytes, Some(50_000_000_000));
        // Empty string must parse back as None, not Some(0) - that's
        // the "unset" contract shared with the shell layer.
        assert_eq!(got.history_warn_bytes, None);
    }

    #[test]
    fn set_global_rewrites_existing_line_in_place() {
        let (bin, _, _) = sandbox("set-rewrite");
        let setup = bin.join("backmeup.setup.sh");
        std::fs::write(
            &setup,
            "BMU_DIRBACKUPS=\"/history\"\nBMU_SYNC_WARN_BYTES=\"100\"\nBMU_OTHER=\"keep\"\n",
        )
        .unwrap();

        set_global(&bin, BudgetKey::Sync, Some(999)).unwrap();
        let contents = std::fs::read_to_string(&setup).unwrap();
        assert!(contents.contains("BMU_SYNC_WARN_BYTES=\"999\""));
        // Didn't duplicate the key
        assert_eq!(contents.matches("BMU_SYNC_WARN_BYTES").count(), 1);
        // Left adjacent lines alone
        assert!(contents.contains("BMU_DIRBACKUPS=\"/history\""));
        assert!(contents.contains("BMU_OTHER=\"keep\""));
    }

    #[test]
    fn set_global_to_none_writes_empty_string_not_removes_line() {
        // Shell contract is "empty = unset = silent"; writing
        // BMU_SYNC_WARN_BYTES="" is the idiomatic way to disable
        // the warning, not deleting the whole variable declaration.
        let (bin, _, _) = sandbox("set-none");
        let setup = bin.join("backmeup.setup.sh");
        std::fs::write(
            &setup,
            "BMU_SYNC_WARN_BYTES=\"42\"\nBMU_HISTORY_WARN_BYTES=\"7\"\n",
        )
        .unwrap();

        set_global(&bin, BudgetKey::Sync, None).unwrap();
        let contents = std::fs::read_to_string(&setup).unwrap();
        assert!(contents.contains("BMU_SYNC_WARN_BYTES=\"\""));
        assert!(contents.contains("BMU_HISTORY_WARN_BYTES=\"7\""));
    }

    #[test]
    fn set_global_appends_when_key_is_missing_from_legacy_setup() {
        // An install predating Phase 2 won't have the key at all.
        // The command still has to work (otherwise users have to
        // reconfigure before setting a budget).
        let (bin, _, _) = sandbox("set-legacy");
        let setup = bin.join("backmeup.setup.sh");
        std::fs::write(
            &setup,
            "BMU_DIRBACKUPS=\"/history\"\nBMU_VERSION=\"2.18.0\"\n",
        )
        .unwrap();

        set_global(&bin, BudgetKey::History, Some(2048)).unwrap();
        let contents = std::fs::read_to_string(&setup).unwrap();
        assert!(contents.contains("BMU_HISTORY_WARN_BYTES=\"2048\""));
        // Legacy content preserved
        assert!(contents.contains("BMU_VERSION=\"2.18.0\""));
    }

    #[test]
    fn read_source_defaults_when_sidecar_missing() {
        let (bin, _, src) = sandbox("read-source-missing");
        let got = read_source(&bin, src.to_str().unwrap());
        assert_eq!(got, SourceBudget::default());
    }

    #[test]
    fn set_and_read_source_round_trip() {
        let (bin, bp, src) = sandbox("roundtrip");
        // Project dir must exist so the sidecar path resolves
        // correctly.
        std::fs::create_dir_all(bp.join("myproj")).unwrap();

        set_source(
            &bin,
            src.to_str().unwrap(),
            SourceBudget {
                sync_warn_bytes: Some(10_000),
                history_warn_bytes: None,
            },
        )
        .unwrap();
        let got = read_source(&bin, src.to_str().unwrap());
        assert_eq!(got.sync_warn_bytes, Some(10_000));
        // Not writing the HISTORY key when it's None means a later
        // read must return None for it, not inherit some previous
        // value.
        assert_eq!(got.history_warn_bytes, None);
    }

    #[test]
    fn set_source_removes_sidecar_when_both_keys_none() {
        // Dialing both keys back to None must drop the sidecar
        // entirely - keeps HISTORY/<project>/ clean when the user
        // decides budgets aren't for them.
        let (bin, bp, src) = sandbox("remove");
        std::fs::create_dir_all(bp.join("myproj")).unwrap();
        let sidecar = bp.join("myproj").join(".bmubudget");
        std::fs::write(&sidecar, "SYNC_WARN_BYTES=42\n").unwrap();
        assert!(sidecar.exists());

        set_source(&bin, src.to_str().unwrap(), SourceBudget::default()).unwrap();
        assert!(!sidecar.exists());
    }

    #[test]
    fn set_source_creates_project_dir_when_backup_never_ran() {
        // A user can set a budget on a source they just added, before
        // any backmeup.sh run has created HISTORY/<project>/.
        // set_source must create the parent dir, not fail.
        let (bin, bp, src) = sandbox("precreate");
        // Deliberately NOT creating bp/myproj
        assert!(!bp.join("myproj").exists());

        set_source(
            &bin,
            src.to_str().unwrap(),
            SourceBudget {
                sync_warn_bytes: Some(1234),
                history_warn_bytes: None,
            },
        )
        .unwrap();
        assert!(bp.join("myproj").join(".bmubudget").exists());
    }

    #[test]
    fn read_source_tolerates_malformed_sidecar_lines() {
        // Same permissive discipline the shell layer uses: a typo
        // reads as "not set" - a bad budget never crashes the GUI.
        let (bin, bp, src) = sandbox("malformed");
        std::fs::create_dir_all(bp.join("myproj")).unwrap();
        let sidecar = bp.join("myproj").join(".bmubudget");
        std::fs::write(
            &sidecar,
            "# comment line ignored\n\n\
             SYNC_WARN_BYTES=twelve-and-a-half\n\
             UNKNOWN_KEY=123\n\
             HISTORY_WARN_BYTES=\"4096\"\n",
        )
        .unwrap();

        let got = read_source(&bin, src.to_str().unwrap());
        // Non-numeric value drops silently
        assert_eq!(got.sync_warn_bytes, None);
        // Quoted value still parses
        assert_eq!(got.history_warn_bytes, Some(4096));
    }
}
