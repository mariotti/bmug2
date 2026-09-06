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
#
${BMU_CMDLOCATE} -i -d ${BMU_DIRDBLOCATE}/.locate.db ${@:1}
${BMU_CMDLOCATE} -i -d ${BMU_DIRDBLOCATE}/.locate.dbb ${@:1}
#
# NOTES
#
# The funny thing is that, because of the locate.db format, and
# our choosen date format and directory structure,
# the results appears already ordered by date.
#
# TODO
# Check to exclude the -d option from this particular
# version of locate. As it makes little sense to allow it.
# For specific searches (when we might need the -d option)
# we can use directly the original "locate" command.
# An exception is to provide facilites for a future GUI.
# But in that case we create the specific facility.
#
