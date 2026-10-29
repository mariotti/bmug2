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
l_BMU_OPT=""
if [ -n "${l_BMU_DRYRUN}" ]; then
    l_BMU_OPT="--dry-run"
    echo "DRY RUN: nothing will actually be copied."
fi;
#
# rclone-specific progress flags not valid for rsync; trailing-slash
# source on rsync mirrors contents rather than nesting the directory name.
if [ "${BMU_REPLICATE_BACKEND}" = "rclone" ]; then
    l_BMU_REPLICATE_FLAGS="-v --stats=10s --stats-one-line --fast-list"
    l_BMU_SYNC_SRC="${BMU_DIRRSYNC}"
    l_BMU_BKUP_SRC="${BMU_DIRBACKUPS}"
else
    l_BMU_REPLICATE_FLAGS="-v"
    l_BMU_SYNC_SRC="${BMU_DIRRSYNC}/"
    l_BMU_BKUP_SRC="${BMU_DIRBACKUPS}/"
fi

echo "Replicating SYNC (${BMU_DIRRSYNC}) -> ${BMU_REPLICATE_REMOTE_SYNC}"
${BMU_CMDREPLICATE} ${l_BMU_REPLICATE_FLAGS} ${l_BMU_OPT} "${l_BMU_SYNC_SRC}" "${BMU_REPLICATE_REMOTE_SYNC}"
l_BMU_RC1=$?
#
echo "Replicating BackUp (${BMU_DIRBACKUPS}) -> ${BMU_REPLICATE_REMOTE_BACKUPS}"
${BMU_CMDREPLICATE} ${l_BMU_REPLICATE_FLAGS} ${l_BMU_OPT} "${l_BMU_BKUP_SRC}" "${BMU_REPLICATE_REMOTE_BACKUPS}"
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
