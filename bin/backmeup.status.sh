#! /bin/sh
#
# Show per-project backup status: last successful run, last archived
# change, number of snapshots, and disk usage of mirror and history.
#
#   LAST RUN    from the .bmulastrun stamp backmeup.sh writes after a
#               successful run ("-" for projects backed up only by
#               versions that did not record it yet)
#   LAST CHANGE the newest B-<date> snapshot, i.e. the last time a
#               backup actually archived something (a run that changes
#               nothing creates no snapshot on purpose)
#
# Old-layout mirrors (pre-bmug2 double nesting) are flagged with the
# migration command to run.
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
echo "BMU backup status"
echo "  SYNC:    ${BMU_DIRRSYNC}"
echo "  HISTORY: ${BMU_DIRBACKUPS}"
echo ""
printf "%-24s %-20s %-20s %10s %8s %8s\n" \
    "PROJECT" "LAST RUN" "LAST CHANGE" "SNAPSHOTS" "MIRROR" "HISTORY"
l_found=0
for l_dir in "${BMU_DIRRSYNC}"/*/; do
    [ -d "${l_dir}" ] || continue
    l_found=1
    l_prj=`basename "${l_dir}"`
    l_bp="${BMU_DIRBACKUPS}/${l_prj}"
    #
    l_lastrun="-"
    if [ -f "${l_bp}/.bmulastrun" ]; then
        l_lastrun=`cat "${l_bp}/.bmulastrun"`
    fi
    #
    # newest snapshot dir, B-YYYYMMDD-HHMMSS reformatted for humans
    l_lastchg="-"
    l_last=`ls -d "${l_bp}"/B-*/ 2>/dev/null | sort | tail -1`
    if [ -n "${l_last}" ]; then
        l_lastchg=`basename "${l_last}" | sed 's/^B-\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/'`
    fi
    #
    l_snaps=`ls -d "${l_bp}"/B-*/ 2>/dev/null | wc -l | tr -d ' '`
    l_msize=`du -sh "${l_dir}" 2>/dev/null | awk '{print $1}'`
    l_hsize="-"
    if [ -d "${l_bp}" ]; then
        l_hsize=`du -sh "${l_bp}" 2>/dev/null | awk '{print $1}'`
    fi
    #
    # same unambiguous check as backmeup.migrate.sh: old layout means the
    # project dir contains nothing but the nested mirror
    l_note=""
    if [ -d "${l_dir}${l_prj}" ] && [ `ls -A "${l_dir}" | wc -l` -eq 1 ]; then
        l_note="  OLD LAYOUT: run backmeup.migrate.sh ${l_prj}"
    fi
    #
    printf "%-24s %-20s %-20s %10s %8s %8s%s\n" \
        "${l_prj}" "${l_lastrun}" "${l_lastchg}" "${l_snaps}" \
        "${l_msize}" "${l_hsize}" "${l_note}"
done
if [ ${l_found} -eq 0 ]; then
    echo "(no projects found in ${BMU_DIRRSYNC})"
fi
