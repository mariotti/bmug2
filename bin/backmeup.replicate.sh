#! /bin/sh
#
# Replicate the local SYNC and BackUp/HISTORY trees to an off-site
# destination (an rclone remote, or a plain local path such as a
# cloud-sync desktop folder), on top of the local versioning
# backmeup.sh already provides. See docs/DESTINATIONS.md for why this
# is a separate step layered on top of SYNC/HISTORY, not a replacement
# for keeping them on fast, local storage.
#
#   usage: backmeup.replicate.sh [-n|--dry-run]
#
# Not configured by default - run backmeup.configure.sh to set it up.
#
# Detect command path
# -------------------
# From: http://stackoverflow.com/questions/630372/determine-the-path-of-the-executing-bash-script
# My version was a bit more "rude" ;)
#
MY_PATH="`dirname \"$0\"`"              # relative
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"  # absolutized and normalized
if [ -z "$MY_PATH" ] ; then
  # error; for some reason, the path is not accessible
  # to the script (e.g. permissions re-evaled after suid)
  exit 1  # fail
fi
BMU_PATH=${MY_PATH}
#
# SETUP
. "${BMU_PATH}/backmeup.shellfunctions.sh"
. "${BMU_PATH}/backmeup.setup.sh"
#
# pipefail: enable if the shell supports it. The | tee of rsync's
# output into the status log below would otherwise mask rsync's
# non-zero exit code behind tee's always-zero exit; pipefail makes
# the pipeline exit non-zero when any component is. Capability
# gated via a subshell probe (matches the project's bmuDetect*
# pattern - never uname-based). Supported on dash >= 0.5.11,
# every modern bash/zsh, macOS /bin/sh (bash in POSIX mode) -
# effectively universal on anything bmug2 ships to. If an ancient
# shell silently skips it, rsync's own ERROR output still appears
# in the log; only the exit code might be rc=0 when it should be
# non-zero. Not catastrophic, worth being honest about.
if ( set -o pipefail ) 2>/dev/null; then
    set -o pipefail
fi
#
# Parsing options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="yes"
    shift
fi;
#
if [ -z "${BMU_CMDREPLICATE}" ] || [ -z "${BMU_REPLICATE_REMOTE_SYNC}" ] \
   || [ -z "${BMU_REPLICATE_REMOTE_BACKUPS}" ]; then
    echo "ERROR: replication is not configured."
    echo "  Re-run backmeup.configure.sh to set it up, or see docs/DESTINATIONS.md."
    exit 1
fi;
#
# Guard against replicating from an unmounted source. If BMU_DIRRSYNC
# or BMU_DIRBACKUPS is on a disk that isn't currently mounted, the
# mountpoint is an empty directory - and both backends run with
# --delete (rsync) or sync-semantics (rclone), which would propagate
# that emptiness and wipe the replica. backmeup.sh has the same
# protection; replicate.sh now mirrors it. Two layered checks:
#   1. If *_MOUNT is set (configured after the backmeup.sh mount
#      check landed), verify the current mountpoint still matches.
#   2. Always verify .bmumeta exists in the source dir - bmug2's
#      install step creates it and nothing removes it; an unmounted
#      mountpoint never has it. This also protects older installs
#      with empty *_MOUNT variables.
# OPEN_ISSUES #3: an install with either *_MOUNT still empty gets
# only the .bmumeta half of the guard - the stronger mount-point
# match is silently off. Tell the user, don't change exit code.
if [ -z "${BMU_DIRRSYNC_MOUNT}" ] || [ -z "${BMU_DIRBACKUPS_MOUNT}" ]; then
    l_bmu_missing_mount=""
    if [ -z "${BMU_DIRRSYNC_MOUNT}" ]; then
        l_bmu_missing_mount="BMU_DIRRSYNC_MOUNT"
    fi
    if [ -z "${BMU_DIRBACKUPS_MOUNT}" ]; then
        l_bmu_missing_mount="${l_bmu_missing_mount}${l_bmu_missing_mount:+, }BMU_DIRBACKUPS_MOUNT"
    fi
    echo "WARNING: source mount check is disabled (empty: ${l_bmu_missing_mount})."
    echo "  Re-run backmeup.configure.sh to populate these and enable it."
fi
if [ -n "${BMU_DIRRSYNC_MOUNT}" ]; then
    l_bmu_live_mount=`bmuMountPoint "${BMU_DIRRSYNC}"`
    if [ "${l_bmu_live_mount}" != "${BMU_DIRRSYNC_MOUNT}" ]; then
        echo "ERROR: SYNC directory ${BMU_DIRRSYNC} is not on its configured"
        echo "filesystem (expected mount: ${BMU_DIRRSYNC_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
        echo "  Refusing to replicate - rsync --delete / rclone sync would wipe the replica."
        exit 1
    fi
fi
if [ ! -f "${BMU_DIRRSYNC}/.bmumeta" ]; then
    echo "ERROR: SYNC directory ${BMU_DIRRSYNC} is missing its .bmumeta marker."
    echo "  Usually this means the backup disk isn't mounted (its mountpoint is empty)."
    echo "  Refusing to replicate - rsync --delete / rclone sync would wipe the replica."
    exit 1
fi
if [ -n "${BMU_DIRBACKUPS_MOUNT}" ]; then
    l_bmu_live_mount=`bmuMountPoint "${BMU_DIRBACKUPS}"`
    if [ "${l_bmu_live_mount}" != "${BMU_DIRBACKUPS_MOUNT}" ]; then
        echo "ERROR: BackUp directory ${BMU_DIRBACKUPS} is not on its configured"
        echo "filesystem (expected mount: ${BMU_DIRBACKUPS_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
        echo "  Refusing to replicate - rsync --delete / rclone sync would wipe the replica."
        exit 1
    fi
fi
if [ ! -f "${BMU_DIRBACKUPS}/.bmumeta" ]; then
    echo "ERROR: BackUp directory ${BMU_DIRBACKUPS} is missing its .bmumeta marker."
    echo "  Usually this means the backup disk isn't mounted (its mountpoint is empty)."
    echo "  Refusing to replicate - rsync --delete / rclone sync would wipe the replica."
    exit 1
fi
#
# Symmetric target-side mount check for the local backend only. The
# rclone and proton backends talk to a remote protocol, not a mounted
# filesystem, so bmuMountPoint doesn't apply there - BMU_REPLICATE_
# REMOTE_SYNC_MOUNT / _BACKUPS_MOUNT stay empty for those backends and
# this block is a no-op. For the local backend the destination is a
# plain path (typically an external drive or cloud-sync folder); if
# that drive is not mounted right now, rsync --delete would write
# the mirror onto the system disk at the mountpoint path - the exact
# "silently fills the system disk" scenario the source-side check
# above protects against. Empty *_MOUNT also means skip (installs
# predating this capture): same behavior as the source side.
if [ "${BMU_REPLICATE_BACKEND}" = "local" ]; then
    # OPEN_ISSUES #3 (symmetric): an install predating #181 has
    # these two empty - the local-backend target mount check is
    # silently off. Tell the user, don't change exit code.
    if [ -z "${BMU_REPLICATE_REMOTE_SYNC_MOUNT}" ] || [ -z "${BMU_REPLICATE_REMOTE_BACKUPS_MOUNT}" ]; then
        l_bmu_missing_mount=""
        if [ -z "${BMU_REPLICATE_REMOTE_SYNC_MOUNT}" ]; then
            l_bmu_missing_mount="BMU_REPLICATE_REMOTE_SYNC_MOUNT"
        fi
        if [ -z "${BMU_REPLICATE_REMOTE_BACKUPS_MOUNT}" ]; then
            l_bmu_missing_mount="${l_bmu_missing_mount}${l_bmu_missing_mount:+, }BMU_REPLICATE_REMOTE_BACKUPS_MOUNT"
        fi
        echo "WARNING: local-backend target mount check is disabled (empty: ${l_bmu_missing_mount})."
        echo "  Re-run backmeup.configure.sh to populate these and enable it."
    fi
    if [ -n "${BMU_REPLICATE_REMOTE_SYNC_MOUNT}" ]; then
        l_bmu_live_mount=`bmuMountPoint "${BMU_REPLICATE_REMOTE_SYNC}"`
        if [ "${l_bmu_live_mount}" != "${BMU_REPLICATE_REMOTE_SYNC_MOUNT}" ]; then
            echo "ERROR: SYNC replication target ${BMU_REPLICATE_REMOTE_SYNC} is not on its"
            echo "configured filesystem (expected mount: ${BMU_REPLICATE_REMOTE_SYNC_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
            echo "  Refusing to replicate - rsync --delete would write to the system disk instead."
            exit 1
        fi
    fi
    if [ -n "${BMU_REPLICATE_REMOTE_BACKUPS_MOUNT}" ]; then
        l_bmu_live_mount=`bmuMountPoint "${BMU_REPLICATE_REMOTE_BACKUPS}"`
        if [ "${l_bmu_live_mount}" != "${BMU_REPLICATE_REMOTE_BACKUPS_MOUNT}" ]; then
            echo "ERROR: BackUp replication target ${BMU_REPLICATE_REMOTE_BACKUPS} is not on its"
            echo "configured filesystem (expected mount: ${BMU_REPLICATE_REMOTE_BACKUPS_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
            echo "  Refusing to replicate - rsync --delete would write to the system disk instead."
            exit 1
        fi
    fi
fi
#
l_BMU_OPT=""
if [ -n "${l_BMU_DRYRUN}" ]; then
    l_BMU_OPT="--dry-run"
    echo "DRY RUN: nothing will actually be copied."
fi;
#
# Status log: predictable path inside BackUp (already protected and
# mount-checked above), truncated per run so backmeup.replicate.
# status.sh always reads the current invocation only - no unbounded
# history, no stale-run confusion. The log is a plain tee of this
# script's own stdout+stderr; status.sh parses rsync's own
# --info=progress2 output + the --info=stats2 end-of-leg block.
# Named with a leading dot so it never shows up in a locate index
# or a casual ls of the BackUp dir.
l_BMU_STATUS_LOG="${BMU_DIRBACKUPS}/.bmureplicate.log"
: > "${l_BMU_STATUS_LOG}"
#
# .DS_Store is pure macOS Finder noise - zero backup value, present
# in nearly every directory a Mac user has ever opened in Finder,
# and causes needless upload churn on cross-platform cloud targets.
# Toggled off via BMU_REPLICATE_EXCLUDE_DS_STORE="" if a user really
# wants it mirrored (unusual - documented in docs/MANUAL.md).
# .locate.dir is NOT excluded: a disaster-recovery restore gets
# instant search instead of having to rebuild updatedb first.
l_BMU_EXCLUDE_FLAGS=""
if [ -z "${BMU_REPLICATE_EXCLUDE_DS_STORE+set}" ] || [ -n "${BMU_REPLICATE_EXCLUDE_DS_STORE}" ]; then
    l_BMU_EXCLUDE_FLAGS="--exclude=.DS_Store"
fi
#
# Per-source off-site replication class: a plain-text
# `${BMU_DIRBACKUPS}/<project>/.bmureplicate-class` sidecar (written
# by the GUI, see replication::set_source_class in Rust) carries
# either "default" (replicate normally) or "none" (skip entirely).
# For every "none" project found, add --exclude=/<project>/ and
# --exclude=/<project>/** so neither leg (SYNC or BackUp) carries
# that source's content off-site. The use case: a large-media
# source (videos, raw photo archives) kept in local SYNC + HISTORY
# but kept out of Proton Drive / rclone bandwidth - a 44 GB cello-
# video subtree would otherwise be pushed every HouseKeeping run.
#
# Honest caveat: if a source was PREVIOUSLY replicated and later
# gets marked "none", the --exclude only skips future transfers.
# rsync --delete acts on the OTHER files it's syncing, not on the
# excluded ones - so the existing copy at the remote is NOT purged.
# Clean-up is a manual remote-side delete for now (documented in
# docs/MANUAL.md); a follow-up --purge-excluded flag could automate
# it but the safe default is "never delete anything the user didn't
# explicitly opt into deleting".
for l_bmu_class_sidecar in "${BMU_DIRBACKUPS}"/*/.bmureplicate-class; do
    case "${l_bmu_class_sidecar}" in
        *'*') continue ;;  # unmatched glob when no sidecars exist yet
    esac
    [ -f "${l_bmu_class_sidecar}" ] || continue
    l_bmu_class_val=`head -1 "${l_bmu_class_sidecar}" 2>/dev/null | tr -d '[:space:]'`
    if [ "${l_bmu_class_val}" = "none" ]; then
        # The project name is the parent-dir basename of the sidecar.
        l_bmu_proj_dir=`dirname "${l_bmu_class_sidecar}"`
        l_bmu_proj_name=`basename "${l_bmu_proj_dir}"`
        l_BMU_EXCLUDE_FLAGS="${l_BMU_EXCLUDE_FLAGS} --exclude=/${l_bmu_proj_name}/ --exclude=/${l_bmu_proj_name}/**"
        echo "Skipping /${l_bmu_proj_name}/ (per-source replicate-class=none)"
    fi
done
#
# Per-backend flag dispatch. Named `case` instead of a two-arm
# if/else so a BMU_REPLICATE_BACKEND="" legacy install (which still
# exists in the wild - BMU_REPLICATE_BACKEND was added later than
# BMU_CMDREPLICATE) falls into the generic * branch rather than
# the local branch's rsync-specific --info= flags. The rclone CLI
# would reject --info=progress2,stats2 as "unknown flag" and exit
# non-zero, breaking any older rclone caller that only set
# BMU_CMDREPLICATE.
#
# --info=progress2,stats2 (rsync local backend only): progress2 is
# a single in-place-updating line (bytes transferred, %, rate,
# ETA), stats2 is the end-of-leg summary block - both near-zero
# cost on small deltas, big UX win on first-time or large pushes
# (verified live on a 44 GB stress test; see docs/MANUAL.md).
#
# rclone's own --stats=10s --stats-one-line --fast-list keeps the
# rclone branch's existing periodic-stats UX. Trailing-slash source
# on rsync mirrors contents rather than nesting the directory name;
# rclone wants the bare source.
case "${BMU_REPLICATE_BACKEND}" in
    rclone)
        l_BMU_REPLICATE_FLAGS="-v --stats=10s --stats-one-line --fast-list ${l_BMU_EXCLUDE_FLAGS}"
        l_BMU_SYNC_SRC="${BMU_DIRRSYNC}"
        l_BMU_BKUP_SRC="${BMU_DIRBACKUPS}"
        ;;
    local)
        l_BMU_REPLICATE_FLAGS="-v --info=progress2,stats2 ${l_BMU_EXCLUDE_FLAGS}"
        l_BMU_SYNC_SRC="${BMU_DIRRSYNC}/"
        l_BMU_BKUP_SRC="${BMU_DIRBACKUPS}/"
        ;;
    *)
        # legacy install (BMU_REPLICATE_BACKEND empty) - keep the
        # pre-#192 flag set so an older rclone caller still works.
        l_BMU_REPLICATE_FLAGS="-v ${l_BMU_EXCLUDE_FLAGS}"
        l_BMU_SYNC_SRC="${BMU_DIRRSYNC}/"
        l_BMU_BKUP_SRC="${BMU_DIRBACKUPS}/"
        ;;
esac

echo "Replicating SYNC (${BMU_DIRRSYNC}) -> ${BMU_REPLICATE_REMOTE_SYNC}" | tee -a "${l_BMU_STATUS_LOG}"
${BMU_CMDREPLICATE} ${l_BMU_REPLICATE_FLAGS} ${l_BMU_OPT} "${l_BMU_SYNC_SRC}" "${BMU_REPLICATE_REMOTE_SYNC}" 2>&1 | tee -a "${l_BMU_STATUS_LOG}"
l_BMU_RC1=$?
#
echo "Replicating BackUp (${BMU_DIRBACKUPS}) -> ${BMU_REPLICATE_REMOTE_BACKUPS}" | tee -a "${l_BMU_STATUS_LOG}"
${BMU_CMDREPLICATE} ${l_BMU_REPLICATE_FLAGS} ${l_BMU_OPT} "${l_BMU_BKUP_SRC}" "${BMU_REPLICATE_REMOTE_BACKUPS}" 2>&1 | tee -a "${l_BMU_STATUS_LOG}"
l_BMU_RC2=$?
#
if [ ${l_BMU_RC1} -ne 0 ] || [ ${l_BMU_RC2} -ne 0 ]; then
    echo "ERROR: replication failed (SYNC rc=${l_BMU_RC1}, BackUp rc=${l_BMU_RC2})."
    exit 1
fi;
if [ -n "${l_BMU_DRYRUN}" ]; then
    echo "DRY RUN complete, nothing was changed."
else
    echo "Replication complete."
fi;
