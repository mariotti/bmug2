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
# Parsing the one option
if [ -z $1 ]; then
    echo "please give a project dir.date name."
    exit 1;
fi;
#
BMUPRJDATE=${1}
#
# TOCHECK, was not working before
##${BMU_CMDUPDATEDB} --output=${BMU_DIRDBLOCATE}/.locate.db.${BMUPRJDATE} ${BMU_UPDBOPT}"${DIRBKUP}"
