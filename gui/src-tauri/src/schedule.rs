// Generates and installs real recurring schedules - launchd on macOS,
// systemd user timers on Linux - per docs/SCHEDULING.md's own recipes,
// so a GUI user never has to hand-write a plist or unit file. cron/
// `at` stay CLI-only (see that doc); this only ever writes the native,
// platform-preferred mechanism.
//
// One generic capability (install/uninstall/status) is reused for
// both per-source schedules and the optional housekeeping
// (updatedb+replicate) schedule - they differ only in label, wrapper
// script content, and where the result gets mirrored in config.json.
//
// The installed plist/timer file is the source of truth for "is this
// actually scheduled" - status() reads it back rather than trusting
// config.json's BackupSource.schedule/Config.housekeeping_schedule
// fields, which are only a UI-convenience mirror kept in sync by
// install()/uninstall() themselves.
use crate::config::Schedule;
use std::path::{Path, PathBuf};

#[cfg(any(target_os = "macos", test))]
const PATH_ENV_MACOS: &str = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
#[cfg(any(target_os = "linux", test))]
const PATH_ENV_LINUX: &str = "/usr/bin:/bin:/usr/local/bin";

// A stable, version-independent hash - std::hash::DefaultHasher's
// algorithm is explicitly documented as unspecified and may change
// between Rust releases, unsuitable for a value (a launchd
// Label/systemd unit name) that must stay stable across app updates
// so an already-installed schedule keeps matching its source on the
// next run. FNV-1a is tiny, deterministic, and dependency-free.
fn slug(path: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in path.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

pub fn source_label(source_path: &str) -> String {
    format!("io.github.mariotti.bmug2.backup.{}", slug(source_path))
}

pub const HOUSEKEEPING_LABEL: &str = "io.github.mariotti.bmug2.housekeeping";

/// Filesystem-safe fragment taken from the source path's own
/// basename - purely cosmetic, appended to the wrapper/plist/log (or
/// service/timer) filenames so macOS's "Allow in the Background"
/// list, which displays each LaunchAgent by its wrapper script's own
/// filename rather than the plist's internal Label, is identifiable
/// per project instead of showing only source_label()'s opaque hash.
/// Never used for the launchd Label/systemd unit name itself - that
/// stays source_label()'s hash, unchanged, so an already-installed
/// schedule's real identity is never affected by this.
pub fn source_file_hint(source_path: &str) -> String {
    let name = Path::new(source_path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .take(40)
        .collect()
}

/// The filename stem used for a schedule's on-disk files - the bare
/// label when there's no hint (housekeeping, and the exact pre-fix
/// shape for a per-source schedule), or label-hint otherwise. Never
/// used for the plist's internal Label/systemd unit name - see
/// source_file_hint above.
fn file_stem(label: &str, hint: &str) -> String {
    if hint.is_empty() {
        label.to_string()
    } else {
        format!("{label}-{hint}")
    }
}

pub fn build_source_wrapper(bin_dir: &str, source_path: &str) -> String {
    format!(
        "#!/bin/sh\nset -e\n\"{bin_dir}/backmeup.sh\" \"{source_path}\"\n",
    )
}

/// Appends whichever replicate script matches the configured backend -
/// detected by reading BMU_REPLICATE_BACKEND="..." out of
/// bin_dir/backmeup.setup.sh, the same simple KEY="value" line-scan
/// version.rs::read_installed_version already uses for BMU_VERSION.
/// Reading BMU_REPLICATE_BACKEND (not the rclone-only BMU_CMDREPLICATE)
/// is what makes this correct for both backends - a Proton-configured
/// install used to silently never run backmeup.replicate.proton.sh on
/// its housekeeping schedule before this fix, since the old check only
/// ever looked for rclone's own variable.
pub fn build_housekeeping_wrapper(bin_dir: &str) -> String {
    let mut script = format!("#!/bin/sh\nset -e\n\"{bin_dir}/backmeup.updatedb.sh\"\n");
    match configured_replication_backend(Path::new(bin_dir)).as_deref() {
        Some("rclone") => script.push_str(&format!("\"{bin_dir}/backmeup.replicate.sh\"\n")),
        Some("proton") => script.push_str(&format!("\"{bin_dir}/backmeup.replicate.proton.sh\"\n")),
        _ => {}
    }
    script
}

pub(crate) fn configured_replication_backend(bin_dir: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(bin_dir.join("backmeup.setup.sh")).ok()?;
    contents.lines().find_map(|line| {
        line.trim()
            .strip_prefix("BMU_REPLICATE_BACKEND=\"")
            .and_then(|rest| rest.strip_suffix('"'))
            .filter(|backend| !backend.is_empty())
            .map(str::to_string)
    })
}

/// Daily emits the existing StartCalendarInterval dict; Interval emits
/// a StartInterval integer (seconds) instead - a different launchd key
/// entirely, not just a different value, per `man launchd.plist`:
/// "StartInterval ... causes the job to be started every N seconds ...
/// If the job is running during an interval firing, that interval
/// firing will likewise be missed" (verified on this machine) - so
/// launchd itself guarantees no overlapping concurrent runs of the
/// same schedule.
#[cfg(any(target_os = "macos", test))]
pub fn build_plist(label: &str, wrapper_path: &str, schedule: &Schedule, log_path: &str) -> String {
    let trigger = match *schedule {
        Schedule::Daily { hour, minute } => format!(
            "    <key>StartCalendarInterval</key>\n    <dict>\n        <key>Hour</key>\n        <integer>{hour}</integer>\n        <key>Minute</key>\n        <integer>{minute}</integer>\n    </dict>\n"
        ),
        Schedule::Interval { minutes } => format!(
            "    <key>StartInterval</key>\n    <integer>{}</integer>\n",
            minutes * 60
        ),
    };
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{wrapper_path}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{PATH_ENV_MACOS}</string>
    </dict>
{trigger}    <key>StandardOutPath</key>
    <string>{log_path}</string>
    <key>StandardErrorPath</key>
    <string>{log_path}</string>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
"#
    )
}

/// Reads the schedule back out of a plist written by build_plist - a
/// simple string scan (matching version.rs's own "not a full parser"
/// philosophy), not a plist crate. Tries StartInterval (Interval)
/// first since it's the more specific/unambiguous shape, falls back
/// to Hour/Minute (Daily).
#[cfg(any(target_os = "macos", test))]
pub fn parse_plist_schedule(contents: &str) -> Option<Schedule> {
    if let Some(seconds) = extract_plist_integer(contents, "StartInterval") {
        return Some(Schedule::Interval { minutes: seconds / 60 });
    }
    let hour = extract_plist_integer(contents, "Hour")?;
    let minute = extract_plist_integer(contents, "Minute")?;
    Some(Schedule::Daily { hour, minute })
}

#[cfg(any(target_os = "macos", test))]
fn extract_plist_integer(contents: &str, key: &str) -> Option<u32> {
    let key_tag = format!("<key>{key}</key>");
    let after_key = &contents[contents.find(&key_tag)? + key_tag.len()..];
    let after_open = after_key.trim_start().strip_prefix("<integer>")?;
    let value = &after_open[..after_open.find("</integer>")?];
    value.trim().parse().ok()
}

#[cfg(any(target_os = "linux", test))]
pub fn build_service(description: &str, wrapper_path: &str) -> String {
    format!(
        "[Unit]\nDescription={description}\n\n[Service]\nType=oneshot\nEnvironment=PATH={PATH_ENV_LINUX}\nExecStart={wrapper_path}\nNice=10\nIOSchedulingClass=idle\n"
    )
}

/// Both variants use OnCalendar= - not a different directive, just a
/// different value shape. Daily keeps the wall-clock form; Interval
/// uses systemd's "*:0/N" step syntax (verified for real: inside an
/// Ubuntu 24.04 container, `systemd-analyze verify` accepts it and
/// `systemd-analyze calendar --iterations=3 '*:0/5'` confirms real
/// 5-minute-apart firings at :00/:05/:10/...), the same mechanism
/// cron's `*/N * * * *` provides.
#[cfg(any(target_os = "linux", test))]
pub fn build_timer(description: &str, schedule: &Schedule) -> String {
    let on_calendar = match *schedule {
        Schedule::Daily { hour, minute } => format!("*-*-* {hour:02}:{minute:02}:00"),
        Schedule::Interval { minutes } => format!("*:0/{minutes}"),
    };
    format!(
        "[Unit]\nDescription={description}\n\n[Timer]\nOnCalendar={on_calendar}\nPersistent=true\nRandomizedDelaySec=300\n\n[Install]\nWantedBy=timers.target\n"
    )
}

/// Reads the schedule back out of a .timer file written by
/// build_timer. Tries the interval shape first (unambiguous - no
/// other OnCalendar= value bmug2 ever generates starts with "*:0/"),
/// falls back to the daily wall-clock shape.
#[cfg(any(target_os = "linux", test))]
pub fn parse_timer_schedule(contents: &str) -> Option<Schedule> {
    let line = contents
        .lines()
        .find_map(|l| l.trim().strip_prefix("OnCalendar="))?;
    if let Some(minutes) = line.strip_prefix("*:0/").and_then(|m| m.parse().ok()) {
        return Some(Schedule::Interval { minutes });
    }
    let time = line.strip_prefix("*-*-* ")?.split(' ').next()?;
    let mut parts = time.split(':');
    let hour = parts.next()?.parse().ok()?;
    let minute = parts.next()?.parse().ok()?;
    Some(Schedule::Daily { hour, minute })
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    fn plist_path(label: &str, hint: &str) -> Result<PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "cannot resolve HOME".to_string())?;
        Ok(PathBuf::from(home)
            .join("Library/LaunchAgents")
            .join(format!("{}.plist", file_stem(label, hint))))
    }

    fn wrapper_path(label: &str, hint: &str) -> Result<PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "cannot resolve HOME".to_string())?;
        Ok(PathBuf::from(home)
            .join("Library/Application Support/io.github.mariotti.bmug2/schedules")
            .join(format!("{}.sh", file_stem(label, hint))))
    }

    fn log_path(label: &str, hint: &str) -> Result<PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "cannot resolve HOME".to_string())?;
        Ok(PathBuf::from(home)
            .join("Library/Logs")
            .join(format!("{}.log", file_stem(label, hint))))
    }

    pub fn install(
        label: &str,
        wrapper_content: &str,
        schedule: &Schedule,
        _description: &str,
        hint: &str,
    ) -> Result<(), String> {
        // Best-effort cleanup of a pre-this-change install's old
        // (hint-less) files, so re-saving an already-installed
        // schedule self-heals its on-disk filenames. Never fails the
        // install if these are already gone or never existed.
        if !hint.is_empty() {
            if let Ok(old) = wrapper_path(label, "") {
                std::fs::remove_file(old).ok();
            }
            if let Ok(old) = plist_path(label, "") {
                std::fs::remove_file(old).ok();
            }
            if let Ok(old) = log_path(label, "") {
                std::fs::remove_file(old).ok();
            }
        }

        let wrapper = wrapper_path(label, hint)?;
        std::fs::create_dir_all(wrapper.parent().unwrap())
            .map_err(|e| format!("cannot create {}: {e}", wrapper.parent().unwrap().display()))?;
        std::fs::write(&wrapper, wrapper_content)
            .map_err(|e| format!("cannot write {}: {e}", wrapper.display()))?;
        set_executable(&wrapper)?;

        let log = log_path(label, hint)?;
        let plist = plist_path(label, hint)?;
        let content = build_plist(label, wrapper.to_str().unwrap(), schedule, log.to_str().unwrap());
        std::fs::write(&plist, content).map_err(|e| format!("cannot write {}: {e}", plist.display()))?;

        // A stale load from a previous install (e.g. re-scheduling at
        // a new time) is harmless to bootout first - ignore its result.
        let _ = run_launchctl(&["bootout", &format!("gui/{}/{label}", uid()?)]);
        run_launchctl(&["bootstrap", &format!("gui/{}", uid()?), plist.to_str().unwrap()])
    }

    pub fn uninstall(label: &str, hint: &str) -> Result<(), String> {
        let _ = run_launchctl(&["bootout", &format!("gui/{}/{label}", uid()?)]);
        // Always try both the current (hinted) and the old (hint-less)
        // paths - removing an already-missing file is a no-op, and
        // this is what lets uninstall() fully clean up a schedule that
        // was installed before this change and never re-saved since.
        for candidate_hint in [hint, ""] {
            if let Ok(plist) = plist_path(label, candidate_hint) {
                std::fs::remove_file(plist).ok();
            }
            if let Ok(wrapper) = wrapper_path(label, candidate_hint) {
                std::fs::remove_file(wrapper).ok();
            }
        }
        Ok(())
    }

    pub fn status(label: &str, hint: &str) -> Option<Schedule> {
        let plist = plist_path(label, hint).ok()?;
        let contents = match std::fs::read_to_string(&plist) {
            Ok(contents) => contents,
            Err(_) => {
                let old_plist = plist_path(label, "").ok()?;
                std::fs::read_to_string(old_plist).ok()?
            }
        };
        parse_plist_schedule(&contents)
    }

    fn set_executable(path: &Path) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)
            .map_err(|e| format!("cannot stat {}: {e}", path.display()))?
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)
            .map_err(|e| format!("cannot chmod {}: {e}", path.display()))
    }

    fn uid() -> Result<String, String> {
        let output = std::process::Command::new("id")
            .arg("-u")
            .output()
            .map_err(|e| format!("failed to run id -u: {e}"))?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    fn run_launchctl(args: &[&str]) -> Result<(), String> {
        let output = std::process::Command::new("launchctl")
            .args(args)
            .output()
            .map_err(|e| format!("failed to run launchctl {args:?}: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "launchctl {args:?} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;

    fn systemd_user_dir() -> Result<PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "cannot resolve HOME".to_string())?;
        Ok(PathBuf::from(home).join(".config/systemd/user"))
    }

    fn wrapper_path(label: &str, hint: &str) -> Result<PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "cannot resolve HOME".to_string())?;
        Ok(PathBuf::from(home)
            .join(".local/share/io.github.mariotti.bmug2/schedules")
            .join(format!("{}.sh", file_stem(label, hint))))
    }

    fn unit_name(label: &str, hint: &str) -> String {
        format!("bmug2-{}", file_stem(label, hint))
    }

    pub fn install(
        label: &str,
        wrapper_content: &str,
        schedule: &Schedule,
        description: &str,
        hint: &str,
    ) -> Result<(), String> {
        // Best-effort cleanup of a pre-this-change install's old
        // (hint-less) files, so re-saving an already-installed
        // schedule self-heals its on-disk filenames. Never fails the
        // install if these are already gone or never existed.
        if !hint.is_empty() {
            if let Ok(old) = wrapper_path(label, "") {
                std::fs::remove_file(old).ok();
            }
            if let Ok(dir) = systemd_user_dir() {
                let old_name = unit_name(label, "");
                std::fs::remove_file(dir.join(format!("{old_name}.service"))).ok();
                std::fs::remove_file(dir.join(format!("{old_name}.timer"))).ok();
            }
        }

        let wrapper = wrapper_path(label, hint)?;
        std::fs::create_dir_all(wrapper.parent().unwrap())
            .map_err(|e| format!("cannot create {}: {e}", wrapper.parent().unwrap().display()))?;
        std::fs::write(&wrapper, wrapper_content)
            .map_err(|e| format!("cannot write {}: {e}", wrapper.display()))?;
        set_executable(&wrapper)?;

        let dir = systemd_user_dir()?;
        std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        let name = unit_name(label, hint);
        let service_path = dir.join(format!("{name}.service"));
        let timer_path = dir.join(format!("{name}.timer"));
        std::fs::write(&service_path, build_service(description, wrapper.to_str().unwrap()))
            .map_err(|e| format!("cannot write {}: {e}", service_path.display()))?;
        std::fs::write(&timer_path, build_timer(description, schedule))
            .map_err(|e| format!("cannot write {}: {e}", timer_path.display()))?;

        run_systemctl(&["--user", "daemon-reload"])?;
        run_systemctl(&["--user", "enable", "--now", &format!("{name}.timer")])
    }

    pub fn uninstall(label: &str, hint: &str) -> Result<(), String> {
        let dir = systemd_user_dir()?;
        // Always try both the current (hinted) and the old (hint-less)
        // unit names - removing an already-missing file is a no-op,
        // and this is what lets uninstall() fully clean up a schedule
        // that was installed before this change and never re-saved
        // since.
        for candidate_hint in [hint, ""] {
            let name = unit_name(label, candidate_hint);
            let _ = run_systemctl(&["--user", "disable", "--now", &format!("{name}.timer")]);
            std::fs::remove_file(dir.join(format!("{name}.service"))).ok();
            std::fs::remove_file(dir.join(format!("{name}.timer"))).ok();
            if let Ok(wrapper) = wrapper_path(label, candidate_hint) {
                std::fs::remove_file(wrapper).ok();
            }
        }
        let _ = run_systemctl(&["--user", "daemon-reload"]);
        Ok(())
    }

    pub fn status(label: &str, hint: &str) -> Option<Schedule> {
        let dir = systemd_user_dir().ok()?;
        let timer_path = dir.join(format!("{}.timer", unit_name(label, hint)));
        let contents = std::fs::read_to_string(&timer_path).or_else(|_| {
            let old_timer_path = dir.join(format!("{}.timer", unit_name(label, "")));
            std::fs::read_to_string(old_timer_path)
        });
        parse_timer_schedule(&contents.ok()?)
    }

    fn set_executable(path: &Path) -> Result<(), String> {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(path)
            .map_err(|e| format!("cannot stat {}: {e}", path.display()))?
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(path, perms)
            .map_err(|e| format!("cannot chmod {}: {e}", path.display()))
    }

    fn run_systemctl(args: &[&str]) -> Result<(), String> {
        let output = std::process::Command::new("systemctl")
            .args(args)
            .output()
            .map_err(|e| format!("failed to run systemctl {args:?}: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "systemctl {args:?} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(())
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub fn install(
    label: &str,
    wrapper_content: &str,
    schedule: &Schedule,
    description: &str,
    hint: &str,
) -> Result<(), String> {
    match *schedule {
        Schedule::Daily { hour, minute } if hour > 23 || minute > 59 => {
            return Err(format!("invalid time {hour:02}:{minute:02}"));
        }
        Schedule::Interval { minutes: 0 } => {
            return Err("interval must be at least 1 minute".to_string());
        }
        _ => {}
    }
    platform::install(label, wrapper_content, schedule, description, hint)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub fn uninstall(label: &str, hint: &str) -> Result<(), String> {
    platform::uninstall(label, hint)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
pub fn status(label: &str, hint: &str) -> Option<Schedule> {
    platform::status(label, hint)
}

/// Whether this app already has macOS's Full Disk Access (TCC)
/// permission - lets the dashboard skip the "scheduled runs may need
/// Full Disk Access" warning when it's moot. There's no public API for
/// "am I TCC-approved"; the standard community technique (used by
/// several open-source TCC-aware tools) is to attempt to open TCC's
/// own database, which is itself one of the paths Full Disk Access
/// gates - readable only with that permission already granted, so a
/// successful open is a reliable yes/no signal without ever reading
/// its contents. Defaults to `false` (show the warning) on any error,
/// including the file genuinely not existing - a false "might need
/// it" is harmless, a false "you're fine" would hide a real gotcha.
#[cfg(target_os = "macos")]
fn file_is_readable(path: &str) -> bool {
    std::fs::File::open(path).is_ok()
}

#[cfg(target_os = "macos")]
pub fn has_full_disk_access() -> bool {
    let Ok(home) = std::env::var("HOME") else {
        return false;
    };
    file_is_readable(&format!("{home}/Library/Application Support/com.apple.TCC/TCC.db"))
}

#[cfg(not(target_os = "macos"))]
pub fn has_full_disk_access() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_deterministic_and_path_specific() {
        assert_eq!(slug("/Users/alex/Documents"), slug("/Users/alex/Documents"));
        assert_ne!(slug("/Users/alex/Documents"), slug("/Users/alex/Pictures"));
    }

    #[test]
    fn source_label_is_stable_and_namespaced() {
        let label = source_label("/Users/alex/Documents");
        assert!(label.starts_with("io.github.mariotti.bmug2.backup."));
        assert_eq!(label, source_label("/Users/alex/Documents"));
    }

    #[test]
    fn source_file_hint_takes_the_basename_and_sanitizes_it() {
        assert_eq!(source_file_hint("/Users/alex/My Documents"), "My_Documents");
        assert_eq!(source_file_hint("/Users/alex/kidsmesh.ch's site"), "kidsmesh_ch_s_site");
        assert_eq!(source_file_hint("/"), "");
    }

    #[test]
    fn source_file_hint_truncates_long_names() {
        let long_name = "a".repeat(100);
        let hint = source_file_hint(&format!("/Users/alex/{long_name}"));
        assert_eq!(hint.len(), 40);
    }

    #[test]
    fn file_stem_with_empty_hint_reproduces_the_bare_label() {
        // The critical backward-compat invariant: an empty hint must
        // produce byte-for-byte the same filename bmug2 always wrote
        // before this change, so an already-installed schedule's
        // files are still found under their original names.
        assert_eq!(file_stem("io.github.mariotti.bmug2.backup.abc123", ""), "io.github.mariotti.bmug2.backup.abc123");
    }

    #[test]
    fn file_stem_with_a_hint_appends_it() {
        assert_eq!(
            file_stem("io.github.mariotti.bmug2.backup.abc123", "Documents"),
            "io.github.mariotti.bmug2.backup.abc123-Documents"
        );
    }

    #[test]
    fn source_wrapper_calls_backmeup_sh_with_the_source_path() {
        let script = build_source_wrapper("/opt/bmu/bin", "/Users/alex/Documents");
        assert!(script.starts_with("#!/bin/sh\nset -e\n"));
        assert!(script.contains("\"/opt/bmu/bin/backmeup.sh\" \"/Users/alex/Documents\""));
    }

    #[test]
    fn housekeeping_wrapper_skips_replicate_when_not_configured() {
        let tmp = std::env::temp_dir().join(format!("bmug2-sched-hk-off-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("backmeup.setup.sh"), "BMU_REPLICATE_BACKEND=\"\"\n").unwrap();
        let script = build_housekeeping_wrapper(tmp.to_str().unwrap());
        assert!(script.contains("backmeup.updatedb.sh"));
        assert!(!script.contains("backmeup.replicate.sh"));
        assert!(!script.contains("backmeup.replicate.proton.sh"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn housekeeping_wrapper_includes_rclone_replicate_when_configured() {
        let tmp = std::env::temp_dir().join(format!("bmug2-sched-hk-rclone-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(
            tmp.join("backmeup.setup.sh"),
            "BMU_REPLICATE_BACKEND=\"rclone\"\nBMU_CMDREPLICATE=\"rclone sync\"\n",
        )
        .unwrap();
        let script = build_housekeeping_wrapper(tmp.to_str().unwrap());
        assert!(script.contains("backmeup.updatedb.sh"));
        assert!(script.contains("backmeup.replicate.sh"));
        assert!(!script.contains("backmeup.replicate.proton.sh"));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn housekeeping_wrapper_includes_proton_replicate_when_configured() {
        let tmp = std::env::temp_dir().join(format!("bmug2-sched-hk-proton-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("backmeup.setup.sh"), "BMU_REPLICATE_BACKEND=\"proton\"\n").unwrap();
        let script = build_housekeeping_wrapper(tmp.to_str().unwrap());
        assert!(script.contains("backmeup.updatedb.sh"));
        assert!(script.contains("backmeup.replicate.proton.sh"));
        assert!(!script.contains("backmeup.replicate.sh\""));
        std::fs::remove_dir_all(&tmp).ok();
    }

    #[test]
    fn plist_round_trips_daily() {
        let daily = Schedule::Daily { hour: 2, minute: 5 };
        let plist = build_plist("test.label", "/opt/bmu/wrapper.sh", &daily, "/tmp/test.log");
        assert!(plist.contains("StartCalendarInterval"));
        assert!(!plist.contains("StartInterval"));
        let parsed = parse_plist_schedule(&plist).expect("should parse");
        assert_eq!(parsed, daily);
    }

    #[test]
    fn plist_round_trips_interval() {
        let interval = Schedule::Interval { minutes: 30 };
        let plist = build_plist("test.label", "/opt/bmu/wrapper.sh", &interval, "/tmp/test.log");
        assert!(plist.contains("<key>StartInterval</key>\n    <integer>1800</integer>"));
        assert!(!plist.contains("StartCalendarInterval"));
        let parsed = parse_plist_schedule(&plist).expect("should parse");
        assert_eq!(parsed, interval);
    }

    #[test]
    fn timer_round_trips_daily() {
        let daily = Schedule::Daily { hour: 23, minute: 59 };
        let timer = build_timer("bmug2 backup", &daily);
        let parsed = parse_timer_schedule(&timer).expect("should parse");
        assert_eq!(parsed, daily);
    }

    #[test]
    fn timer_round_trips_interval() {
        let interval = Schedule::Interval { minutes: 5 };
        let timer = build_timer("bmug2 backup", &interval);
        assert!(timer.contains("OnCalendar=*:0/5"));
        let parsed = parse_timer_schedule(&timer).expect("should parse");
        assert_eq!(parsed, interval);
    }

    #[test]
    fn service_references_the_wrapper_and_explicit_path() {
        let service = build_service("bmug2 backup", "/opt/bmu/wrapper.sh");
        assert!(service.contains("ExecStart=/opt/bmu/wrapper.sh"));
        assert!(service.contains(PATH_ENV_LINUX));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn file_is_readable_true_for_a_real_file() {
        let path = std::env::temp_dir().join(format!("bmug2-fda-test-{}", std::process::id()));
        std::fs::write(&path, "x").unwrap();
        assert!(file_is_readable(path.to_str().unwrap()));
        std::fs::remove_file(&path).ok();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn file_is_readable_false_for_a_missing_file() {
        let path = std::env::temp_dir().join(format!("bmug2-fda-test-missing-{}", std::process::id()));
        assert!(!file_is_readable(path.to_str().unwrap()));
    }
}

/// Real install()/uninstall()/status() against actual launchd - not
/// run by default. `cargo test` in CI and any contributor's ordinary
/// local run never touches real launchctl state (confirmed:
/// .github/workflows/tests.yml never passes --include-ignored, same
/// precedent as install.rs's network-dependent ignored test) - only a
/// deliberate `cargo test -- --ignored` does. Unlike the sandboxed
/// backup test in run.rs, a real LaunchAgent is persistent OS state
/// until explicitly removed, so this shouldn't run on an ordinary dev
/// machine by accident.
#[cfg(all(test, target_os = "macos"))]
mod macos_real_tests {
    use super::*;

    struct Cleanup(String, String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = platform::uninstall(&self.0, &self.1);
        }
    }

    #[test]
    #[ignore]
    fn install_and_uninstall_a_real_daily_launchd_agent() {
        let label = format!("io.github.mariotti.bmug2.test.daily.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let daily = Schedule::Daily { hour: 3, minute: 30 };

        install(&label, "#!/bin/sh\nexit 0\n", &daily, "bmug2 schedule test", hint).expect("install should succeed");
        let found = status(&label, hint).expect("status should read back what was just installed");
        assert_eq!(found, daily);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "status should be gone after uninstall");
    }

    #[test]
    #[ignore]
    fn install_and_uninstall_a_real_interval_launchd_agent() {
        let label = format!("io.github.mariotti.bmug2.test.interval.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let interval = Schedule::Interval { minutes: 15 };

        install(&label, "#!/bin/sh\nexit 0\n", &interval, "bmug2 schedule test", hint).expect("install should succeed");
        let found = status(&label, hint).expect("status should read back what was just installed");
        assert_eq!(found, interval);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "status should be gone after uninstall");
    }

    /// Regression guard: a schedule installed before this change
    /// wrote its plist/wrapper under the bare (hint-less) label. This
    /// confirms status()/uninstall() still find and fully remove that
    /// old-style file when called with a non-empty hint, so upgrading
    /// the app never orphans a real, already-installed LaunchAgent.
    #[test]
    #[ignore]
    fn status_and_uninstall_find_an_old_style_hint_less_install() {
        let label = format!("io.github.mariotti.bmug2.test.oldstyle.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let daily = Schedule::Daily { hour: 4, minute: 0 };

        // Simulate a pre-fix install: write directly under the bare
        // label, bypassing install()'s hint-aware paths entirely.
        install(&label, "#!/bin/sh\nexit 0\n", &daily, "bmug2 schedule test", "").expect("install should succeed");

        let found = status(&label, hint).expect("status should fall back to the old-style file");
        assert_eq!(found, daily);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "old-style file should be gone after uninstall");
    }
}

/// Real install()/uninstall()/status() against actual systemd --user -
/// same reasoning and the same not-run-by-default guarantee as
/// macos_real_tests above. Needs a real user session/D-Bus session bus
/// for `systemctl --user` to work at all (not available on a minimal
/// container without `loginctl enable-linger` or an active login) -
/// unlike the macOS launchd equivalent, a bare CI runner typically
/// can't run this even with --ignored; it's meant for a real desktop
/// Linux machine.
#[cfg(all(test, target_os = "linux"))]
mod linux_real_tests {
    use super::*;

    struct Cleanup(String, String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = platform::uninstall(&self.0, &self.1);
        }
    }

    #[test]
    #[ignore]
    fn install_and_uninstall_a_real_daily_systemd_timer() {
        let label = format!("io.github.mariotti.bmug2.test.daily.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let daily = Schedule::Daily { hour: 3, minute: 30 };

        install(&label, "#!/bin/sh\nexit 0\n", &daily, "bmug2 schedule test", hint).expect("install should succeed");
        let found = status(&label, hint).expect("status should read back what was just installed");
        assert_eq!(found, daily);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "status should be gone after uninstall");
    }

    #[test]
    #[ignore]
    fn install_and_uninstall_a_real_interval_systemd_timer() {
        let label = format!("io.github.mariotti.bmug2.test.interval.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let interval = Schedule::Interval { minutes: 15 };

        install(&label, "#!/bin/sh\nexit 0\n", &interval, "bmug2 schedule test", hint).expect("install should succeed");
        let found = status(&label, hint).expect("status should read back what was just installed");
        assert_eq!(found, interval);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "status should be gone after uninstall");
    }

    /// Regression guard: a schedule installed before this change
    /// wrote its unit files under the bare (hint-less) label. This
    /// confirms status()/uninstall() still find and fully remove that
    /// old-style file when called with a non-empty hint, so upgrading
    /// the app never orphans a real, already-installed systemd timer.
    #[test]
    #[ignore]
    fn status_and_uninstall_find_an_old_style_hint_less_install() {
        let label = format!("io.github.mariotti.bmug2.test.oldstyle.{}", std::process::id());
        let hint = "readable-name";
        let _cleanup = Cleanup(label.clone(), hint.to_string());
        let daily = Schedule::Daily { hour: 4, minute: 0 };

        // Simulate a pre-fix install: write directly under the bare
        // label, bypassing install()'s hint-aware paths entirely.
        install(&label, "#!/bin/sh\nexit 0\n", &daily, "bmug2 schedule test", "").expect("install should succeed");

        let found = status(&label, hint).expect("status should fall back to the old-style file");
        assert_eq!(found, daily);

        uninstall(&label, hint).expect("uninstall should succeed");
        assert!(status(&label, hint).is_none(), "old-style file should be gone after uninstall");
    }
}
