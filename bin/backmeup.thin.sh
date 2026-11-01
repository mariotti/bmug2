#! /bin/sh
#
# Thin out old B-<stamp> snapshots using a time-bucket retention
# policy (borg prune / restic forget style). Opt-in: with every
# BMU_KEEP_* empty, this script exits 0 without touching anything.
#
#   usage: backmeup.thin.sh -n|--dry-run <project>
#
# ONLY the dry-run path is implemented in this PR. The destructive
# fold-merge + tail-delete half (plan PR 2) lands next; invoking
# this script without -n refuses rather than silently falling back
# to dry-run, so neither a future user nor a future test can quietly
# assume thinning works yet when it doesn't.
#
# Policy (each empty = rule off; "all" allowed for yearly):
#   BMU_KEEP_HOURLY   last N hourly buckets that have a snapshot
#   BMU_KEEP_DAILY    same, daily
#   BMU_KEEP_WEEKLY   same, weekly (Monday-aligned, computed in UTC)
#   BMU_KEEP_MONTHLY  same, monthly
#   BMU_KEEP_YEARLY   same, yearly; "all" = unlimited
#   BMU_KEEP_MIN      hard floor on total kept snapshots
#
# Keep set = union over all rules. Dry-run prints one line per
# snapshot (newest first) with its disposition - "keep (hourly,
# daily)", "merge -> B-<stamp>", "delete (tail)", "keep (archived)",
# "keep (KEEP_MIN)", "keep (newest)" - then a summary.
#
# Detect command path
# -------------------
# From: http://stackoverflow.com/questions/630372/determine-the-path-of-the-executing-bash-script
#
MY_PATH="`dirname \"$0\"`"              # relative
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"  # absolutized and normalized
if [ -z "$MY_PATH" ] ; then
  exit 1  # fail
fi
BMU_PATH=${MY_PATH}
#
# SETUP
. "${BMU_PATH}/backmeup.shellfunctions.sh"
. "${BMU_PATH}/backmeup.setup.sh"
#
# Parse options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="yes"
    shift
fi
if [ -z "$1" ]; then
    echo "usage: backmeup.thin.sh -n|--dry-run <project>"
    echo "  Dry-run preview of time-bucket retention thinning. Reads the"
    echo "  BMU_KEEP_* policy from backmeup.setup.sh; with every BMU_KEEP_*"
    echo "  empty, exits 0 without doing anything."
    exit 1
fi
if [ -z "${l_BMU_DRYRUN}" ]; then
    echo "ERROR: destructive thinning is not yet implemented in this release."
    echo "  Re-run with -n (or --dry-run) to preview what thinning would do;"
    echo "  the fold-merge + tail-delete step is planned for the next PR."
    exit 1
fi
l_BMU_PRJDIR=`basename "${1}"`
l_BMU_BP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
if [ ! -d "${l_BMU_BP}" ]; then
    echo "ERROR: no history for ${l_BMU_PRJDIR} in ${BMU_DIRBACKUPS}"
    exit 1
fi
#
# Validate each BMU_KEEP_* value - empty / positive integer / "all"
# (yearly only). Reject anything else before taking the lock so a
# typo doesn't silently become "rule off" without warning.
l_bmu_check_keep() {
    # $1 = var name, $2 = value, $3 = "all-allowed" or ""
    if [ -z "$2" ]; then return 0; fi
    if [ "$2" = "all" ]; then
        if [ "$3" = "all-allowed" ]; then return 0; fi
        echo "ERROR: '$1=\"$2\"' is not valid; 'all' is only allowed for BMU_KEEP_YEARLY." >&2
        return 1
    fi
    case "$2" in
        *[!0-9]*|'')
            echo "ERROR: '$1=\"$2\"' is not valid; must be empty, a positive integer, or (yearly) 'all'." >&2
            return 1 ;;
    esac
    if [ "$2" -le 0 ]; then
        echo "ERROR: '$1=\"$2\"' is not valid; must be at least 1." >&2
        return 1
    fi
    return 0
}
l_bmu_check_keep "BMU_KEEP_HOURLY"  "${BMU_KEEP_HOURLY}"  ""           || exit 1
l_bmu_check_keep "BMU_KEEP_DAILY"   "${BMU_KEEP_DAILY}"   ""           || exit 1
l_bmu_check_keep "BMU_KEEP_WEEKLY"  "${BMU_KEEP_WEEKLY}"  ""           || exit 1
l_bmu_check_keep "BMU_KEEP_MONTHLY" "${BMU_KEEP_MONTHLY}" ""           || exit 1
l_bmu_check_keep "BMU_KEEP_YEARLY"  "${BMU_KEEP_YEARLY}"  "all-allowed"|| exit 1
l_bmu_check_keep "BMU_KEEP_MIN"     "${BMU_KEEP_MIN}"     ""           || exit 1
#
# All empty => thinning disabled. Report + exit before any lock /
# mount check: a disabled run has nothing to protect against.
if [ -z "${BMU_KEEP_HOURLY}${BMU_KEEP_DAILY}${BMU_KEEP_WEEKLY}${BMU_KEEP_MONTHLY}${BMU_KEEP_YEARLY}" ]; then
    echo "Thinning disabled (every BMU_KEEP_* is empty)."
    echo "  Set BMU_KEEP_HOURLY / DAILY / WEEKLY / MONTHLY / YEARLY in"
    echo "  backmeup.setup.sh to enable."
    exit 0
fi
#
# Same lock + mount + .bmumeta guards as backmeup.replicate.sh /
# backmeup.archive.sh. Even in dry-run: the mount check is cheap and
# catches "backup disk isn't mounted right now" before a reader
# confuses an empty mountpoint with "nothing to thin yet". The lock
# matches the pattern this project standardised on; a destructive
# PR will add nothing lock-wise.
l_BMU_LOCKDIR="${l_BMU_BP}/.bmulock"
if ! bmuAcquireLock "${l_BMU_LOCKDIR}"; then
    echo "ERROR: another bmug2 run for '${l_BMU_PRJDIR}' is already in progress."
    exit 1
fi
trap 'bmuReleaseLock "${l_BMU_LOCKDIR}"' EXIT
#
if [ -n "${BMU_DIRBACKUPS_MOUNT}" ]; then
    l_bmu_live_mount=`bmuMountPoint "${BMU_DIRBACKUPS}"`
    if [ "${l_bmu_live_mount}" != "${BMU_DIRBACKUPS_MOUNT}" ]; then
        echo "ERROR: BackUp directory ${BMU_DIRBACKUPS} is not on its configured"
        echo "filesystem (expected mount: ${BMU_DIRBACKUPS_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
        echo "  Refusing to thin - would operate on an empty mountpoint."
        exit 1
    fi
fi
if [ ! -f "${BMU_DIRBACKUPS}/.bmumeta" ]; then
    echo "ERROR: BackUp directory ${BMU_DIRBACKUPS} is missing its .bmumeta marker."
    echo "  Usually this means the backup disk isn't mounted (its mountpoint is empty)."
    echo "  Refusing to thin."
    exit 1
fi
#
# Collect snapshots: dirs AND tarballs, sorted ascending so index 0
# is oldest and last is newest. Each snapshot is written to the
# scratch file as "<stamp>|<type>" where type is "dir" or "archived".
l_BMU_SCRATCH="${SHUNIT_TMPDIR:-${TMPDIR:-/tmp}}/bmu-thin.$$"
rm -f "${l_BMU_SCRATCH}"
for l_entry in "${l_BMU_BP}"/B-*/ "${l_BMU_BP}"/B-*.tar.gz; do
    case "${l_entry}" in
        *'*') continue ;;  # unmatched glob
    esac
    if [ -d "${l_entry}" ]; then
        l_name=`basename "${l_entry}"`
        l_name="${l_name%/}"
        l_stamp="${l_name#B-}"
        echo "${l_stamp}|dir" >> "${l_BMU_SCRATCH}"
    elif [ -f "${l_entry}" ]; then
        l_name=`basename "${l_entry}"`
        l_name="${l_name%.tar.gz}"
        l_stamp="${l_name#B-}"
        echo "${l_stamp}|archived" >> "${l_BMU_SCRATCH}"
    fi
done
if [ ! -s "${l_BMU_SCRATCH}" ]; then
    echo "No snapshots to consider for ${l_BMU_PRJDIR}."
    rm -f "${l_BMU_SCRATCH}"
    exit 0
fi
# Sort ascending by stamp (chronological; stamp is lexicographically
# sortable). The pipe reads sort's output in reverse into our walk
# below so "newest first" is natural.
sort "${l_BMU_SCRATCH}" > "${l_BMU_SCRATCH}.sorted"
mv "${l_BMU_SCRATCH}.sorted" "${l_BMU_SCRATCH}"
#
# Bucket keys. All but week are string prefixes - no date math needed.
# Week needs bmuStampToEpoch + Monday-aligned math: 1970-01-01 was a
# Thursday (day 0), so adding 3 before dividing by 7 shifts the
# week boundary to Monday (day -3 = Monday 1969-12-29).
l_bmu_bucket_key() {
    # $1 = rule (hourly|daily|weekly|monthly|yearly), $2 = stamp
    case "$1" in
        hourly)  echo "${2}" | cut -c1-11 ;;   # YYYYMMDD-HH
        daily)   echo "${2}" | cut -c1-8  ;;   # YYYYMMDD
        monthly) echo "${2}" | cut -c1-6  ;;   # YYYYMM
        yearly)  echo "${2}" | cut -c1-4  ;;   # YYYY
        weekly)
            l_bmu_ep=`bmuStampToEpoch "$2"` || { echo "x_bad_stamp_$2"; return; }
            # expr for integer math; parens needed - escape for POSIX.
            echo `expr \( "${l_bmu_ep}" / 86400 + 3 \) / 7` ;;
    esac
}
#
# Walk newest -> oldest once per rule, mark each snapshot with the
# names of the rules keeping it. "keptBy|<stamp>|" + rule names
# concatenated in rule order; final rendering keeps that order.
l_BMU_KEEPSTATE="${l_BMU_SCRATCH}.keep"
: > "${l_BMU_KEEPSTATE}"
# Append-only rewrite: avoids a sed -i whose "|" separator would
# collide with the "|" bmug2 uses as the stamp/rule delimiter below
# (BSD sed on macOS reads "s|a|b|c|" as too many fields).
l_bmu_mark_kept() {
    # $1 = stamp, $2 = rule name
    l_bmu_mk_tmp="${l_BMU_KEEPSTATE}.mk"
    l_bmu_mk_found=""
    : > "${l_bmu_mk_tmp}"
    while IFS='|' read -r l_bmu_mk_s l_bmu_mk_r; do
        if [ "${l_bmu_mk_s}" = "$1" ]; then
            l_bmu_mk_found="yes"
            case ",${l_bmu_mk_r}," in
                *",$2,"*) echo "${l_bmu_mk_s}|${l_bmu_mk_r}" >> "${l_bmu_mk_tmp}" ;;
                *) echo "${l_bmu_mk_s}|${l_bmu_mk_r},$2" >> "${l_bmu_mk_tmp}" ;;
            esac
        else
            echo "${l_bmu_mk_s}|${l_bmu_mk_r}" >> "${l_bmu_mk_tmp}"
        fi
    done < "${l_BMU_KEEPSTATE}"
    if [ -z "${l_bmu_mk_found}" ]; then
        echo "$1|$2" >> "${l_bmu_mk_tmp}"
    fi
    mv "${l_bmu_mk_tmp}" "${l_BMU_KEEPSTATE}"
}
# Archived snapshots are always kept (v1 scope) and count toward
# bucket selection (occupy their buckets); mark them first so the
# per-rule walk sees them already "claimed".
while IFS='|' read -r l_stamp l_type; do
    [ "${l_type}" = "archived" ] && l_bmu_mark_kept "${l_stamp}" "archived"
done < "${l_BMU_SCRATCH}"
# The newest snapshot overall is always kept.
l_BMU_NEWEST=`tail -1 "${l_BMU_SCRATCH}" | awk -F'|' '{print $1}'`
l_bmu_mark_kept "${l_BMU_NEWEST}" "newest"
#
l_bmu_apply_rule() {
    # $1 = rule name, $2 = N (positive int or "all")
    l_bmu_rule="$1"
    l_bmu_n="$2"
    [ -z "${l_bmu_n}" ] && return 0
    l_bmu_count=0
    l_bmu_seen=""
    # Reverse the scratch (newest first) into a plain file. Reading
    # from a file redirect keeps the loop body in the parent shell;
    # a pipeline would run it in a subshell on dash/busybox, breaking
    # both the state-mutating writes to l_bmu_mark_kept's scratch
    # file (it reads/writes a separate file anyway, so that part is
    # fine) and - more importantly - the break-out-of-loop semantics
    # we want when N is reached.
    l_bmu_rev="${l_BMU_SCRATCH}.rev"
    tail -r "${l_BMU_SCRATCH}" > "${l_bmu_rev}" 2>/dev/null \
        || tac "${l_BMU_SCRATCH}" > "${l_bmu_rev}"
    while IFS='|' read -r l_stamp l_type; do
        l_bmu_key=`l_bmu_bucket_key "${l_bmu_rule}" "${l_stamp}"`
        case ",${l_bmu_seen}," in
            *",${l_bmu_key},"*) continue ;;
        esac
        l_bmu_seen="${l_bmu_seen},${l_bmu_key}"
        l_bmu_mark_kept "${l_stamp}" "${l_bmu_rule}"
        l_bmu_count=`expr "${l_bmu_count}" + 1`
        if [ "${l_bmu_n}" != "all" ] && [ "${l_bmu_count}" -ge "${l_bmu_n}" ]; then
            break
        fi
    done < "${l_bmu_rev}"
    rm -f "${l_bmu_rev}"
}
l_bmu_apply_rule hourly  "${BMU_KEEP_HOURLY}"
l_bmu_apply_rule daily   "${BMU_KEEP_DAILY}"
l_bmu_apply_rule weekly  "${BMU_KEEP_WEEKLY}"
l_bmu_apply_rule monthly "${BMU_KEEP_MONTHLY}"
l_bmu_apply_rule yearly  "${BMU_KEEP_YEARLY}"
#
# BMU_KEEP_MIN floor: if the keep set is smaller than MIN, promote
# the newest-not-yet-kept until the floor is met. Walks newest ->
# oldest so promotion follows the "closer-to-now wins ties" rule.
l_bmu_kept_count=`wc -l < "${l_BMU_KEEPSTATE}" | tr -d ' '`
l_bmu_min="${BMU_KEEP_MIN:-0}"
if [ "${l_bmu_kept_count}" -lt "${l_bmu_min}" ]; then
    l_bmu_rev="${l_BMU_SCRATCH}.rev"
    tail -r "${l_BMU_SCRATCH}" > "${l_bmu_rev}" 2>/dev/null \
        || tac "${l_BMU_SCRATCH}" > "${l_bmu_rev}"
    while IFS='|' read -r l_stamp l_type; do
        if [ "${l_bmu_kept_count}" -ge "${l_bmu_min}" ]; then break; fi
        if ! grep -q "^${l_stamp}|" "${l_BMU_KEEPSTATE}"; then
            l_bmu_mark_kept "${l_stamp}" "KEEP_MIN"
            l_bmu_kept_count=`expr "${l_bmu_kept_count}" + 1`
        fi
    done < "${l_bmu_rev}"
    rm -f "${l_bmu_rev}"
    l_bmu_kept_count=`wc -l < "${l_BMU_KEEPSTATE}" | tr -d ' '`
fi
#
# Compute oldest kept stamp for tail-vs-merge classification.
l_BMU_OLDEST_KEPT=`awk -F'|' '{print $1}' "${l_BMU_KEEPSTATE}" | sort | head -1`
#
# Report, newest first.
echo "DRY RUN - thinning preview for ${l_BMU_PRJDIR}:"
l_bmu_total=`wc -l < "${l_BMU_SCRATCH}" | tr -d ' '`
l_bmu_rev="${l_BMU_SCRATCH}.rev"
tail -r "${l_BMU_SCRATCH}" > "${l_bmu_rev}" 2>/dev/null \
    || tac "${l_BMU_SCRATCH}" > "${l_bmu_rev}"
l_bmu_lastkept=""
while IFS='|' read -r l_stamp l_type; do
    l_rules=`grep "^${l_stamp}|" "${l_BMU_KEEPSTATE}" 2>/dev/null | head -1 | awk -F'|' '{print $2}'`
    if [ -n "${l_rules}" ]; then
        # Convert "newest,hourly,daily" -> "(newest, hourly, daily)"
        l_label=`echo "${l_rules}" | sed 's/,/, /g'`
        if [ "${l_type}" = "archived" ]; then
            echo "  B-${l_stamp}  keep (${l_label}) [archived]"
        else
            echo "  B-${l_stamp}  keep (${l_label})"
        fi
        l_bmu_lastkept="${l_stamp}"
    else
        # Not kept: tail if older than oldest kept, else merge.
        if [ "`expr \"${l_stamp}\" \< \"${l_BMU_OLDEST_KEPT}\"`" = "1" ]; then
            echo "  B-${l_stamp}  delete (tail)"
        else
            # Next-newer kept = the most recent "keep" line printed above.
            echo "  B-${l_stamp}  merge -> B-${l_bmu_lastkept}"
        fi
    fi
done < "${l_bmu_rev}"
rm -f "${l_bmu_rev}"
l_bmu_keep_total=`wc -l < "${l_BMU_KEEPSTATE}" | tr -d ' '`
l_bmu_change=`expr "${l_bmu_total}" - "${l_bmu_keep_total}"`
echo ""
echo "Summary: ${l_bmu_keep_total} kept, ${l_bmu_change} would be removed (merge+tail), ${l_bmu_total} total."
echo "DRY RUN complete, nothing was changed."
rm -f "${l_BMU_SCRATCH}" "${l_BMU_KEEPSTATE}"
exit 0
