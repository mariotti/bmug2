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
. ${BMU_PATH}/backmeup.shellfunctions.sh 
#
# SETUP
if [ -f ${BMU_PATH}/backmeup.setup.sh ];
then
    . ${BMU_PATH}/backmeup.setup.sh
    echo "Previous setup file. Using: ${BMU_PATH}/backmeup.setup.sh"
else
    . ${BMU_PATH}/backmeup.setup.sh.template
    echo "No previous setup file. Using template."
fi    
#
echo "You are configuring BMU to run from: ${BMU_PATH}"
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
    if bmuMkDir ${BMU_DIRRSYNC} "empty"; then
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
    if bmuMkDir ${BMU_DIRBACKUPS} "empty"; then
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
    if bmuMkDir ${BMU_DIRDBLOCATE} "empty"; then
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
# BMU_INSTPATH
BMU_INSTPATH_TMP=${BMU_INSTPATH}
while bmuPromptValue "Please type the base INSTALL directory: (${BMU_INSTPATH_TMP})" "BMU_INSTPATH_TMP" "d"
do
    echo "not existing installation path."
    exit 1
done
BMU_INSTPATH=${BMU_INSTPATH_TMP}
echo "Install on: ${BMU_INSTPATH}"
#

#
# BMU_INSTDIR
BMU_INSTDIR_TMP=${BMU_INSTDIR}
while bmuPromptValue "Please type the BMU install directory: (${BMU_INSTDIR_TMP})" "BMU_INSTDIR_TMP" "d"
do
    echo "not valid or not existing BMU install directory: ${BMU_INSTDIR_TMP}"
    if [ -z "$BMU_INSTDIR_TMP" ] ; then
	echo "Empty input value: Exiting the configuration ..."
	exit 1
    fi
    bmuPromptyNexit "Shall I create the directory for you (y/N)?"
    export BMU_INSTDIR=${BMU_INSTDIR_TMP}
    if bmuMkDir ${BMU_INSTDIR} "empty"; then
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
BMU_CMDUPDATEDB='updatedb -l 0'
BMU_UPDBOPT='-U '
BMU_CMDLOCATE='locate'
BMU_CMDFILTER='sed'
BMU_UNAME=`uname`
#
if [ "${BMU_UNAME}a" == "Darwina" ]; then
    BMU_CMDUPDATEDB='gupdatedb'
    BMU_UPDBOPT='--localpaths='
    BMU_CMDLOCATE='glocate'
    BMU_CMDFILTER='bbe -e'
    echo "MAC DARWIN detected: using gupdatedb, glocate and bbe"
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
rm -rf ${MY_PATH}/backmeup.setup.sh.new
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
    echo "${curvar}=\"$val\"" >> ${MY_PATH}/backmeup.setup.sh.new
done
#
if [ -f ${MY_PATH}/backmeup.setup.sh ];
then
    cp ${MY_PATH}/backmeup.setup.sh ${MY_PATH}/backmeup.setup.sh.old
fi
cp ${MY_PATH}/backmeup.setup.sh.new ${MY_PATH}/backmeup.setup.sh
#
