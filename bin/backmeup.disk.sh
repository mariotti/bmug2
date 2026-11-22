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
#                            Each row also carries sync_warn_bytes,
#                            history_warn_bytes (effective budget after
#                            per-project sidecar override), plus
#                            sync_over / history_over booleans.
#   budget                 - global budget info: sync_warn_bytes,
#                            history_warn_bytes (nulls if unset) plus
#                            sync_over / history_over booleans against
#                            the grand totals. See docs/PROJECT_disk-
#                            size.md for the policy - shell is warn-only;
#                            this script never acts on over-budget state.
#   volumes                - which volume SYNC / HISTORY live on,
#                            with the mount point, total/available KB,
#                            and a same_volume boolean for when they
#                            share one. The GUI uses this to show
#                            per-volume subheadings on the Disk usage
#                            view; a scripted caller can detect
#                            SYNC-on-external-drive setups.
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
    # Per-project effective budget: sidecar key overrides the global
    # default (same precedence backmeup.sh uses at end-of-run).
    l_prj_sync_warn=`bmuReadBudgetKey "${l_bp}" SYNC_WARN_BYTES`
    [ -z "${l_prj_sync_warn}" ] && l_prj_sync_warn="${BMU_SYNC_WARN_BYTES}"
    l_prj_hist_warn=`bmuReadBudgetKey "${l_bp}" HISTORY_WARN_BYTES`
    [ -z "${l_prj_hist_warn}" ] && l_prj_hist_warn="${BMU_HISTORY_WARN_BYTES}"
    #
    l_prj_sync_bytes=`expr "${l_syncval}" \* 1024`
    l_prj_hist_bytes=`expr "${l_histval}" \* 1024`
    l_prj_sync_over="false"
    if [ -n "${l_prj_sync_warn}" ] && [ "${l_prj_sync_bytes}" -gt "${l_prj_sync_warn}" ] 2>/dev/null; then
        l_prj_sync_over="true"
    fi
    l_prj_hist_over="false"
    if [ -n "${l_prj_hist_warn}" ] && [ "${l_prj_hist_bytes}" -gt "${l_prj_hist_warn}" ] 2>/dev/null; then
        l_prj_hist_over="true"
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
        # Budget keys serialize as JSON `null` when unset (empty
        # string from the resolver), not the string "" - keeps the
        # Rust side (DiskUsageProject) parse-strict.
        l_prj_sync_warn_json="null"
        [ -n "${l_prj_sync_warn}" ] && l_prj_sync_warn_json="${l_prj_sync_warn}"
        l_prj_hist_warn_json="null"
        [ -n "${l_prj_hist_warn}" ] && l_prj_hist_warn_json="${l_prj_hist_warn}"
        l_obj="{\"name\":\"${l_pesc}\",\"sync_kb\":${l_syncval},\"history_kb\":${l_histval},\"replicate_class\":\"${l_replclass}\",\"sync_warn_bytes\":${l_prj_sync_warn_json},\"history_warn_bytes\":${l_prj_hist_warn_json},\"sync_over\":${l_prj_sync_over},\"history_over\":${l_prj_hist_over}}"
        [ -n "${l_BMU_PROJJSON}" ] && l_BMU_PROJJSON="${l_BMU_PROJJSON},"
        l_BMU_PROJJSON="${l_BMU_PROJJSON}${l_obj}"
    fi
done
#
# Global budget evaluation (grand-total scale, not per-project).
# `*_WARN_BYTES` comes straight from setup.sh; the per-source sidecar
# only overrides at the project level above, never at the global level.
l_BMU_SYNC_TOTAL_B=`expr "${l_BMU_SYNC_TOTAL}" \* 1024`
l_BMU_HIST_TOTAL_B=`expr "${l_BMU_HIST_TOTAL}" \* 1024`
l_BMU_SYNC_OVER="false"
if [ -n "${BMU_SYNC_WARN_BYTES}" ] && [ "${l_BMU_SYNC_TOTAL_B}" -gt "${BMU_SYNC_WARN_BYTES}" ] 2>/dev/null; then
    l_BMU_SYNC_OVER="true"
fi
l_BMU_HIST_OVER="false"
if [ -n "${BMU_HISTORY_WARN_BYTES}" ] && [ "${l_BMU_HIST_TOTAL_B}" -gt "${BMU_HISTORY_WARN_BYTES}" ] 2>/dev/null; then
    l_BMU_HIST_OVER="true"
fi
#
# Volume info for each of the two roots. bmuVolumeInfo returns
# "mount|total_kb|avail_kb" or empty on any failure - we treat empty
# as "volume info unavailable" and emit null fields rather than
# aborting the report. same_volume is derived from the mount strings;
# if either is empty, same_volume is null (unknown).
l_sync_vol=`bmuVolumeInfo "${BMU_DIRRSYNC}"`
l_hist_vol=`bmuVolumeInfo "${BMU_DIRBACKUPS}"`
l_sync_vol_mount=`echo "${l_sync_vol}" | awk -F'|' '{print $1}'`
l_sync_vol_total=`echo "${l_sync_vol}" | awk -F'|' '{print $2}'`
l_sync_vol_avail=`echo "${l_sync_vol}" | awk -F'|' '{print $3}'`
l_hist_vol_mount=`echo "${l_hist_vol}" | awk -F'|' '{print $1}'`
l_hist_vol_total=`echo "${l_hist_vol}" | awk -F'|' '{print $2}'`
l_hist_vol_avail=`echo "${l_hist_vol}" | awk -F'|' '{print $3}'`
l_same_vol_json="null"
if [ -n "${l_sync_vol_mount}" ] && [ -n "${l_hist_vol_mount}" ]; then
    if [ "${l_sync_vol_mount}" = "${l_hist_vol_mount}" ]; then
        l_same_vol_json="true"
    else
        l_same_vol_json="false"
    fi
fi
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
    # Budget + volume sub-objects. Null when unset so the Rust/TS
    # side can reach for the presence-check idiom (option<u64>)
    # rather than decoding an empty string as a number.
    l_sync_warn_json="null"
    [ -n "${BMU_SYNC_WARN_BYTES}" ] && l_sync_warn_json="${BMU_SYNC_WARN_BYTES}"
    l_hist_warn_json="null"
    [ -n "${BMU_HISTORY_WARN_BYTES}" ] && l_hist_warn_json="${BMU_HISTORY_WARN_BYTES}"
    l_sync_mount_json="null"
    [ -n "${l_sync_vol_mount}" ] && l_sync_mount_json="\"`bmuJsonEscape \"${l_sync_vol_mount}\"`\""
    l_sync_vol_total_json="null"; [ -n "${l_sync_vol_total}" ] && l_sync_vol_total_json="${l_sync_vol_total}"
    l_sync_vol_avail_json="null"; [ -n "${l_sync_vol_avail}" ] && l_sync_vol_avail_json="${l_sync_vol_avail}"
    l_hist_mount_json="null"
    [ -n "${l_hist_vol_mount}" ] && l_hist_mount_json="\"`bmuJsonEscape \"${l_hist_vol_mount}\"`\""
    l_hist_vol_total_json="null"; [ -n "${l_hist_vol_total}" ] && l_hist_vol_total_json="${l_hist_vol_total}"
    l_hist_vol_avail_json="null"; [ -n "${l_hist_vol_avail}" ] && l_hist_vol_avail_json="${l_hist_vol_avail}"
    #
    printf '{"sync_dir":"%s","history_dir":"%s","sync_total_kb":%s,"history_total_kb":%s,"replicate_estimate_kb":%s,"budget":{"sync_warn_bytes":%s,"history_warn_bytes":%s,"sync_over":%s,"history_over":%s},"volumes":{"sync":{"mount":%s,"total_kb":%s,"avail_kb":%s},"history":{"mount":%s,"total_kb":%s,"avail_kb":%s},"same_volume":%s},"projects":[%s]}\n' \
        "${l_sync_esc}" "${l_hist_esc}" \
        "${l_BMU_SYNC_TOTAL}" "${l_BMU_HIST_TOTAL}" "${l_BMU_EST_TOTAL}" \
        "${l_sync_warn_json}" "${l_hist_warn_json}" \
        "${l_BMU_SYNC_OVER}" "${l_BMU_HIST_OVER}" \
        "${l_sync_mount_json}" "${l_sync_vol_total_json}" "${l_sync_vol_avail_json}" \
        "${l_hist_mount_json}" "${l_hist_vol_total_json}" "${l_hist_vol_avail_json}" \
        "${l_same_vol_json}" \
        "${l_BMU_PROJJSON}"
else
    echo "BMU disk usage (${l_BMU_PROJCOUNT} projects)"
    echo "  SYNC:    ${BMU_DIRRSYNC}"
    echo "  HISTORY: ${BMU_DIRBACKUPS}"
    # Volume subheading - only when the mount lookup returned
    # something; skip silently otherwise (keeps the old output shape
    # stable for a scripted caller that greps the heading).
    if [ -n "${l_sync_vol_mount}" ]; then
        l_sync_vol_avail_fmt=`bmuFormatKb "${l_sync_vol_avail:-0}"`
        l_sync_vol_total_fmt=`bmuFormatKb "${l_sync_vol_total:-0}"`
        echo "  SYNC volume:    ${l_sync_vol_mount} (${l_sync_vol_avail_fmt} free of ${l_sync_vol_total_fmt})"
    fi
    if [ -n "${l_hist_vol_mount}" ] && [ "${l_hist_vol_mount}" != "${l_sync_vol_mount}" ]; then
        l_hist_vol_avail_fmt=`bmuFormatKb "${l_hist_vol_avail:-0}"`
        l_hist_vol_total_fmt=`bmuFormatKb "${l_hist_vol_total:-0}"`
        echo "  HISTORY volume: ${l_hist_vol_mount} (${l_hist_vol_avail_fmt} free of ${l_hist_vol_total_fmt})"
    fi
    echo ""
    l_syncfmt=`bmuFormatKb "${l_BMU_SYNC_TOTAL}"`
    l_histfmt=`bmuFormatKb "${l_BMU_HIST_TOTAL}"`
    l_estfmt=`bmuFormatKb "${l_BMU_EST_TOTAL}"`
    # Human-friendly over-budget flag per row; blank when budget unset.
    l_sync_over_flag=""
    [ "${l_BMU_SYNC_OVER}" = "true" ] && l_sync_over_flag="  OVER BUDGET"
    l_hist_over_flag=""
    [ "${l_BMU_HIST_OVER}" = "true" ] && l_hist_over_flag="  OVER BUDGET"
    printf "  %-20s %10s%s\n" "SYNC total:"        "${l_syncfmt}" "${l_sync_over_flag}"
    printf "  %-20s %10s%s\n" "HISTORY total:"     "${l_histfmt}" "${l_hist_over_flag}"
    printf "  %-20s %10s   (estimate; local proxy, no remote call)\n" \
        "Replicate estimate:" "${l_estfmt}"
fi
