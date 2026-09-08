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
# Source BMU functions (bmuJsonEscape, used by --json below)
# --------------------------
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# SETUP
. "${BMU_PATH}/backmeup.setup.sh"
#
# --json: stable structured output for non-terminal consumers (a
# future GUI, or any other script) instead of the padded table below.
# Field names deliberately echo mcp/'s StatusResult/StatusProject
# models (last_run, last_change, snapshot_count, old_layout) so
# bmug2's two structured-status surfaces don't gratuitously disagree.
# One honest difference: mirror_size_kb/history_size_kb here come from
# `du -sk` (kilobytes, block-based) rather than an exact byte sum -
# getting byte-exact, portable sizing across BSD/GNU du/stat flag
# differences is real complexity not worth adding for a dashboard
# number. last_run/last_change stay the raw internal date strings
# (not reformatted to ISO 8601) - trivial for a JS/any consumer to
# reparse, not worth a `date` portability dependency here for.
l_BMU_JSON=""
if [ "$1" = "--json" ]; then
    l_BMU_JSON="yes"
    shift
fi;
#
if [ -z "${l_BMU_JSON}" ]; then
    echo "BMU backup status"
    echo "  SYNC:    ${BMU_DIRRSYNC}"
    echo "  HISTORY: ${BMU_DIRBACKUPS}"
    echo ""
    printf "%-24s %-20s %-20s %10s %8s %8s\n" \
        "PROJECT" "LAST RUN" "LAST CHANGE" "SNAPSHOTS" "MIRROR" "HISTORY"
fi;
l_found=0
l_projjson=""
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
    # newest snapshot dir, B-YYYYMMDD-HHMMSS - kept raw for JSON,
    # reformatted for the human table
    l_lastchg="-"
    l_lastchgraw=""
    l_last=`ls -d "${l_bp}"/B-*/ 2>/dev/null | sort | tail -1`
    if [ -n "${l_last}" ]; then
        l_lastchgraw=`basename "${l_last}"`
        l_lastchgraw="${l_lastchgraw#B-}"
        l_lastchg=`echo "${l_lastchgraw}" | sed 's/^\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/'`
    fi
    #
    l_snaps=`ls -d "${l_bp}"/B-*/ 2>/dev/null | wc -l | tr -d ' '`
    #
    # same unambiguous check as backmeup.migrate.sh: old layout means the
    # project dir contains nothing but the nested mirror
    l_note=""
    l_oldlayout="false"
    if [ -d "${l_dir}${l_prj}" ] && [ `ls -A "${l_dir}" | wc -l` -eq 1 ]; then
        l_note="  OLD LAYOUT: run backmeup.migrate.sh ${l_prj}"
        l_oldlayout="true"
    fi
    #
    if [ -n "${l_BMU_JSON}" ]; then
        l_msizekb=`du -sk "${l_dir}" 2>/dev/null | awk '{print $1}'`
        [ -z "${l_msizekb}" ] && l_msizekb=0
        l_hsizekb="null"
        if [ -d "${l_bp}" ]; then
            l_hsizeval=`du -sk "${l_bp}" 2>/dev/null | awk '{print $1}'`
            [ -n "${l_hsizeval}" ] && l_hsizekb="${l_hsizeval}"
        fi
        l_lastrunjson="null"
        if [ "${l_lastrun}" != "-" ]; then
            l_lastrunjson="\"`bmuJsonEscape \"${l_lastrun}\"`\""
        fi
        l_lastchgjson="null"
        [ -n "${l_lastchgraw}" ] && l_lastchgjson="\"${l_lastchgraw}\""
        l_pesc=`bmuJsonEscape "${l_prj}"`
        l_obj="{\"name\":\"${l_pesc}\",\"last_run\":${l_lastrunjson},\"last_change\":${l_lastchgjson},\"snapshot_count\":${l_snaps},\"mirror_size_kb\":${l_msizekb},\"history_size_kb\":${l_hsizekb},\"old_layout\":${l_oldlayout}}"
        [ -n "${l_projjson}" ] && l_projjson="${l_projjson},"
        l_projjson="${l_projjson}${l_obj}"
    else
        l_msize=`du -sh "${l_dir}" 2>/dev/null | awk '{print $1}'`
        l_hsize="-"
        if [ -d "${l_bp}" ]; then
            l_hsize=`du -sh "${l_bp}" 2>/dev/null | awk '{print $1}'`
        fi
        printf "%-24s %-20s %-20s %10s %8s %8s%s\n" \
            "${l_prj}" "${l_lastrun}" "${l_lastchg}" "${l_snaps}" \
            "${l_msize}" "${l_hsize}" "${l_note}"
    fi;
done
if [ -n "${l_BMU_JSON}" ]; then
    l_sync_esc=`bmuJsonEscape "${BMU_DIRRSYNC}"`
    l_hist_esc=`bmuJsonEscape "${BMU_DIRBACKUPS}"`
    printf '{"sync_dir":"%s","history_dir":"%s","projects":[%s]}\n' \
        "${l_sync_esc}" "${l_hist_esc}" "${l_projjson}"
else
    if [ ${l_found} -eq 0 ]; then
        echo "(no projects found in ${BMU_DIRRSYNC})"
    fi
fi
