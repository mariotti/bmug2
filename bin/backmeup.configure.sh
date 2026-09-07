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
# RollBack attempt
BMU_CONFIGURE_ROLLBACK=""
#
# Source BMU functions
# --------------------
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# SETUP
if [ -f "${BMU_PATH}/backmeup.setup.sh" ];
then
    . "${BMU_PATH}/backmeup.setup.sh"
    echo "Previous setup file. Using: ${BMU_PATH}/backmeup.setup.sh"
else
    . "${BMU_PATH}/backmeup.setup.sh.template"
    echo "No previous setup file. Using template."
fi
#
echo "You are configuring BMU to run from: ${BMU_PATH}"
#
echo ""
echo "The next three questions are about where your DATA goes:"
echo ""
echo "  SYNC     the live mirror - a current copy of what you back up"
echo "  BackUp   old and deleted versions, kept as your history"
echo "  IndexDB  the search index (lives inside SYNC by default)"
echo ""
echo "Point these at your actual backup destination - an external"
echo "drive, a NAS, or similar (see docs/DESTINATIONS.md for what's"
echo "supported) - not a directory you might casually delete later."
echo "The suggested default is just a starting point to edit or accept,"
echo "not a recommendation."
echo ""
#
#
# LOCAL/USER DEFINED OPTIONS
# --------------------------
# Namely: where to do the backup.
# These are defaults. If for example you want to have
# the search index always locally available please
# change this default.
#
# See also below INDEXING OPTIONS which will be introduced soon
#
# BMU_DIRRSYNC
BMU_DIRRSYNC_TMP=${BMU_DIRRSYNC}
while bmuPromptValue "Please type the SYNC directory: (${BMU_DIRRSYNC_TMP})" "BMU_DIRRSYNC_TMP" "d"
do
    echo "not valid or not existing SYNC directory: ${BMU_DIRRSYNC_TMP}"
    if [ -z "$BMU_DIRRSYNC_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_DIRRSYNC=${BMU_DIRRSYNC_TMP}
    if bmuMkDir "${BMU_DIRRSYNC}" "empty"; then
	BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_DIRRSYNC};"
	break
    else
	echo "cannot create the directory."
    fi
done
#echo "debug SYNC directory: >${BMU_DIRRSYNC}< >${BMU_DIRRSYNC_TMP}<"
BMU_DIRRSYNC=${BMU_DIRRSYNC_TMP}
echo "SYNC Directory is: ${BMU_DIRRSYNC}"
#
# BMU_DIRBACKUPS
BMU_DIRBACKUPS_TMP=${BMU_DIRBACKUPS}
while bmuPromptValue "Please type the BackUp directory: (${BMU_DIRBACKUPS_TMP})" "BMU_DIRBACKUPS_TMP" "d"
do
    echo "not valid or not existing BackUp directory: ${BMU_DIRBACKUPS_TMP}"
    if [ -z "$BMU_DIRBACKUPS_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_DIRBACKUPS=${BMU_DIRBACKUPS_TMP}
    if bmuMkDir "${BMU_DIRBACKUPS}" "empty"; then
	BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_DIRBACKUPS};"
	break
    else
	echo "cannot create the directory."
    fi
done
#echo "debug BackUp directory: >${BMU_DIRBACKUPS}< >${BMU_DIRBACKUPS_TMP}<"
BMU_DIRBACKUPS=${BMU_DIRBACKUPS_TMP}
echo "BackUp Directory is: ${BMU_DIRBACKUPS}"
#
#
# BMU_DIRDBLOCATE
BMU_DIRDBLOCATE_TMP=${BMU_DIRDBLOCATE}
while bmuPromptValue "Please type the IndexDB directory: (${BMU_DIRDBLOCATE_TMP})" "BMU_DIRDBLOCATE_TMP" "d"
do
    echo "not valid or not existing IndexDB directory: ${BMU_DIRDBLOCATE_TMP}"
    if [ -z "$BMU_DIRDBLOCATE_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_DIRDBLOCATE=${BMU_DIRDBLOCATE_TMP}
    if bmuMkDir "${BMU_DIRDBLOCATE}" "empty"; then
	BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_DIRDBLOCATE};"
	break
    else
	echo "cannot create the directory."
    fi
done
#echo "debug IndexDB directory: >${BMU_DIRDBLOCATE}< >${BMU_DIRDBLOCATE_TMP}<"
BMU_DIRDBLOCATE=${BMU_DIRDBLOCATE_TMP}
echo "IndexDB Directory is: ${BMU_DIRDBLOCATE}"
#
#
# OS Options
# ----------
#BMU_INSTPATH="/usr/local"
#BMU_INSTDIRNAME="/bmu"
#BMU_INSTDIR="${BMU_INSTPATH}${BMU_INSTDIRNAME}"
#BMU_LINKTO="/usr/local/bin/backmeup"
#
echo ""
echo "The next two questions are different: this is where the bmug2"
echo "PROGRAM itself lives, not your data. Keep it on your regular"
echo "system disk (not the backup destination above), so it still"
echo "works even when that drive isn't connected."
echo ""
#
# BMU_INSTPATH
BMU_INSTPATH_TMP=${BMU_INSTPATH}
while bmuPromptValue "Please type the base INSTALL directory: (${BMU_INSTPATH_TMP})" "BMU_INSTPATH_TMP" "d"
do
    echo "not valid or not existing installation path: ${BMU_INSTPATH_TMP}"
    if [ -z "$BMU_INSTPATH_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_INSTPATH=${BMU_INSTPATH_TMP}
    if bmuMkDir "${BMU_INSTPATH}" "empty"; then
	BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_INSTPATH};"
	break
    else
	echo "cannot create the directory."
    fi
done
BMU_INSTPATH=${BMU_INSTPATH_TMP}
echo "Install on: ${BMU_INSTPATH}"
#

#
# BMU_INSTDIR
# Recompute the suggested default from the just-chosen BMU_INSTPATH,
# rather than reusing the value the template originally expanded before
# BMU_INSTPATH was overridden - otherwise a custom install path is
# silently ignored here and the old default location is suggested again.
BMU_INSTDIR_TMP="${BMU_INSTPATH}${BMU_INSTDIRNAME}"
while bmuPromptValue "Please type the BMU install directory: (${BMU_INSTDIR_TMP})" "BMU_INSTDIR_TMP" "d"
do
    echo "not valid or not existing BMU install directory: ${BMU_INSTDIR_TMP}"
    if [ -z "$BMU_INSTDIR_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_INSTDIR=${BMU_INSTDIR_TMP}
    if bmuMkDir "${BMU_INSTDIR}" "empty"; then
	BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_INSTDIR};"
	break
    else
	echo "cannot create the directory."
    fi
done
#echo "debug IndexDB directory: >${BMU_INSTDIR}< >${BMU_INSTDIR_TMP}<"
BMU_INSTDIR=${BMU_INSTDIR_TMP}
echo "BMU install Directory is: ${BMU_INSTDIR}"
#
# Currently HARDCODED
#
# System Options
# --------------
BMU_INDEXTYPE="locate"
BMU_DATEFRMT="+%Y%m%d-%H%M%S"
BMU_mydate=`date +%Y%m%d-%H%M%S`
BMU_OPTRSYNC="-av --delete --backup" # --modify-window=1
BMU_CMDFILTER='sed'
BMU_UNAME=`uname`
#
# rsync detection (skip Apple's openrsync: it drops --delete with --backup)
# Keep in sync with backmeup.setup.sh.template
BMU_CMDRSYNC=""
for l_bmu_rsync in rsync /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
    command -v "${l_bmu_rsync}" > /dev/null 2>&1 || continue
    if "${l_bmu_rsync}" --version 2>/dev/null | head -1 | grep -qi openrsync; then
        continue
    fi
    BMU_CMDRSYNC="${l_bmu_rsync}"
    break
done
if [ -z "${BMU_CMDRSYNC}" ]; then
    echo "WARNING: no usable rsync found (only Apple openrsync?)."
    echo "  backmeup.sh will refuse to run. Install one: brew install rsync"
else
    echo "usable rsync detected: ${BMU_CMDRSYNC}"
fi;
#
# Index command detection (capability based, not uname based)
# Keep in sync with backmeup.setup.sh.template
BMU_CMDUPDATEDB=''
BMU_UPDBOPT=''
BMU_CMDLOCATE=''
if command -v gupdatedb > /dev/null 2>&1; then
    BMU_CMDUPDATEDB='gupdatedb'
    BMU_UPDBOPT='--localpaths='
    BMU_CMDLOCATE='glocate'
    echo "GNU findutils detected (gupdatedb/glocate)"
elif command -v updatedb > /dev/null 2>&1; then
    if updatedb --version 2>/dev/null | head -1 | grep -q 'GNU findutils'; then
        BMU_CMDUPDATEDB='updatedb'
        BMU_UPDBOPT='--localpaths='
        echo "GNU findutils detected (updatedb/locate)"
    else
        BMU_CMDUPDATEDB='updatedb -l 0'
        BMU_UPDBOPT='-U '
        echo "mlocate/plocate style updatedb detected"
    fi
    BMU_CMDLOCATE='locate'
else
    echo "WARNING: no updatedb found, indexing will be skipped."
    echo "  Install GNU findutils (macOS: brew install findutils)"
fi;
#
#
# INDEXING OPTIONS
# ----------------
# Not yet used. They are at present down here as we need INDEXTYPE.
# We might consider to re-sort these options
# To be implemented.
#
# The basic idea is that we can  have locally stored indexes for
# backup search when the backup disk is off-line.
BMU_MAININDEXDIR=${DIRRSYNC}
BMU_PARTINDEXDIR=${DIRRSYNC}/.locate.db.part
#
# WRITING THE SETUP FILE
#-----------------------
rm -rf "${MY_PATH}/backmeup.setup.sh.new"
echo "# Generated by backmeup.configure.sh - do not run this file directly," \
    > "${MY_PATH}/backmeup.setup.sh.new"
echo "# it is meant to be sourced (. backmeup.setup.sh) by the other bmug2" \
    >> "${MY_PATH}/backmeup.setup.sh.new"
echo "# scripts. To change these settings, re-run backmeup.configure.sh." \
    >> "${MY_PATH}/backmeup.setup.sh.new"
for curvar in \
 BMU_DIRRSYNC \
 BMU_DIRBACKUPS \
 BMU_DIRDBLOCATE \
 BMU_INSTPATH \
 BMU_INSTDIRNAME \
 BMU_INSTDIR \
 BMU_LINKTO \
 BMU_INDEXTYPE \
 BMU_DATEFRMT \
 BMU_mydate \
 BMU_OPTRSYNC \
 BMU_CMDRSYNC \
 BMU_CMDUPDATEDB \
 BMU_UPDBOPT \
 BMU_CMDLOCATE \
 BMU_CMDFILTER \
 BMU_UNAME \
 BMU_MAININDEXDIR \
 BMU_PARTINDEXDIR;
do
    val=""
    bmuSetIndirectVar "val" "$curvar"
    echo "${curvar}=\"$val\"" >> "${MY_PATH}/backmeup.setup.sh.new"
done
#
if [ -f "${MY_PATH}/backmeup.setup.sh" ];
then
    cp "${MY_PATH}/backmeup.setup.sh" "${MY_PATH}/backmeup.setup.sh.old"
fi
mv "${MY_PATH}/backmeup.setup.sh.new" "${MY_PATH}/backmeup.setup.sh"
#
# WRITING THE SHELL INTEGRATION FILE
# -----------------------------------
# Written straight to BMU_INSTDIR (not staged in the checkout like
# backmeup.setup.sh above) - it's only ever useful at the final install
# location, and by this point BMU_INSTDIR is guaranteed to already exist
# (the prompt loop above won't let it be anything else). Regenerated on
# every configure.sh run, including a bare reconfigure, so it stays
# correct if BMU_INSTDIR itself ever changes.
rm -f "${BMU_INSTDIR}/backmeup_shrc.new"
{
    echo "# backmeup_shrc - generated by backmeup.configure.sh, do not edit by hand."
    echo "# Re-run backmeup.configure.sh to regenerate (e.g. after moving the"
    echo "# install directory). Source it from your shell rc file:"
    echo "#   . \"${BMU_INSTDIR}/backmeup_shrc\""
    echo "#"
    echo "# Add bmug2's commands to PATH. Idempotent: safe to source more than"
    echo "# once, from multiple shells, or if sourced twice by mistake."
    echo "case \":\${PATH}:\" in"
    echo "    *\":${BMU_INSTDIR}/bin:\"*) ;;"
    echo "    *) PATH=\"${BMU_INSTDIR}/bin:\${PATH}\" ;;"
    echo "esac"
    echo "export PATH"
    echo "#"
    echo "# Reserved for future bmug2 environment variables. None are needed"
    echo "# today - every bmug2 script gets its configuration by sourcing"
    echo "# backmeup.setup.sh directly, not from the environment."
} > "${BMU_INSTDIR}/backmeup_shrc.new"
mv "${BMU_INSTDIR}/backmeup_shrc.new" "${BMU_INSTDIR}/backmeup_shrc"
#
