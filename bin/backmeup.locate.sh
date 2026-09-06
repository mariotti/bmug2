#! /bin/sh
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
#
if [ -n "${BMU_CMDLOCATE}" ]; then
    ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.db" "$@"
    ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.dbb" "$@"
fi;
#
# Archived snapshots (backmeup.archive.sh): their files are no longer on
# disk for locate, but every archived snapshot keeps its .filelist. Grep
# the filelists whose snapshot directory is gone - plain grep, so this
# works with no locate installed at all.
for l_fl in "${BMU_DIRBACKUPS}"/*/B-*.filelist; do
    [ -f "${l_fl}" ] || continue
    l_bdir="${l_fl%.filelist}"
    [ -d "${l_bdir}" ] && continue
    for l_pat in "$@"; do
        grep -i -- "${l_pat}" "${l_fl}" | \
            sed "s|^|${BMU_DIRBACKUPS}/|; s|\$| (archived)|"
    done
done
#
# NOTES
#
# The funny thing is that, because of the locate.db format, and
# our choosen date format and directory structure,
# the results appears already ordered by date.
#
# TODO
# Check to exclude the -d option from this particular
# version of locate. As it makes little sense to allow it.
# For specific searches (when we might need the -d option)
# we can use directly the original "locate" command.
# An exception is to provide facilites for a future GUI.
# But in that case we create the specific facility.
#
