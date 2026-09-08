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
# Copy command files. Only the real *.sh scripts, the resolved
# backmeup.setup.sh (which also ends in .sh), and the template (kept in
# case the installed setup.sh is ever deleted and configure.sh needs a
# starting point) - not backmeup.setup.sh.old (configure.sh's own backup
# of the previous config) or any stray backup file a hand edit might
# have left lying around. Those have no purpose in a fresh install;
# copying the whole source directory used to bring them along regardless.
mkdir -p "${BMU_INSTDIR}/bin"
cp -p "${BMU_PATH}"/*.sh "${BMU_PATH}"/*.template "${BMU_INSTDIR}/bin/"
cp -p "${BMU_PATH}"/shell-integration/* "${BMU_INSTDIR}/bin/"
#
# Create check file
touch "${BMU_DIRRSYNC}/.bmumeta"
touch "${BMU_DIRBACKUPS}/.bmumeta"
#
# Optional: offer to wire bmug2 onto PATH via the shell rc file. Never
# edits silently, never touches more than one line, safe to decline
# (does not affect this script's own exit code) and safe to run again
# later (idempotent: skips if the line is already there).
case "${SHELL}" in
    */zsh)
	l_bmu_rcfile="${HOME}/.zshrc"
	;;
    */bash)
	if [ -f "${HOME}/.bash_profile" ]; then
	    l_bmu_rcfile="${HOME}/.bash_profile"
	else
	    l_bmu_rcfile="${HOME}/.bashrc"
	fi
	;;
    *)
	l_bmu_rcfile="${HOME}/.profile"
	;;
esac
l_bmu_rcline=". \"${BMU_INSTDIR}/backmeup_shrc\""
if [ -f "${l_bmu_rcfile}" ] && grep -qF "${l_bmu_rcline}" "${l_bmu_rcfile}"; then
    echo "Shell integration already present in ${l_bmu_rcfile}, nothing to do."
else
    echo ""
    echo "bmug2 can add itself to your PATH by appending one line to:"
    echo "  ${l_bmu_rcfile}"
    echo "  ${l_bmu_rcline}"
    if bmuPromptyN "Shall I append it for you (y/N)?"; then
	printf '%s\n' "${l_bmu_rcline}" >> "${l_bmu_rcfile}"
	echo "Added. Restart your shell (or run: ${l_bmu_rcline}) to pick it up."
    else
	echo "Skipped. Add it yourself later if you want it:"
	echo "  ${l_bmu_rcline}"
    fi
fi
echo ""
echo "Once bmug2 is on your PATH, the short 'bmu' command is available"
echo "(e.g. 'bmu status', 'bmu ~/Documents'). Shell completion for it is"
echo "also available - see docs/MANUAL.md for how to turn it on."
#
# END
