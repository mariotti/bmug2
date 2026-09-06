#! /bin/sh
#
# Restore an archived snapshot: extract B-<date>.tar.gz back into the
# project history and remove the tarball, returning to the exact state
# before backmeup.archive.sh ran.
#
#   usage: backmeup.unarchive.sh <project> <snapshot>
#
# <snapshot> is the B-YYYYMMDD-HHMMSS name (the B- prefix is optional).
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
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "usage: backmeup.unarchive.sh <project> <snapshot>"
    echo "  Extracts <snapshot>.tar.gz back into the project history."
    exit 1;
fi;
l_BMU_PRJDIR=`basename "${1}"`
case "${2}" in
    B-*) l_BMU_SNAP="${2}";;
    *)   l_BMU_SNAP="B-${2}";;
esac
l_BMU_BP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
l_BMU_TGZ="${l_BMU_BP}/${l_BMU_SNAP}.tar.gz"
#
if [ ! -f "${l_BMU_TGZ}" ]; then
    echo "ERROR: no archive found: ${l_BMU_TGZ}"
    exit 1
fi;
if [ -d "${l_BMU_BP}/${l_BMU_SNAP}" ]; then
    echo "ERROR: ${l_BMU_SNAP} already exists as a directory, not touching it."
    exit 1
fi;
#
if ( cd "${l_BMU_BP}" && tar -xzf "${l_BMU_SNAP}.tar.gz" ); then
    rm "${l_BMU_TGZ}"
    echo "restored ${l_BMU_SNAP} (archive removed)"
else
    echo "ERROR: extraction failed, archive kept: ${l_BMU_TGZ}"
    exit 1
fi;
