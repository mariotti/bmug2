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

#Define a rsync backup dir. It is new at each time we run up to mydate granularity
l_BMU_DIRBKUP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate}"
l_BMU_OPTBKUP=" --backup-dir=${l_BMU_DIRBKUP}"
#
rsync ${BMU_OPTRSYNC} ${l_BMU_OPTBKUP} ${l_BMU_TOBACKUP} ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}
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
if [ -d ${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate} ]; then
#    ${BMU_CMDUPDATEDB} --output=${BMU_DIRDBLOCATE}/.locate.db.${l_BMU_PRJDIR}.${mydate} --localpaths="${l_BMU_DIRBKUP}"  --netpaths="${l_BMU_DIRBKUP}"
    ${BMU_CMDUPDATEDB} --output=${BMU_DIRDBLOCATE}/.locate.db.${l_BMU_PRJDIR}.${mydate} ${BMU_UPDBOPT}"${l_BMU_DIRBKUP}"
fi
#
