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
l_BMU_OPT=""
if [ -n "${l_BMU_DRYRUN}" ]; then
    l_BMU_OPT="--dry-run"
    echo "DRY RUN: nothing will actually be copied."
fi;
#
echo "Replicating SYNC (${BMU_DIRRSYNC}) -> ${BMU_REPLICATE_REMOTE_SYNC}"
${BMU_CMDREPLICATE} ${l_BMU_OPT} "${BMU_DIRRSYNC}" "${BMU_REPLICATE_REMOTE_SYNC}"
l_BMU_RC1=$?
#
echo "Replicating BackUp (${BMU_DIRBACKUPS}) -> ${BMU_REPLICATE_REMOTE_BACKUPS}"
${BMU_CMDREPLICATE} ${l_BMU_OPT} "${BMU_DIRBACKUPS}" "${BMU_REPLICATE_REMOTE_BACKUPS}"
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
