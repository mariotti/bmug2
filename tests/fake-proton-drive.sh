#! /bin/sh
#
# A minimal stand-in for the real proton-drive CLI, used only by
# tests/test_backmeup.sh's backmeup.replicate.proton.sh tests - CI has
# no real Proton account to authenticate against. Only implements the
# exact invocations backmeup.replicate.proton.sh actually makes:
#
#   filesystem info <path>
#   filesystem create-folder <parent> <name>
#   filesystem upload -j -f skip -d skip -t <local> <remote-parent>
#
# Logs every call (one line per invocation, args space-separated) to
# $BMU_FAKE_PROTON_LOG, and persists minimal "remote" state (which
# folders/files it has "seen") under $BMU_FAKE_PROTON_STATE_DIR, so
# repeated calls - across one script run, and across separate test
# invocations reusing the same state dir - simulate a real stateful
# remote (a folder that was "created" stays "found"; a file uploaded
# once is "skipped" on a byte-identical second upload, matching the
# real CLI's own confirmed behavior).
#
# $BMU_FAKE_PROTON_FAIL_MATCH, if set, makes any upload whose local-path
# argument contains that substring report a failure instead - this is
# how tests inject a deliberate upload failure.
#
: "${BMU_FAKE_PROTON_LOG:?BMU_FAKE_PROTON_LOG must be set}"
: "${BMU_FAKE_PROTON_STATE_DIR:?BMU_FAKE_PROTON_STATE_DIR must be set}"
mkdir -p "${BMU_FAKE_PROTON_STATE_DIR}"
echo "$@" >> "${BMU_FAKE_PROTON_LOG}"
#
l_fpd_key() {
    printf '%s' "$1" | tr '/' '_'
}
#
case "$1 $2" in
    "filesystem info")
        l_fpd_path="$3"
        if [ -f "${BMU_FAKE_PROTON_STATE_DIR}/folder_`l_fpd_key \"${l_fpd_path}\"`" ]; then
            exit 0
        fi;
        echo "Node not found: ${l_fpd_path}"
        exit 1
        ;;
    "filesystem create-folder")
        l_fpd_parent="$3"
        l_fpd_name="$4"
        l_fpd_full="${l_fpd_parent%/}/${l_fpd_name}"
        if [ -f "${BMU_FAKE_PROTON_STATE_DIR}/folder_`l_fpd_key \"${l_fpd_full}\"`" ]; then
            echo "A file or folder with that name already exists"
            exit 1
        fi;
        touch "${BMU_FAKE_PROTON_STATE_DIR}/folder_`l_fpd_key \"${l_fpd_full}\"`"
        exit 0
        ;;
    "filesystem upload")
        # Always called as: upload -j -f skip -d skip -t <local> <remote-parent>
        shift 2
        l_fpd_argcount=$#
        l_fpd_remoteparent=`eval echo \\$${l_fpd_argcount}`
        l_fpd_local=`eval echo \\$$((l_fpd_argcount - 1))`
        if [ -n "${BMU_FAKE_PROTON_FAIL_MATCH:-}" ]; then
            case "${l_fpd_local}" in
                *"${BMU_FAKE_PROTON_FAIL_MATCH}"*)
                    echo '{"transferredItems":0,"transferredBytes":0,"skippedItems":0,"failedItems":1,"failures":[{"path":"'"${l_fpd_local}"'"}]}'
                    exit 1
                    ;;
            esac
        fi;
        l_fpd_rkey=`l_fpd_key "${l_fpd_remoteparent}/$(basename "${l_fpd_local}")"`
        if [ -f "${BMU_FAKE_PROTON_STATE_DIR}/file_${l_fpd_rkey}" ]; then
            echo '{"transferredItems":0,"transferredBytes":0,"skippedItems":1,"failedItems":0,"failures":[]}'
        else
            touch "${BMU_FAKE_PROTON_STATE_DIR}/file_${l_fpd_rkey}"
            echo '{"transferredItems":1,"transferredBytes":1,"skippedItems":0,"failedItems":0,"failures":[]}'
        fi;
        exit 0
        ;;
    *)
        echo "fake-proton-drive: unsupported invocation: $*" >&2
        exit 1
        ;;
esac
