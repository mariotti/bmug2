#! /bin/sh
#
# Archive old B-<date> snapshots: compress each to B-<date>.tar.gz and
# remove the directory, keeping the uncompressed B-<date>.filelist next
# to it so the snapshot stays searchable (backmeup.locate.sh greps the
# filelists of archived snapshots) with no special software at all.
#
#   usage: backmeup.archive.sh [-n|--dry-run] <project> [days]
#
# Snapshots strictly older than <days> (default 180) are archived. The
# age comes from the B-YYYYMMDD-HHMMSS name itself, not from file
# mtimes. A tarball is only kept, and the directory only removed, after
# verifying the tar entry count against the directory.
#
# Restore with: backmeup.unarchive.sh <project> <snapshot>
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
# Parsing options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="yes"
    shift
fi;
if [ -z "$1" ]; then
    echo "usage: backmeup.archive.sh [-n|--dry-run] <project> [days]"
    echo "  Compress B-<date> snapshots older than <days> (default 180)"
    echo "  to .tar.gz, keeping the .filelist for searching."
    exit 1;
fi;
l_BMU_PRJDIR=`basename "${1}"`
l_BMU_DAYS="${2:-180}"
case "${l_BMU_DAYS}" in
    *[!0-9]*) echo "ERROR: days must be a number, got: ${l_BMU_DAYS}"; exit 1;;
esac
l_BMU_BP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
if [ ! -d "${l_BMU_BP}" ]; then
    echo "ERROR: no history for ${l_BMU_PRJDIR} in ${BMU_DIRBACKUPS}"
    exit 1
fi;
#
# Cutoff timestamp, BSD date first, GNU date as fallback. The snapshot
# names sort chronologically as strings, so a string compare against
# the cutoff in the same format is all we need.
l_BMU_CUTOFF=`date -v-"${l_BMU_DAYS}"d "+%Y%m%d-%H%M%S" 2>/dev/null` || true
if [ -z "${l_BMU_CUTOFF}" ]; then
    l_BMU_CUTOFF=`date -d "-${l_BMU_DAYS} days" "+%Y%m%d-%H%M%S" 2>/dev/null`
fi;
if [ -z "${l_BMU_CUTOFF}" ]; then
    echo "ERROR: cannot compute the cutoff date on this system."
    exit 1
fi;
#
echo "Archiving ${l_BMU_PRJDIR} snapshots older than ${l_BMU_DAYS} days (before ${l_BMU_CUTOFF})"
l_BMU_COUNT=0
for l_dir in "${l_BMU_BP}"/B-*/; do
    [ -d "${l_dir}" ] || continue
    l_name=`basename "${l_dir}"`
    l_stamp="${l_name#B-}"
    # expr string compare: 1 when strictly older than the cutoff
    # (test's < operator is not available in all /bin/sh implementations)
    if [ "`expr "${l_stamp}" \< "${l_BMU_CUTOFF}"`" != "1" ]; then
        continue
    fi;
    #
    # make sure the searchable filelist exists before the dir goes away
    if [ ! -f "${l_BMU_BP}/${l_name}.filelist" ]; then
        ( cd "${BMU_DIRBACKUPS}" && \
          find "${l_BMU_PRJDIR}/${l_name}" > "${l_BMU_PRJDIR}/${l_name}.filelist" )
    fi;
    #
    if [ -n "${l_BMU_DRYRUN}" ]; then
        l_size=`du -sh "${l_dir}" 2>/dev/null | awk '{print $1}'`
        echo "would archive ${l_name} (${l_size})"
        l_BMU_COUNT=`expr ${l_BMU_COUNT} + 1`
        continue
    fi;
    #
    # tar to a .part file, verify, then commit and remove the directory
    if ! ( cd "${l_BMU_BP}" && tar -czf "${l_name}.tar.gz.part" "${l_name}" ); then
        echo "ERROR: tar failed for ${l_name}, snapshot left untouched."
        rm -f "${l_BMU_BP}/${l_name}.tar.gz.part"
        exit 1
    fi;
    l_ntar=`tar -tzf "${l_BMU_BP}/${l_name}.tar.gz.part" | wc -l | tr -d ' '`
    l_ndir=`find "${l_dir%/}" | wc -l | tr -d ' '`
    if [ "${l_ntar}" != "${l_ndir}" ]; then
        echo "ERROR: verification failed for ${l_name} (tar ${l_ntar} entries, dir ${l_ndir}),"
        echo "snapshot left untouched."
        rm -f "${l_BMU_BP}/${l_name}.tar.gz.part"
        exit 1
    fi;
    mv "${l_BMU_BP}/${l_name}.tar.gz.part" "${l_BMU_BP}/${l_name}.tar.gz" && \
        rm -rf "${l_dir%/}"
    echo "archived ${l_name} -> ${l_name}.tar.gz (${l_ntar} entries verified)"
    l_BMU_COUNT=`expr ${l_BMU_COUNT} + 1`
done
if [ ${l_BMU_COUNT} -eq 0 ]; then
    echo "No snapshots older than ${l_BMU_DAYS} days."
elif [ -n "${l_BMU_DRYRUN}" ]; then
    echo "DRY RUN: ${l_BMU_COUNT} snapshot(s) would be archived, nothing was changed."
else
    echo "${l_BMU_COUNT} snapshot(s) archived."
fi;
