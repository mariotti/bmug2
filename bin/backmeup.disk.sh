#! /bin/sh
#
# Disk-usage report: how much space is bmug2 costing on this machine,
# aggregated across every project in SYNC + HISTORY, plus an honest
# estimate of what off-site replication would push (today a pure
# local proxy; a future phase can call `rclone size` for real).
#
#   usage: backmeup.disk.sh [--json]
#
# Without --json, prints a short text summary. With --json, prints a
# structured object the GUI parses into its Disk usage view.
#
# Fields:
#   sync_total_kb          - sum of per-project SYNC sizes (du -sk)
#   history_total_kb       - sum of per-project HISTORY sizes
#   replicate_estimate_kb  - (sync + history), minus projects whose
#                            .bmureplicate-class sidecar reads "none"
#                            (those are local-only - see docs/MANUAL.md).
#                            An ESTIMATE, not a measurement. No remote
#                            call. A later phase could call
#                            `rclone size` when the backend is rclone.
#   projects[]             - per-project rows with sync_kb/history_kb/
#                            replicate_class, same shape as
#                            backmeup.status.sh --json so a caller can
#                            recompute totals itself or cross-check.
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
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# SETUP
. "${BMU_PATH}/backmeup.setup.sh"
#
l_BMU_JSON=""
if [ "$1" = "--json" ]; then
    l_BMU_JSON="yes"
    shift
fi;
#
l_BMU_SYNC_TOTAL=0
l_BMU_HIST_TOTAL=0
l_BMU_EST_TOTAL=0
l_BMU_PROJJSON=""
l_BMU_PROJCOUNT=0
#
for l_dir in "${BMU_DIRRSYNC}"/*/; do
    [ -d "${l_dir}" ] || continue
    l_prj=`basename "${l_dir}"`
    l_bp="${BMU_DIRBACKUPS}/${l_prj}"
    #
    # SYNC size (project's live mirror dir)
    l_syncval=`du -sk "${l_dir}" 2>/dev/null | awk '{print $1}'`
    [ -z "${l_syncval}" ] && l_syncval=0
    #
    # HISTORY size (project's .../HISTORY/<project>/ dir). Missing is
    # valid: a never-run project has no HISTORY entry at all. Reported
    # as 0 to keep arithmetic honest; the detail view sees it as 0 kB.
    l_histval=0
    if [ -d "${l_bp}" ]; then
        l_histcand=`du -sk "${l_bp}" 2>/dev/null | awk '{print $1}'`
        [ -n "${l_histcand}" ] && l_histval="${l_histcand}"
    fi;
    #
    # Replicate class: same sidecar backmeup.replicate.sh reads.
    # Anything other than literal "none" (after trim) is treated as
    # "default" - matches replicate.sh's own permissive behavior.
    l_replclass="default"
    if [ -f "${l_bp}/.bmureplicate-class" ]; then
        l_classraw=`head -1 "${l_bp}/.bmureplicate-class" 2>/dev/null | tr -d '[:space:]'`
        if [ "${l_classraw}" = "none" ]; then
            l_replclass="none"
        fi
    fi
    #
    l_BMU_SYNC_TOTAL=`expr "${l_BMU_SYNC_TOTAL}" + "${l_syncval}"`
    l_BMU_HIST_TOTAL=`expr "${l_BMU_HIST_TOTAL}" + "${l_histval}"`
    if [ "${l_replclass}" != "none" ]; then
        l_BMU_EST_TOTAL=`expr "${l_BMU_EST_TOTAL}" + "${l_syncval}" + "${l_histval}"`
    fi
    l_BMU_PROJCOUNT=`expr "${l_BMU_PROJCOUNT}" + 1`
    #
    if [ -n "${l_BMU_JSON}" ]; then
        l_pesc=`bmuJsonEscape "${l_prj}"`
        l_obj="{\"name\":\"${l_pesc}\",\"sync_kb\":${l_syncval},\"history_kb\":${l_histval},\"replicate_class\":\"${l_replclass}\"}"
        [ -n "${l_BMU_PROJJSON}" ] && l_BMU_PROJJSON="${l_BMU_PROJJSON},"
        l_BMU_PROJJSON="${l_BMU_PROJJSON}${l_obj}"
    fi
done
#
# Human-friendly KB -> auto-unit formatter. Matches `du -sh`'s shape
# (one decimal place, suffix) closely enough for a status line; a
# precise byte count lives in the --json output for anyone who needs
# it. `expr` is integer-only, so we keep it in KB and let awk do the
# one float division when printing.
bmuFormatKb() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576)      printf "%.1f GB\n", kb/1048576;
        else if (kb >= 1024)    printf "%.1f MB\n", kb/1024;
        else                    printf "%d KB\n",  kb;
    }'
}
#
if [ -n "${l_BMU_JSON}" ]; then
    l_sync_esc=`bmuJsonEscape "${BMU_DIRRSYNC}"`
    l_hist_esc=`bmuJsonEscape "${BMU_DIRBACKUPS}"`
    printf '{"sync_dir":"%s","history_dir":"%s","sync_total_kb":%s,"history_total_kb":%s,"replicate_estimate_kb":%s,"projects":[%s]}\n' \
        "${l_sync_esc}" "${l_hist_esc}" \
        "${l_BMU_SYNC_TOTAL}" "${l_BMU_HIST_TOTAL}" "${l_BMU_EST_TOTAL}" \
        "${l_BMU_PROJJSON}"
else
    echo "BMU disk usage (${l_BMU_PROJCOUNT} projects)"
    echo "  SYNC:    ${BMU_DIRRSYNC}"
    echo "  HISTORY: ${BMU_DIRBACKUPS}"
    echo ""
    l_syncfmt=`bmuFormatKb "${l_BMU_SYNC_TOTAL}"`
    l_histfmt=`bmuFormatKb "${l_BMU_HIST_TOTAL}"`
    l_estfmt=`bmuFormatKb "${l_BMU_EST_TOTAL}"`
    printf "  %-20s %10s\n" "SYNC total:"        "${l_syncfmt}"
    printf "  %-20s %10s\n" "HISTORY total:"     "${l_histfmt}"
    printf "  %-20s %10s   (estimate; local proxy, no remote call)\n" \
        "Replicate estimate:" "${l_estfmt}"
fi
