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
# Source BMU functions (bmuJsonEscape, used by --json below)
# --------------------------
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# SETUP
. "${BMU_PATH}/backmeup.setup.sh"
#
# --json: stable structured output for non-terminal consumers (a
# future GUI, or any other script) instead of the raw locate/grep
# output below. Field names echo mcp/'s LocateResult/LocateHit/
# LocateCounts models (patterns, indexed, counts, results[].source).
l_BMU_JSON=""
if [ "$1" = "--json" ]; then
    l_BMU_JSON="yes"
    shift
fi;
#
if [ -z "${l_BMU_JSON}" ]; then
    if [ -n "${BMU_CMDLOCATE}" ]; then
        ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.db" "$@"
        ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.dbb" "$@"
    fi;
    #
    # Archived snapshots (backmeup.archive.sh): their files are no longer
    # on disk for locate, but every archived snapshot keeps its
    # .filelist. Grep the filelists whose snapshot directory is gone -
    # plain grep, so this works with no locate installed at all.
    for l_fl in "${BMU_DIRBACKUPS}"/*/B-*.filelist; do
        [ -f "${l_fl}" ] || continue
        l_bdir="${l_fl%.filelist}"
        [ -d "${l_bdir}" ] && continue
        for l_pat in "$@"; do
            grep -i -- "${l_pat}" "${l_fl}" | \
                sed "s|^|${BMU_DIRBACKUPS}/|; s|\$| (archived)|"
        done
    done
    exit 0
fi;
#
# JSON mode: same two sources as above, captured instead of printed.
l_indexed="false"
l_idxcount=0
l_archcount=0
l_results=""
#
bmuJsonAddResult() {
    # $1=path $2=source
    l_jaresc=`bmuJsonEscape "$1"`
    [ -n "${l_results}" ] && l_results="${l_results},"
    l_results="${l_results}{\"path\":\"${l_jaresc}\",\"source\":\"$2\"}"
}
#
if [ -n "${BMU_CMDLOCATE}" ]; then
    l_indexed="true"
    l_hits=`{ ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.db" "$@" 2>/dev/null; \
              ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.dbb" "$@" 2>/dev/null; }`
    if [ -n "${l_hits}" ]; then
        l_oldifs="${IFS}"
        IFS='
'
        for l_path in ${l_hits}; do
            [ -n "${l_path}" ] || continue
            bmuJsonAddResult "${l_path}" "index"
            l_idxcount=`expr ${l_idxcount} + 1`
        done
        IFS="${l_oldifs}"
    fi;
fi;
#
for l_fl in "${BMU_DIRBACKUPS}"/*/B-*.filelist; do
    [ -f "${l_fl}" ] || continue
    l_bdir="${l_fl%.filelist}"
    [ -d "${l_bdir}" ] && continue
    for l_pat in "$@"; do
        l_ahits=`grep -i -- "${l_pat}" "${l_fl}" 2>/dev/null`
        [ -z "${l_ahits}" ] && continue
        l_oldifs="${IFS}"
        IFS='
'
        for l_apath in ${l_ahits}; do
            [ -n "${l_apath}" ] || continue
            bmuJsonAddResult "${BMU_DIRBACKUPS}/${l_apath}" "archived_filelist"
            l_archcount=`expr ${l_archcount} + 1`
        done
        IFS="${l_oldifs}"
    done
done
#
l_patjson=""
for l_pat in "$@"; do
    l_pesc=`bmuJsonEscape "${l_pat}"`
    [ -n "${l_patjson}" ] && l_patjson="${l_patjson},"
    l_patjson="${l_patjson}\"${l_pesc}\""
done
#
printf '{"patterns":[%s],"indexed":%s,"counts":{"index":%d,"archived_filelist":%d},"results":[%s]}\n' \
    "${l_patjson}" "${l_indexed}" "${l_idxcount}" "${l_archcount}" "${l_results}"
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
