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
# Set up the current date
mydate=`date +%Y%m%d-%H%M%S`

# Parsing options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="--dry-run"
    shift
fi;
if [ -z "$1" ]; then
    echo "usage: backmeup.sh [-n|--dry-run] <dir>"
    echo "  -n, --dry-run   show what would be copied, deleted and archived"
    echo "                  without changing anything"
    exit 1;
fi;
#Remove trailing / It creates a project directory
l_BMU_TOBACKUP="`dirname \"$1\"`/`basename \"$1\"`"
l_BMU_PRJDIR=`basename "${1}"`

#Refuse to run without a usable rsync (openrsync drops --delete with --backup)
if [ -z "${BMU_CMDRSYNC}" ]; then
    echo "ERROR: no usable rsync found. Apple's openrsync ignores --delete"
    echo "when --backup is active, so deleted files would never be backed up."
    echo "Install a real rsync, e.g.: brew install rsync"
    exit 1
fi;

#Old (pre-bmug2) layout detection: the mirror used to live one level deeper
#(sync/<project>/<project>). Running the fixed layout against it would archive
#the whole old mirror into today's B- dir and re-transfer everything, so
#refuse and point to the migration script instead. If the source project
#really contains a same-named subdirectory we cannot tell the layouts apart;
#that legitimate case also has ${l_BMU_TOBACKUP}/${l_BMU_PRJDIR} and passes.
if [ -d "${BMU_DIRRSYNC}/${l_BMU_PRJDIR}/${l_BMU_PRJDIR}" ] && \
   [ ! -e "${l_BMU_TOBACKUP}/${l_BMU_PRJDIR}" ]; then
    echo "ERROR: old bmu layout detected: ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}/${l_BMU_PRJDIR}"
    echo "bmug2 mirrors the project directly in ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}."
    echo "Migrate once (instant rename, no re-transfer):"
    echo "  ${BMU_PATH}/backmeup.migrate.sh ${l_BMU_PRJDIR}"
    exit 1
fi;

#Define a rsync backup dir. It is new at each time we run up to mydate granularity
l_BMU_DIRBKUP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate}"
#Pre-create the project level: rsync (>=3.4) fails delete-phase backups with
#"File exists" when the --backup-dir path has 2+ missing components. With the
#project dir in place only B-${mydate} is missing, which rsync handles fine,
#and the dir-exists checks below still tell whether anything was backed up.
if [ -z "${l_BMU_DRYRUN}" ]; then
    mkdir -p "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
fi;
#
#Trailing slash on the source: mirror the project content directly into
#${BMU_DIRRSYNC}/<project> instead of the old nested <project>/<project>
${BMU_CMDRSYNC} ${l_BMU_DRYRUN} ${BMU_OPTRSYNC} --backup-dir="${l_BMU_DIRBKUP}" \
    "${l_BMU_TOBACKUP}/" "${BMU_DIRRSYNC}/${l_BMU_PRJDIR}"
l_BMU_RSYNCRC=$?
#
#In a dry run rsync only reported what it would do: skip the filelist and
#the indexing, which key off a backup dir that was never created.
if [ -n "${l_BMU_DRYRUN}" ]; then
    echo ""
    echo "DRY RUN: no files were copied, deleted, archived or indexed."
    exit 0
fi;
#
#Record the last successful run for backmeup.status.sh. Kept outside the
#mirror on purpose: anything inside it would be deleted (and archived!) by
#the next --delete run. Written as text because reading a file's mtime
#portably (BSD vs GNU date/stat) is not worth the trouble.
if [ ${l_BMU_RSYNCRC} -eq 0 ]; then
    date "+%Y-%m-%d %H:%M:%S" > "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/.bmulastrun"
fi;
#
# Create List Files
if [ -d "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate}" ]; then
  cd "${BMU_DIRBACKUPS}"
  find "${l_BMU_PRJDIR}/B-${mydate}" > "${l_BMU_PRJDIR}/B-${mydate}.filelist"
  cd - > /dev/null
fi;
#
# Live filelist: a plain `find` over the just-updated mirror, refreshed on
# every successful run - not the slow full `bmu updatedb`/cron reindex,
# which can be a day away. Without this, a file backed up seconds ago
# is invisible to backmeup.locate.sh until that next full reindex
# happens, since the index it queries (.locate.db) is only ever built by
# backmeup.updatedb.sh, never incrementally by this script. Same
# zero-dependency "grep a plain filelist" trick already used for
# archived snapshots below, just for the live mirror instead of history.
if [ ${l_BMU_RSYNCRC} -eq 0 ]; then
    ( cd "${BMU_DIRRSYNC}" && find "${l_BMU_PRJDIR}" > "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}.filelist" )
fi;
#
### END OF RSYNC JOB ###
#
#Exit with rsync's own status: a cron job checking $? should see a real
#rsync failure, not the unrelated exit code of whichever "if" ran last
#(POSIX: an if/elif with no branch taken exits 0, masking rsync's rc).
exit ${l_BMU_RSYNCRC}
