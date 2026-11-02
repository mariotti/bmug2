#! /bin/sh
#
# Report the status of the most recent (or currently-running)
# backmeup.replicate.sh invocation. Read-only - never mutates
# anything, safe to call concurrently with an in-flight
# replicate run.
#
#   usage: backmeup.replicate.status.sh [-j|--json]
#
# Three signals derived from the status log backmeup.replicate.sh
# writes to ${BMU_DIRBACKUPS}/.bmureplicate.log (truncated per
# run), plus two external observations:
#   1. rsync-phase progress  - parsed from --info=progress2 lines
#   2. destination-size      - du -sh on the configured target
#   3. upload-queue (macOS)  - fileproviderctl dump for the
#                              configured provider; local backend
#                              only, nothing for rclone/proton
#
# When no run has ever happened (log missing), prints "not run yet"
# and exits 0 (same shape every other backmeup.* tool uses for
# "nothing to do"). When a prior run completed, parses the final
# stats block.
#
# Detect command path
# -------------------
MY_PATH="`dirname \"$0\"`"
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"
if [ -z "$MY_PATH" ] ; then
  exit 1
fi
BMU_PATH=${MY_PATH}
#
# SETUP
. "${BMU_PATH}/backmeup.shellfunctions.sh"
. "${BMU_PATH}/backmeup.setup.sh"
#
l_BMU_JSON=""
if [ "$1" = "-j" ] || [ "$1" = "--json" ]; then
    l_BMU_JSON="yes"
fi
#
l_BMU_LOG="${BMU_DIRBACKUPS}/.bmureplicate.log"
if [ ! -f "${l_BMU_LOG}" ]; then
    if [ -n "${l_BMU_JSON}" ]; then
        echo '{"state":"not_run_yet","log":"'"${l_BMU_LOG}"'"}'
    else
        echo "backmeup.replicate.sh has not been run on this install yet."
        echo "  Expected log at: ${l_BMU_LOG}"
    fi
    exit 0
fi
#
# rsync --info=progress2 writes carriage-return-separated updates;
# each in-place-updating line is a "chunk" delimited by \r. The
# newest chunk is at the end of the file.
# Pick the last line that LOOKS like a progress line (bytes +
# percent + rate + ETA). Example rsync format:
#   "         12,345,678  52%   15.23MB/s    0:14:12"
# Also pick up stats2 summary lines if present:
#   "Total transferred file size: 47,428,304,791 bytes"
l_BMU_LATEST_PROGRESS=`tr '\r' '\n' < "${l_BMU_LOG}" 2>/dev/null \
    | awk '/^ *[0-9,]+ +[0-9]+% +[0-9]/' \
    | tail -1 \
    | tr -s ' '`
l_BMU_FINAL_STATS=`grep "^Total transferred file size" "${l_BMU_LOG}" 2>/dev/null | tail -1`
l_BMU_ERROR=`grep "^ERROR:" "${l_BMU_LOG}" 2>/dev/null | tail -1`
l_BMU_COMPLETE=`grep -E "^Replication complete\.$|^DRY RUN complete" "${l_BMU_LOG}" 2>/dev/null | tail -1`
#
# Derive state. Order matters: ERROR > complete > in-progress >
# unknown.
if [ -n "${l_BMU_ERROR}" ]; then
    l_BMU_STATE="error"
elif [ -n "${l_BMU_COMPLETE}" ]; then
    l_BMU_STATE="complete"
elif [ -n "${l_BMU_LATEST_PROGRESS}" ]; then
    l_BMU_STATE="in_progress"
else
    l_BMU_STATE="started"
fi
#
# Destination size (what rsync has staged into the local cache /
# written to the target so far). Works for every backend, since
# BMU_REPLICATE_REMOTE_SYNC is a filesystem path for the local
# backend and a remote URI for rclone/proton - du -sh prints
# nothing for the latter and that's fine, we just omit it.
l_BMU_DST_SIZE=""
if [ -n "${BMU_REPLICATE_REMOTE_SYNC}" ] && [ -d "${BMU_REPLICATE_REMOTE_SYNC}" ]; then
    l_BMU_DST_SIZE=`du -sh "${BMU_REPLICATE_REMOTE_SYNC}" 2>/dev/null | awk '{print $1}'`
fi
#
# Upload queue (macOS + local backend only). Opt-in on uname:
# fileproviderctl is Darwin-only, the provider name is
# backend-specific. Guard with capability check instead of
# hardcoded "darwin": if the tool exists and the provider
# resolves, we have a reading - everywhere else, print nothing.
l_BMU_UPLOAD_QUEUE=""
if [ "${BMU_REPLICATE_BACKEND}" = "local" ] && command -v fileproviderctl >/dev/null 2>&1; then
    # Try common provider identifiers for the CloudStorage providers
    # bmug2 docs mention; silent miss is fine (just omit the field).
    for l_provider in ch.protonmail.drive.fileprovider com.dropbox.DropboxMacUpdate.fileprovider com.google.drivefs.fileprovider; do
        l_rec=`fileproviderctl dump "${l_provider}" 2>/dev/null | grep -m1 'p:root n:"b{3}2/"'`
        if [ -n "${l_rec}" ]; then
            l_nev=`echo "${l_rec}" | sed -nE 's/.*nev:([0-9]+).*/\1/p'`
            l_ev=`echo "${l_rec}" | sed -nE 's/.*ev:([0-9]+)[^0-9].*/\1/p'`
            if [ -n "${l_nev}" ] && [ -n "${l_ev}" ]; then
                l_BMU_UPLOAD_QUEUE="${l_nev} of `expr ${l_nev} + ${l_ev}` pending (${l_provider})"
                break
            fi
        fi
    done
fi
#
# Output
if [ -n "${l_BMU_JSON}" ]; then
    # Minimal JSON - just enough for the GUI / another script to
    # consume. Fields missing in text form appear as "" here (not
    # null) so the schema is stable regardless of state.
    printf '{"state":"%s","progress":"%s","dst_size":"%s","upload_queue":"%s","final_stats":"%s","error":"%s","log":"%s"}\n' \
        "${l_BMU_STATE}" \
        "`bmuJsonEscape \"${l_BMU_LATEST_PROGRESS}\"`" \
        "${l_BMU_DST_SIZE}" \
        "`bmuJsonEscape \"${l_BMU_UPLOAD_QUEUE}\"`" \
        "`bmuJsonEscape \"${l_BMU_FINAL_STATS}\"`" \
        "`bmuJsonEscape \"${l_BMU_ERROR}\"`" \
        "${l_BMU_LOG}"
else
    case "${l_BMU_STATE}" in
        error)       echo "state: ERROR -- ${l_BMU_ERROR}" ;;
        complete)    echo "state: complete -- ${l_BMU_COMPLETE}" ;;
        in_progress) echo "state: in progress -- ${l_BMU_LATEST_PROGRESS}" ;;
        started)     echo "state: started (no progress yet)" ;;
    esac
    if [ -n "${l_BMU_FINAL_STATS}" ]; then
        echo "stats:   ${l_BMU_FINAL_STATS}"
    fi
    if [ -n "${l_BMU_DST_SIZE}" ]; then
        echo "dst:     ${l_BMU_DST_SIZE}  (${BMU_REPLICATE_REMOTE_SYNC})"
    fi
    if [ -n "${l_BMU_UPLOAD_QUEUE}" ]; then
        echo "upload:  ${l_BMU_UPLOAD_QUEUE}"
    fi
    echo "log:     ${l_BMU_LOG}"
fi
exit 0
