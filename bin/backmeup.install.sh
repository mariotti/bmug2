#! /bin/sh
#
# Detect command path
# -------------------
# From: http://stackoverflow.com/questions/630372/determine-the-path-of-the-executing-bash-script
# My version was a bit more "rude" ;)
# But indeed this version might not detect symlinks.
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
# Source BMU functions
# --------------------
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# SETUP
if [ -f "${BMU_PATH}/backmeup.setup.sh" ];
then
    . "${BMU_PATH}/backmeup.setup.sh"
    echo "Read existing setup file."
else
    . "${BMU_PATH}/backmeup.setup.sh.template"
    echo "Installing a new system without existing configuration."
fi
echo ""
#
echo "You are installing BMU from: ${BMU_PATH}"
#
echo "${BMU_PATH}/backmeup.configure.sh will run and ask you few questions for installation."
"${BMU_PATH}/backmeup.configure.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: configuration did not complete, installation aborted."
    exit 1
fi;
#
# Reread the setup file configure.sh just wrote. It ran as a subprocess,
# so whatever it interactively chose (including a custom BMU_INSTDIR)
# never propagates back to this shell on its own - without this re-read,
# the cp below would silently use the stale default sourced at the top
# of this script instead of what the user actually just chose.
if [ -f "${BMU_PATH}/backmeup.setup.sh" ];
then
    . "${BMU_PATH}/backmeup.setup.sh"
else
    echo "ERROR: backmeup.setup.sh was not created by configure.sh."
    exit 1
fi;
#
# Copy command files
cp -rp "${BMU_PATH}/" "${BMU_INSTDIR}/bin"
#
# Create check file
touch "${BMU_DIRRSYNC}/.bmumeta"
touch "${BMU_DIRBACKUPS}/.bmumeta"
#
# END
