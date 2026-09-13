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
    #
    # Live mirror content (backmeup.sh writes/refreshes one of these per
    # project on every successful run) - covers files too new for the
    # locate index above, which is only rebuilt by the separate, slower
    # bmu updatedb, possibly a day away via cron.
    for l_fl in "${BMU_DIRBACKUPS}"/*.filelist; do
        [ -f "${l_fl}" ] || continue
        for l_pat in "$@"; do
            grep -i -- "${l_pat}" "${l_fl}" | \
                sed "s|^|${BMU_DIRRSYNC}/|; s|\$| (live)|"
        done
    done
    exit 0
fi;
#
# JSON mode: same sources as above, but formatted via one native awk
# pass per result set instead of a shell subprocess (bmuJsonEscape,
# two forks: printf+sed) plus a string that grows one result at a
# time. Fine for a handful of hits, but confirmed for real to be
# catastrophic at realistic scale: a 20k-line filelist matched against
# an unselective single-letter pattern ("a" - about as bad a case as
# search gets) never finished in 3 minutes with the old code, from
# tens of thousands of forks plus the growing-string's own quadratic
# cost. awk parses each whole match set in one process instead.
# mktemp -d (not a fixed/predictable path) avoids a symlink race in a
# shared /tmp; falls back to a PID-based dir if mktemp is unavailable,
# same "prefer the safe tool, still work without it" spirit as the
# rsync/indexer/rclone detection above.
l_indexed="false"
l_bmu_tmpdir=`mktemp -d "${TMPDIR:-/tmp}/bmulocate.XXXXXX" 2>/dev/null` || l_bmu_tmpdir="${TMPDIR:-/tmp}/bmulocate.$$"
mkdir -p "${l_bmu_tmpdir}"
trap 'rm -rf "${l_bmu_tmpdir}"' EXIT
: > "${l_bmu_tmpdir}/idx"
: > "${l_bmu_tmpdir}/arch"
: > "${l_bmu_tmpdir}/live"
#
if [ -n "${BMU_CMDLOCATE}" ]; then
    l_indexed="true"
    { ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.db" "$@" 2>/dev/null; \
      ${BMU_CMDLOCATE} -i -d "${BMU_DIRDBLOCATE}/.locate.dbb" "$@" 2>/dev/null; } \
      > "${l_bmu_tmpdir}/idx"
fi;
#
for l_fl in "${BMU_DIRBACKUPS}"/*/B-*.filelist; do
    [ -f "${l_fl}" ] || continue
    l_bdir="${l_fl%.filelist}"
    [ -d "${l_bdir}" ] && continue
    for l_pat in "$@"; do
        grep -i -- "${l_pat}" "${l_fl}" 2>/dev/null | \
            sed "s|^|${BMU_DIRBACKUPS}/|" >> "${l_bmu_tmpdir}/arch"
    done
done
#
for l_fl in "${BMU_DIRBACKUPS}"/*.filelist; do
    [ -f "${l_fl}" ] || continue
    for l_pat in "$@"; do
        grep -i -- "${l_pat}" "${l_fl}" 2>/dev/null | \
            sed "s|^|${BMU_DIRRSYNC}/|" >> "${l_bmu_tmpdir}/live"
    done
done
#
l_idxcount=`wc -l < "${l_bmu_tmpdir}/idx" | tr -d ' '`
l_archcount=`wc -l < "${l_bmu_tmpdir}/arch" | tr -d ' '`
l_livecount=`wc -l < "${l_bmu_tmpdir}/live" | tr -d ' '`
#
# Same escaping bmuJsonEscape does (backslash first, then quote - so a
# literal backslash in a path doesn't get double-escaped by the second
# substitution), just applied to every line of all three files in one
# process instead of once per line. srctag=X between files is standard
# awk: file arguments are processed in order, and a var=value argument
# is assigned at the point awk reaches it, so srctag is "index" while
# reading idx, then reassigned before arch, then live.
# $(...) here, not backticks: backtick command substitution has its
# own legacy backslash pre-processing that reaches through nested
# single quotes - confirmed for real that it mangled the awk regex
# below (a stray "newline in regular expression" syntax error) even
# though the exact same script text runs correctly on its own. $(...)
# doesn't have that quirk.
l_results=$(awk '
{
    path = $0
    gsub(/\\/, "\\\\", path)
    gsub(/"/, "\\\"", path)
    if (n++ > 0) printf ","
    printf "{\"path\":\"%s\",\"source\":\"%s\"}", path, srctag
}
' srctag=index "${l_bmu_tmpdir}/idx" \
  srctag=archived_filelist "${l_bmu_tmpdir}/arch" \
  srctag=live "${l_bmu_tmpdir}/live")
#
l_patjson=""
for l_pat in "$@"; do
    l_pesc=`bmuJsonEscape "${l_pat}"`
    [ -n "${l_patjson}" ] && l_patjson="${l_patjson},"
    l_patjson="${l_patjson}\"${l_pesc}\""
done
#
printf '{"patterns":[%s],"indexed":%s,"counts":{"index":%d,"archived_filelist":%d,"live":%d},"results":[%s]}\n' \
    "${l_patjson}" "${l_indexed}" "${l_idxcount}" "${l_archcount}" "${l_livecount}" "${l_results}"
#
# NOTES
#
# The funny thing is that, because of the locate.db format, and
# our choosen date format and directory structure,
# the results appears already ordered by date.
#
