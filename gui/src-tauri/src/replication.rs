// Off-site replication status/config - a narrow, dedicated GUI
// capability, not a general "reconfigure" screen (see gui/README.md's
// "no reconfigure/move-install UI" stance, which this is a deliberate,
// scoped exception to). Mirrors ignore.rs's line-scan-of-
// backmeup.setup.sh idiom for reads, and install.rs's run() helper
// shape for shelling out to backmeup.configure.sh's --replicate-*
// flags for writes. Never writes backmeup.setup.sh directly -
// configure.sh remains the one place that regenerates it, so this
// module can't drift out of sync with the CLI's own variable list.
use std::path::Path;
use std::process::Command;

/// The version backmeup.configure.sh first ships --replicate-backend=/
/// --replicate-remote-sync=/--replicate-remote-backups=/
/// --replicate-proton-remote=. Checked independently of
/// version::MIN_COMPATIBLE_VERSION, deliberately not folded into that
/// blanket gate: an older CLI's configure.sh already rejects an
/// unrecognized --replicate-backend= flag loudly on its own ("ERROR:
/// unrecognized argument", exit 1, surfaced as this module's own
/// Result<(), String> error) - unlike the ignore-settings case that
/// justified bumping MIN_COMPATIBLE_VERSION to 2.11.0, where an old
/// backmeup.sh would *silently* never read the GUI's .bmuconfig
/// writes. A loud, already-safe failure doesn't need every existing
/// GUI user locked out of the whole app just to gain this one
/// optional feature - a feature-local check showing a clear upgrade
/// message pre-emptively is enough.
pub const MIN_VERSION_FOR_FLAGS: (u32, u32, u32) = (2, 14, 0);

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "backend", rename_all = "snake_case")]
pub enum ReplicationStatus {
    Off,
    Rclone {
        remote_sync: String,
        remote_backups: String,
    },
    Proton {
        remote: String,
    },
}

#[derive(Debug, serde::Deserialize)]
#[serde(tag = "backend", rename_all = "snake_case")]
pub enum ReplicationRequest {
    Rclone {
        remote_sync: String,
        remote_backups: String,
    },
    Proton {
        // Omitted/None lets backmeup.configure.sh apply its own
        // /bmug2/<hostname> default - the default lives in exactly one
        // place (the shell script), not duplicated here.
        remote: Option<String>,
    },
}

// Same KEY="value" line-scan idiom as ignore.rs::read_setup_var and
// schedule.rs's own detection - not a real shell parser, just enough
// to pull one variable out of a generated setup file.
fn read_setup_var(bin_dir: &Path, key: &str) -> Option<String> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh")).ok()?;
    let prefix = format!("{key}=\"");
    contents.lines().find_map(|line| {
        line.trim()
            .strip_prefix(&prefix)
            .and_then(|rest| rest.strip_suffix('"'))
            .map(str::to_string)
    })
}

/// Always safe to call, even against an install that predates this
/// feature entirely - the vars just read back empty/absent, same as a
/// never-configured install.
pub fn get_status(bin_dir: &Path) -> ReplicationStatus {
    match read_setup_var(bin_dir, "BMU_REPLICATE_BACKEND").as_deref() {
        Some("rclone") => ReplicationStatus::Rclone {
            remote_sync: read_setup_var(bin_dir, "BMU_REPLICATE_REMOTE_SYNC").unwrap_or_default(),
            remote_backups: read_setup_var(bin_dir, "BMU_REPLICATE_REMOTE_BACKUPS")
                .unwrap_or_default(),
        },
        Some("proton") => ReplicationStatus::Proton {
            remote: read_setup_var(bin_dir, "BMU_REPLICATE_PROTON_REMOTE").unwrap_or_default(),
        },
        _ => ReplicationStatus::Off,
    }
}

/// Err with a clear message if bin_dir's installed CLI predates the
/// --replicate-* flags - same shape as version::check_compatible, but
/// a feature-local gate rather than the global minimum (see the
/// MIN_VERSION_FOR_FLAGS doc comment above for why).
pub fn check_flags_supported(bin_dir: &Path) -> Result<(), String> {
    match crate::version::read_installed_version(bin_dir) {
        Some(found) if found >= MIN_VERSION_FOR_FLAGS => Ok(()),
        Some(found) => Err(format!(
            "This install is bmug2 v{}.{}.{}, which predates off-site replication settings in the GUI (needs v{}.{}.{}+). Upgrade the CLI (re-run install.sh/configure.sh from a newer checkout) to use this panel.",
            found.0, found.1, found.2,
            MIN_VERSION_FOR_FLAGS.0, MIN_VERSION_FOR_FLAGS.1, MIN_VERSION_FOR_FLAGS.2
        )),
        None => Err(
            "This install has no version marker, so it predates off-site replication settings in the GUI.".to_string(),
        ),
    }
}

fn run_configure(bin_dir: &Path, args: &[String]) -> Result<(), String> {
    let mut cmd = Command::new(bin_dir.join("backmeup.configure.sh"));
    cmd.args(args);
    let name = format!("{cmd:?}");
    let output = cmd
        .output()
        .map_err(|e| format!("failed to run {name}: {e}"))?;
    let mut log = String::new();
    log.push_str(&String::from_utf8_lossy(&output.stdout));
    log.push_str(&String::from_utf8_lossy(&output.stderr));
    if output.status.success() {
        Ok(())
    } else {
        Err(log)
    }
}

pub fn set(bin_dir: &Path, request: ReplicationRequest) -> Result<(), String> {
    check_flags_supported(bin_dir)?;
    let args = match request {
        ReplicationRequest::Rclone {
            remote_sync,
            remote_backups,
        } => vec![
            "--replicate-backend=rclone".to_string(),
            format!("--replicate-remote-sync={remote_sync}"),
            format!("--replicate-remote-backups={remote_backups}"),
        ],
        ReplicationRequest::Proton { remote } => {
            let mut args = vec!["--replicate-backend=proton".to_string()];
            if let Some(remote) = remote.filter(|r| !r.is_empty()) {
                args.push(format!("--replicate-proton-remote={remote}"));
            }
            args
        }
    };
    run_configure(bin_dir, &args)
}

pub fn clear(bin_dir: &Path) -> Result<(), String> {
    check_flags_supported(bin_dir)?;
    run_configure(bin_dir, &["--replicate-backend=none".to_string()])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sandbox(name: &str, setup_contents: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("bmug2-replication-test-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("backmeup.setup.sh"), setup_contents).unwrap();
        dir
    }

    #[test]
    fn status_reads_off_when_backend_empty() {
        let dir = sandbox("off", "BMU_REPLICATE_BACKEND=\"\"\n");
        assert_eq!(get_status(&dir), ReplicationStatus::Off);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn status_reads_off_when_no_setup_file_at_all() {
        let dir = std::env::temp_dir().join(format!("bmug2-replication-test-nofile-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(get_status(&dir), ReplicationStatus::Off);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn status_reads_rclone_remotes() {
        let dir = sandbox(
            "rclone",
            "BMU_REPLICATE_BACKEND=\"rclone\"\nBMU_REPLICATE_REMOTE_SYNC=\"remote:a\"\nBMU_REPLICATE_REMOTE_BACKUPS=\"remote:b\"\n",
        );
        assert_eq!(
            get_status(&dir),
            ReplicationStatus::Rclone {
                remote_sync: "remote:a".to_string(),
                remote_backups: "remote:b".to_string(),
            }
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn status_reads_proton_remote() {
        let dir = sandbox(
            "proton",
            "BMU_REPLICATE_BACKEND=\"proton\"\nBMU_REPLICATE_PROTON_REMOTE=\"/bmug2/host\"\n",
        );
        assert_eq!(
            get_status(&dir),
            ReplicationStatus::Proton {
                remote: "/bmug2/host".to_string(),
            }
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_flags_supported_rejects_old_version() {
        let dir = sandbox("oldver", "BMU_VERSION=\"2.13.0\"\n");
        let err = check_flags_supported(&dir).unwrap_err();
        assert!(err.contains("2.13.0"), "message should name the found version: {err}");
        assert!(err.contains("2.14.0"), "message should name the required version: {err}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_flags_supported_accepts_matching_or_newer() {
        let dir = sandbox("matchver", "BMU_VERSION=\"2.14.0\"\n");
        assert!(check_flags_supported(&dir).is_ok());
        std::fs::remove_dir_all(&dir).ok();

        let dir = sandbox("newerver", "BMU_VERSION=\"2.15.0\"\n");
        assert!(check_flags_supported(&dir).is_ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn check_flags_supported_rejects_missing_version_marker() {
        let dir = sandbox("noversion", "BMU_DIRRSYNC=\"/tmp/x\"\n");
        assert!(check_flags_supported(&dir).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }

    fn fake_configure_script(dir: &Path, log_path: &Path, exit_code: i32) {
        let script = format!(
            "#!/bin/sh\necho \"$@\" > \"{}\"\nexit {}\n",
            log_path.display(),
            exit_code
        );
        let path = dir.join("backmeup.configure.sh");
        std::fs::write(&path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&path, perms).unwrap();
        }
    }

    #[test]
    fn set_rclone_calls_configure_with_the_right_flags() {
        let dir = sandbox("set-rclone", "BMU_VERSION=\"2.14.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 0);

        let result = set(
            &dir,
            ReplicationRequest::Rclone {
                remote_sync: "remote:a".to_string(),
                remote_backups: "remote:b".to_string(),
            },
        );
        assert!(result.is_ok(), "set failed: {result:?}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(logged.contains("--replicate-backend=rclone"));
        assert!(logged.contains("--replicate-remote-sync=remote:a"));
        assert!(logged.contains("--replicate-remote-backups=remote:b"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn set_proton_omits_remote_flag_when_blank() {
        let dir = sandbox("set-proton-blank", "BMU_VERSION=\"2.14.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 0);

        let result = set(&dir, ReplicationRequest::Proton { remote: None });
        assert!(result.is_ok(), "set failed: {result:?}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(logged.contains("--replicate-backend=proton"));
        assert!(!logged.contains("--replicate-proton-remote="));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn set_proton_includes_remote_flag_when_given() {
        let dir = sandbox("set-proton-explicit", "BMU_VERSION=\"2.14.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 0);

        let result = set(
            &dir,
            ReplicationRequest::Proton {
                remote: Some("/bmug2/custom".to_string()),
            },
        );
        assert!(result.is_ok(), "set failed: {result:?}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(logged.contains("--replicate-proton-remote=/bmug2/custom"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn clear_calls_configure_with_none() {
        let dir = sandbox("clear", "BMU_VERSION=\"2.14.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 0);

        let result = clear(&dir);
        assert!(result.is_ok(), "clear failed: {result:?}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(logged.contains("--replicate-backend=none"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn set_rejects_old_install_before_ever_shelling_out() {
        let dir = sandbox("set-rejects-old", "BMU_VERSION=\"2.13.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 0);

        let result = set(
            &dir,
            ReplicationRequest::Proton { remote: None },
        );
        assert!(result.is_err());
        assert!(!log.exists(), "should not have shelled out to configure.sh at all");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn set_surfaces_configure_sh_failure() {
        let dir = sandbox("set-failure", "BMU_VERSION=\"2.14.0\"\n");
        let log = dir.join("call.log");
        fake_configure_script(&dir, &log, 1);

        let result = set(&dir, ReplicationRequest::Proton { remote: None });
        assert!(result.is_err());
        std::fs::remove_dir_all(&dir).ok();
    }
}
