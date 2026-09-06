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
. ${BMU_PATH}/backmeup.setup.sh
#
# Set up the current date
mydate=`date +%Y%m%d-%H%M%S`

# Parsing the one option
if [ -z $1 ]; then
    echo "please give a dir name."
    exit 1;
fi;
#Remove trailing / It creates a project directory
l_BMU_TOBACKUP=`dirname $1`/`basename $1`
l_BMU_PRJDIR=`basename ${1}`

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
l_BMU_OPTBKUP=" --backup-dir=${l_BMU_DIRBKUP}"
#Pre-create the project level: rsync (>=3.4) fails delete-phase backups with
#"File exists" when the --backup-dir path has 2+ missing components. With the
#project dir in place only B-${mydate} is missing, which rsync handles fine,
#and the dir-exists checks below still tell whether anything was backed up.
mkdir -p "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
#
#Trailing slash on the source: mirror the project content directly into
#${BMU_DIRRSYNC}/<project> instead of the old nested <project>/<project>
${BMU_CMDRSYNC} ${BMU_OPTRSYNC} ${l_BMU_OPTBKUP} ${l_BMU_TOBACKUP}/ ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}
#
# Create List Files
if [ -d ${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate} ]; then
  cd ${BMU_DIRBACKUPS}
  find ${l_BMU_PRJDIR}/B-${mydate} > ${l_BMU_PRJDIR}/B-${mydate}.filelist
  cd -
fi;
#
### END OF RSYNC JOB ###
#
# INDEXING
# Add Eventual changed files
if [ -z "${BMU_CMDUPDATEDB}" ]; then
    echo "WARNING: no updatedb found, skipping indexing."
    echo "  Search still works via the .filelist files."
    echo "  Install GNU findutils (macOS: brew install findutils)"
elif [ -d ${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate} ]; then
#    ${BMU_CMDUPDATEDB} --output=${BMU_DIRDBLOCATE}/.locate.db.${l_BMU_PRJDIR}.${mydate} --localpaths="${l_BMU_DIRBKUP}"  --netpaths="${l_BMU_DIRBKUP}"
    ${BMU_CMDUPDATEDB} --output=${BMU_DIRDBLOCATE}/.locate.db.${l_BMU_PRJDIR}.${mydate} ${BMU_UPDBOPT}"${l_BMU_DIRBKUP}"
fi
#
