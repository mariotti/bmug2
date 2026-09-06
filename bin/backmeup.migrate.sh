#! /bin/sh
#
# Migrate one project's mirror from the old bmu layout to the bmug2 layout.
#
#   old: ${BMU_DIRRSYNC}/<project>/<project>/...   (double nesting)
#   new: ${BMU_DIRRSYNC}/<project>/...
#
# This is a same-filesystem rename: instant, and it preserves mtimes so the
# next backmeup.sh run re-transfers nothing. Historical B-<date> dirs in
# ${BMU_DIRBACKUPS} are immutable snapshots and are left untouched (they
# keep the extra level; search still finds everything in them).
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
. ${BMU_PATH}/backmeup.setup.sh
#
# Parsing the one option
if [ -z $1 ]; then
    echo "please give a project name (a directory under ${BMU_DIRRSYNC})."
    exit 1;
fi;
l_BMU_PRJDIR=`basename ${1}`
l_BMU_DIR="${BMU_DIRRSYNC}/${l_BMU_PRJDIR}"
l_BMU_NESTED="${l_BMU_DIR}/${l_BMU_PRJDIR}"
#
if [ ! -d "${l_BMU_NESTED}" ]; then
    echo "ERROR: no old-layout nesting found at ${l_BMU_NESTED}"
    echo "Nothing to migrate."
    exit 1
fi;
#
# In the old layout the project dir contains ONLY the nested mirror. If
# anything else is in there we cannot be sure this is the old layout
# (the project might legitimately contain a same-named subdirectory), so
# refuse rather than guess with the user's data.
l_BMU_ENTRIES=`ls -A "${l_BMU_DIR}" | wc -l`
if [ ${l_BMU_ENTRIES} -ne 1 ]; then
    echo "ERROR: ${l_BMU_DIR} contains more than the nested mirror,"
    echo "cannot safely tell the old layout from a project that has a"
    echo "same-named subdirectory. Please inspect and migrate manually."
    exit 1
fi;
#
# Rename up one level via a sibling temp name (same filesystem, instant).
l_BMU_TMP="${l_BMU_DIR}.bmumigrate.$$"
mv "${l_BMU_NESTED}" "${l_BMU_TMP}" && \
rmdir "${l_BMU_DIR}" && \
mv "${l_BMU_TMP}" "${l_BMU_DIR}"
if [ $? -ne 0 ]; then
    echo "ERROR: migration failed, please check ${l_BMU_DIR} and ${l_BMU_TMP}"
    exit 1
fi;
echo "Migrated: ${l_BMU_DIR} now mirrors the project directly."
echo "The next backmeup.sh run should transfer (almost) nothing."
