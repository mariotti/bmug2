#! /bin/sh
#
# Safe extraction, not restoration: pulls one file (or a whole
# snapshot) out of project history - live or already archived into a
# B-<date>.tar.gz - to a destination you choose. Never touches SYNC
# (the live mirror) and never modifies HISTORY itself; making a
# retrieved file live again stays a deliberate manual step, on
# purpose - this project's philosophy is plain files you can always
# just cp/Finder yourself, not automating the one step (overwriting
# current work) that's genuinely risky.
#
#   usage: backmeup.retrieve.sh [-n|--dry-run] <project> <snapshot> [relative-path] <destination>
#
# <snapshot> is the B-YYYYMMDD-HHMMSS name (the B- prefix is optional).
# With <relative-path>, retrieves just that one file from inside the
# snapshot. Without it, retrieves the whole snapshot. <destination> is
# always a directory (created if missing) - the retrieved item is
# placed inside it, never overwriting anything already there.
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
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="yes"
    shift
fi;
#
l_BMU_USAGE="usage: backmeup.retrieve.sh [-n|--dry-run] <project> <snapshot> [relative-path] <destination>"
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "${l_BMU_USAGE}"
    exit 1;
fi;
l_BMU_PRJDIR=`basename "${1}"`
case "${2}" in
    B-*) l_BMU_SNAP="${2}";;
    *)   l_BMU_SNAP="B-${2}";;
esac
#
# Disambiguate by how many args are left: 1 = whole-snapshot
# (<destination> only), 2 = single-file (<relative-path> <destination>)
# - destination always last, matching cp's own convention.
l_BMU_RELPATH=""
if [ -n "$4" ]; then
    l_BMU_RELPATH="${3}"
    l_BMU_DEST="${4}"
else
    l_BMU_DEST="${3}"
fi;
#
# Path-traversal guard: a real concern for the live-directory case
# specifically (cp would happily follow ".." out of the snapshot
# directory) - cheap to check unconditionally rather than only for
# that one code path.
case "${l_BMU_RELPATH}" in
    /*)
        echo "ERROR: relative-path must not be absolute: ${l_BMU_RELPATH}"
        exit 1
        ;;
    ../*|*/../*|*/..|..)
        echo "ERROR: relative-path must not contain '..': ${l_BMU_RELPATH}"
        exit 1
        ;;
esac
#
l_BMU_BP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
l_BMU_SNAPDIR="${l_BMU_BP}/${l_BMU_SNAP}"
l_BMU_TGZ="${l_BMU_BP}/${l_BMU_SNAP}.tar.gz"
#
l_BMU_ISLIVE=""
if [ -d "${l_BMU_SNAPDIR}" ]; then
    l_BMU_ISLIVE="yes"
elif [ ! -f "${l_BMU_TGZ}" ]; then
    echo "ERROR: no snapshot found: ${l_BMU_SNAP} (checked ${l_BMU_SNAPDIR} and ${l_BMU_TGZ})"
    exit 1
fi;
#
if [ -n "${l_BMU_RELPATH}" ]; then
    l_BMU_TARGET="${l_BMU_DEST}/`basename \"${l_BMU_RELPATH}\"`"
else
    l_BMU_TARGET="${l_BMU_DEST}/${l_BMU_SNAP}"
fi;
if [ -e "${l_BMU_TARGET}" ]; then
    echo "ERROR: ${l_BMU_TARGET} already exists, not touching it."
    exit 1
fi;
#
if [ -n "${l_BMU_DRYRUN}" ]; then
    if [ -n "${l_BMU_RELPATH}" ]; then
        echo "would retrieve ${l_BMU_PRJDIR}/${l_BMU_SNAP}/${l_BMU_RELPATH} -> ${l_BMU_TARGET}"
    else
        echo "would retrieve ${l_BMU_PRJDIR}/${l_BMU_SNAP} (whole snapshot) -> ${l_BMU_TARGET}"
    fi;
    exit 0
fi;
#
mkdir -p "${l_BMU_DEST}"
#
if [ -n "${l_BMU_ISLIVE}" ]; then
    if [ -n "${l_BMU_RELPATH}" ]; then
        if [ ! -f "${l_BMU_SNAPDIR}/${l_BMU_RELPATH}" ]; then
            echo "ERROR: ${l_BMU_RELPATH} not found in ${l_BMU_SNAP}"
            exit 1
        fi;
        cp "${l_BMU_SNAPDIR}/${l_BMU_RELPATH}" "${l_BMU_TARGET}"
    else
        cp -R "${l_BMU_SNAPDIR}" "${l_BMU_DEST}/"
    fi;
else
    if [ -n "${l_BMU_RELPATH}" ]; then
        if ! tar -xzf "${l_BMU_TGZ}" -O "${l_BMU_SNAP}/${l_BMU_RELPATH}" > "${l_BMU_TARGET}.part" 2>/dev/null; then
            echo "ERROR: ${l_BMU_RELPATH} not found in ${l_BMU_SNAP}"
            rm -f "${l_BMU_TARGET}.part"
            exit 1
        fi;
        mv "${l_BMU_TARGET}.part" "${l_BMU_TARGET}"
    else
        tar -xzf "${l_BMU_TGZ}" -C "${l_BMU_DEST}"
    fi;
fi;
#
if [ -n "${l_BMU_RELPATH}" ]; then
    echo "retrieved ${l_BMU_PRJDIR}/${l_BMU_SNAP}/${l_BMU_RELPATH} -> ${l_BMU_TARGET}"
else
    echo "retrieved ${l_BMU_PRJDIR}/${l_BMU_SNAP} (whole snapshot) -> ${l_BMU_TARGET}"
fi;
