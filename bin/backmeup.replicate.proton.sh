#! /bin/sh
#
# Replicate HISTORY (only - not SYNC) to Proton Drive via the native
# proton-drive CLI, on top of the local versioning backmeup.sh already
# provides. See docs/DESTINATIONS.md for how this differs from
# backmeup.replicate.sh (which also covers SYNC, via rclone).
#
#   usage: backmeup.replicate.proton.sh [-n|--dry-run]
#
# Not configured by default - run backmeup.configure.sh to set it up.
# Each B-<date> snapshot (live directory, or already archived into a
# .tar.gz) is uploaded at most once; successful uploads are recorded
# per project in HISTORY/<project>/.bmureplicated.proton, so a re-run
# is a no-op. A failed upload is never recorded, so it is retried on
# the next run.
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
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# Parsing options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="yes"
    shift
fi;
#
if [ -z "${BMU_REPLICATE_PROTON_BIN}" ] || [ -z "${BMU_REPLICATE_PROTON_REMOTE}" ]; then
    echo "ERROR: Proton Drive replication is not configured."
    echo "  Re-run backmeup.configure.sh to set it up, or see docs/DESTINATIONS.md."
    if [ "${BMU_REPLICATE_BACKEND}" = "rclone" ]; then
        echo "  NOTE: this install is configured for the 'rclone' backend -"
        echo "  run backmeup.replicate.sh instead."
    fi;
    exit 1
fi;
#
# Whole-run lock: unlike backmeup.sh's per-project lock, this script
# walks every project in one pass and writes a shared state file per
# project - two overlapping runs could otherwise interleave writes to
# the same .bmureplicated.proton file.
l_BMU_LOCKDIR="${BMU_DIRBACKUPS}/.bmureplicate-proton.lock"
if ! bmuAcquireLock "${l_BMU_LOCKDIR}"; then
    echo "ERROR: another backmeup.replicate.proton.sh run is already in progress."
    exit 1
fi;
trap 'bmuReleaseLock "${l_BMU_LOCKDIR}"' EXIT
#
# bmuProtonEnsureFolder <remote-path>
# "mkdir -p" for a remote Proton Drive path. "filesystem info" cleanly
# distinguishes exists (exit 0) from missing ("Node not found", exit
# 1); "filesystem create-folder" on an already-existing name FAILS
# (exit 1, "A file or folder with that name already exists") - verified
# against the real CLI (v0.8.0), so create-folder is only ever called
# after info has confirmed the path is missing, and the result is
# re-verified via info rather than trusted from create-folder's own
# exit code either way (tolerates a concurrent-create race).
bmuProtonEnsureFolder() {
    l_bpef_path="$1"
    "${BMU_REPLICATE_PROTON_BIN}" filesystem info "${l_bpef_path}" >/dev/null 2>&1 && return 0
    l_bpef_parent=`dirname "${l_bpef_path}"`
    l_bpef_name=`basename "${l_bpef_path}"`
    case "${l_bpef_parent}" in
        "/"|".") ;;
        *) bmuProtonEnsureFolder "${l_bpef_parent}" || return 1 ;;
    esac
    "${BMU_REPLICATE_PROTON_BIN}" filesystem create-folder "${l_bpef_parent}" "${l_bpef_name}" >/dev/null 2>&1
    "${BMU_REPLICATE_PROTON_BIN}" filesystem info "${l_bpef_path}" >/dev/null 2>&1
}
#
# bmuProtonUploadOne <local-file> <remote-parent-dir>
# Uploads exactly one local file, with explicit conflict strategies on
# every call (never rely on the no-flag interactive/EOF-default
# behavior, which silently skips and still exits 0 - verified against
# the real CLI). "skip" can never corrupt an existing remote object,
# and makes a retry after a crash between "upload succeeded" and
# "state file written" safe, since identical-content re-upload
# auto-skips. Returns 0 only when the JSON response confirms real
# success (no failed items, and something was actually transferred or
# already-present) - exit code alone is not enough signal, since a
# silent skip also exits 0.
bmuProtonUploadOne() {
    l_bpu_local="$1"
    l_bpu_remoteparent="$2"
    l_bpu_json=`"${BMU_REPLICATE_PROTON_BIN}" filesystem upload -j -f skip -d skip -t \
        "${l_bpu_local}" "${l_bpu_remoteparent}" 2>&1`
    l_bpu_rc=$?
    if [ ${l_bpu_rc} -ne 0 ]; then
        echo "ERROR: upload failed (exit ${l_bpu_rc}): ${l_bpu_json}"
        return 1
    fi;
    l_bpu_failed=`bmuProtonJsonField "${l_bpu_json}" "failedItems"`
    l_bpu_xfer=`bmuProtonJsonField "${l_bpu_json}" "transferredItems"`
    l_bpu_skip=`bmuProtonJsonField "${l_bpu_json}" "skippedItems"`
    if [ -z "${l_bpu_failed}" ] || [ "${l_bpu_failed}" -ne 0 ]; then
        echo "ERROR: upload reported failure: ${l_bpu_json}"
        return 1
    fi;
    if [ "${l_bpu_xfer:-0}" -eq 0 ] && [ "${l_bpu_skip:-0}" -eq 0 ]; then
        echo "ERROR: upload did not confirm transfer or skip: ${l_bpu_json}"
        return 1
    fi;
    return 0
}
#
l_BMU_STAGING_PARENT="${BMU_DIRBACKUPS}/.proton-staging"
l_BMU_REPLICATED=0
l_BMU_SKIPPED=0
l_BMU_FAILED=0
#
for l_prjdir in "${BMU_DIRBACKUPS}"/*/; do
    [ -d "${l_prjdir}" ] || continue
    l_prj=`basename "${l_prjdir}"`
    l_bp="${BMU_DIRBACKUPS}/${l_prj}"
    l_state="${l_bp}/.bmureplicated.proton"
    l_remote_prj="${BMU_REPLICATE_PROTON_REMOTE}/history/${l_prj}"
    l_remote_ensured=""
    #
    for l_entry in "${l_bp}"/B-*; do
        [ -e "${l_entry}" ] || continue
        l_name=`basename "${l_entry}"`
        case "${l_name}" in
            *.filelist) continue ;;   # not a snapshot - see backmeup.archive.sh
        esac
        case "${l_name}" in
            *.tar.gz) l_snapkey="${l_name%.tar.gz}" ;;
            *)        l_snapkey="${l_name}" ;;
        esac
        #
        if [ -f "${l_state}" ] && grep -qxF "${l_snapkey}" "${l_state}" 2>/dev/null; then
            l_BMU_SKIPPED=`expr ${l_BMU_SKIPPED} + 1`
            continue
        fi;
        #
        if [ -n "${l_BMU_DRYRUN}" ]; then
            echo "would replicate ${l_prj}/${l_snapkey} -> ${l_remote_prj}"
            l_BMU_REPLICATED=`expr ${l_BMU_REPLICATED} + 1`
            continue
        fi;
        #
        if [ -z "${l_remote_ensured}" ]; then
            if ! bmuProtonEnsureFolder "${l_remote_prj}"; then
                echo "ERROR: cannot create/verify remote folder ${l_remote_prj}, skipping ${l_prj}."
                l_BMU_FAILED=`expr ${l_BMU_FAILED} + 1`
                break
            fi;
            l_remote_ensured="yes"
        fi;
        #
        if [ -f "${l_entry}" ]; then
            # already-archived .tar.gz - upload as-is
            if bmuProtonUploadOne "${l_entry}" "${l_remote_prj}"; then
                printf '%s\n' "${l_snapkey}" >> "${l_state}"
                echo "replicated ${l_prj}/${l_snapkey}"
                l_BMU_REPLICATED=`expr ${l_BMU_REPLICATED} + 1`
            else
                echo "ERROR: ${l_prj}/${l_snapkey} not marked replicated (see above)."
                l_BMU_FAILED=`expr ${l_BMU_FAILED} + 1`
            fi;
        elif [ -d "${l_entry}" ]; then
            # live snapshot - tar on the fly to one scratch object, same
            # tar-then-verify discipline as backmeup.archive.sh. This is
            # scratch staging only: the live directory itself is NEVER
            # removed here (that is backmeup.archive.sh's job, on its
            # own schedule) and the scratch tarball is always deleted
            # after this attempt, success or failure.
            mkdir -p "${l_BMU_STAGING_PARENT}"
            l_tmp="${l_BMU_STAGING_PARENT}/${l_prj}-${l_snapkey}.tar.gz.part"
            rm -f "${l_tmp}"
            if ! ( cd "${l_bp}" && tar -czf "${l_tmp}" "${l_snapkey}" ); then
                echo "ERROR: local tar failed for ${l_prj}/${l_snapkey}, not uploaded."
                rm -f "${l_tmp}"
                l_BMU_FAILED=`expr ${l_BMU_FAILED} + 1`
                continue
            fi;
            l_ntar=`tar -tzf "${l_tmp}" | wc -l | tr -d ' '`
            l_ndir=`find "${l_entry%/}" | wc -l | tr -d ' '`
            if [ "${l_ntar}" != "${l_ndir}" ]; then
                echo "ERROR: local tar verification failed for ${l_prj}/${l_snapkey}, not uploaded."
                rm -f "${l_tmp}"
                l_BMU_FAILED=`expr ${l_BMU_FAILED} + 1`
                continue
            fi;
            l_final="${l_BMU_STAGING_PARENT}/${l_snapkey}.tar.gz"
            mv "${l_tmp}" "${l_final}"
            if bmuProtonUploadOne "${l_final}" "${l_remote_prj}"; then
                printf '%s\n' "${l_snapkey}" >> "${l_state}"
                echo "replicated ${l_prj}/${l_snapkey}"
                l_BMU_REPLICATED=`expr ${l_BMU_REPLICATED} + 1`
            else
                echo "ERROR: ${l_prj}/${l_snapkey} not marked replicated (see above)."
                l_BMU_FAILED=`expr ${l_BMU_FAILED} + 1`
            fi;
            rm -f "${l_final}"
        fi;
    done
done
rm -rf "${l_BMU_STAGING_PARENT}" 2>/dev/null
#
if [ -n "${l_BMU_DRYRUN}" ]; then
    echo "DRY RUN: ${l_BMU_REPLICATED} snapshot(s) would be replicated, ${l_BMU_SKIPPED} already done."
    exit 0
fi;
echo "${l_BMU_REPLICATED} snapshot(s) replicated, ${l_BMU_SKIPPED} already done, ${l_BMU_FAILED} failed."
if [ ${l_BMU_FAILED} -gt 0 ]; then
    exit 1
fi;
exit 0
