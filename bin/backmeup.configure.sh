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
# Non-interactive flags (a GUI, or any other scripted caller, uses
# these instead of interactive prompts): --sync-dir=, --backup-dir=,
# --index-dir=, --install-dir=. Any prompt whose flag isn't given still
# prompts interactively as before - purely additive, mixing flagged and
# unflagged prompts in the same run is supported.
BMU_CLI_DIRRSYNC=""
BMU_CLI_DIRBACKUPS=""
BMU_CLI_DIRDBLOCATE=""
BMU_CLI_INSTDIR=""
for l_bmu_arg in "$@"; do
    case "$l_bmu_arg" in
        --sync-dir=*)     BMU_CLI_DIRRSYNC="${l_bmu_arg#--sync-dir=}" ;;
        --backup-dir=*)   BMU_CLI_DIRBACKUPS="${l_bmu_arg#--backup-dir=}" ;;
        --index-dir=*)    BMU_CLI_DIRDBLOCATE="${l_bmu_arg#--index-dir=}" ;;
        --install-dir=*)  BMU_CLI_INSTDIR="${l_bmu_arg#--install-dir=}" ;;
        *)
            echo "ERROR: unrecognized argument: $l_bmu_arg" >&2
            exit 1
            ;;
    esac
done
# Any flag given at all switches the whole run non-interactive: the
# optional replication prompt below is skipped too (rather than left
# to bmuPromptyN's EOF-safe decline), since a flag-driven caller has no
# tty to ask on and no UI for that prompt yet either.
BMU_NONINTERACTIVE=""
if [ -n "$BMU_CLI_DIRRSYNC" ] || [ -n "$BMU_CLI_DIRBACKUPS" ] || [ -n "$BMU_CLI_DIRDBLOCATE" ] \
   || [ -n "$BMU_CLI_INSTDIR" ]; then
    BMU_NONINTERACTIVE="yes"
fi
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
# Not sourced from the template/existing setup.sh above like everything
# else - deliberately. This must always be the version of *this*
# configure.sh, so a reconfigure doesn't keep reporting a stale value
# from whenever the install was first set up (sourcing an existing
# setup.sh above would otherwise silently win). Bump by hand alongside
# every git tag.
BMU_VERSION="2.7.0"
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
echo "These should live somewhere safe from casual deletion - but SYNC"
echo "and IndexDB in particular are meant to stay readily available, so"
echo "a local disk (even the internal one) is often the right call, not"
echo "necessarily an external drive or NAS. Want an off-site copy too?"
echo "That's a separate replication step layered on top of these, not a"
echo "replacement destination for them - see docs/DESTINATIONS.md."
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
# BMU_DIRRSYNC
bmuConfigureDir "SYNC" "BMU_DIRRSYNC" "${BMU_DIRRSYNC}" "--sync-dir" "${BMU_CLI_DIRRSYNC}"
#
# BMU_DIRBACKUPS
bmuConfigureDir "BackUp" "BMU_DIRBACKUPS" "${BMU_DIRBACKUPS}" "--backup-dir" "${BMU_CLI_DIRBACKUPS}"
#
#
# BMU_DIRDBLOCATE
# Default recomputed from the just-chosen BMU_DIRRSYNC (not simply the
# template's original value) - otherwise a custom/flagged SYNC dir is
# silently ignored here and the stale template default ("lives inside
# SYNC by default" becomes false) is suggested again. A real bug an
# earlier test caught: a flagged --sync-dir left the IndexDB prompt
# suggesting the old default location, unrelated to the SYNC dir
# actually chosen.
bmuConfigureDir "IndexDB" "BMU_DIRDBLOCATE" "${BMU_DIRRSYNC}/.locate.dir" "--index-dir" "${BMU_CLI_DIRDBLOCATE}"
#
#
# OS Options
# ----------
echo ""
echo "The next question is different: this is where the bmug2"
echo "PROGRAM itself lives, not your data. Keep it on your regular"
echo "system disk (not the backup destination above), so it still"
echo "works even when that drive isn't connected."
echo ""
#
# BMU_INSTDIR
bmuConfigureDir "BMU install" "BMU_INSTDIR" "${BMU_INSTDIR}" "--install-dir" "${BMU_CLI_INSTDIR}"
#
# Currently HARDCODED
#
# System Options
# --------------
BMU_OPTRSYNC="-av --delete --backup" # --modify-window=1
#
# rsync detection (skip Apple's openrsync: it drops --delete with --backup)
bmuDetectRsync
if [ -z "${BMU_CMDRSYNC}" ]; then
    echo "WARNING: no usable rsync found (only Apple openrsync?)."
    echo "  backmeup.sh will refuse to run. Install one: brew install rsync"
else
    echo "usable rsync detected: ${BMU_CMDRSYNC}"
fi;
#
# Index command detection (capability based, not uname based)
bmuDetectIndexer
if [ -z "${BMU_CMDUPDATEDB}" ]; then
    echo "WARNING: no updatedb found, indexing will be skipped."
    echo "  Install GNU findutils (macOS: brew install findutils)"
else
    case "${BMU_CMDUPDATEDB}" in
        gupdatedb) echo "GNU findutils detected (gupdatedb/glocate)" ;;
        updatedb)  echo "GNU findutils detected (updatedb/locate)" ;;
        *)         echo "mlocate/plocate style updatedb detected" ;;
    esac
fi;
#
# OFF-SITE REPLICATION (optional)
# --------------------------------
# A separate hop on top of the local SYNC/HISTORY versioning above: copy
# the whole tree to wherever the actual backup disk is (external drive,
# NAS, cloud) - see docs/DESTINATIONS.md. Opt-in, skipped entirely if
# rclone isn't installed; re-run backmeup.configure.sh later to enable
# it once rclone is available.
echo ""
echo "Optional: bmug2 can automate copying SYNC/HISTORY to an off-site"
echo "destination (S3, Google Drive, a remote host, etc.) via rclone,"
echo "on top of the local versioning above - see docs/DESTINATIONS.md"
echo "for the full picture."
echo ""
BMU_CMDREPLICATE=""
BMU_REPLICATE_REMOTE_SYNC=""
BMU_REPLICATE_REMOTE_BACKUPS=""
if [ -n "${BMU_NONINTERACTIVE}" ]; then
    echo "Non-interactive run: skipping optional replication setup."
    echo "  Re-run backmeup.configure.sh interactively later to enable it."
elif ! command -v rclone > /dev/null 2>&1; then
    echo "No rclone detected - skipping replication setup."
    echo "  Install it later (e.g. brew/apt install rclone) and re-run"
    echo "  backmeup.configure.sh to enable this."
elif bmuPromptyN "Set up off-site replication now (y/N)?"; then
    BMU_CMDREPLICATE="rclone sync"
    while bmuPromptValue "Please type the remote SYNC destination (e.g. remote:bucket/path):" "BMU_REPLICATE_REMOTE_SYNC" "n"
    do
        echo "Empty input: replication needs a destination."
    done
    while bmuPromptValue "Please type the remote BackUp destination (e.g. remote:bucket/path-BP):" "BMU_REPLICATE_REMOTE_BACKUPS" "n"
    do
        echo "Empty input: replication needs a destination."
    done
    echo "Off-site replication configured. Run backmeup.replicate.sh to sync."
else
    echo "Skipped. Re-run backmeup.configure.sh later to enable it."
fi
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
 BMU_VERSION \
 BMU_DIRRSYNC \
 BMU_DIRBACKUPS \
 BMU_DIRDBLOCATE \
 BMU_INSTDIR \
 BMU_OPTRSYNC \
 BMU_CMDRSYNC \
 BMU_CMDUPDATEDB \
 BMU_UPDBOPT \
 BMU_CMDLOCATE \
 BMU_CMDREPLICATE \
 BMU_REPLICATE_REMOTE_SYNC \
 BMU_REPLICATE_REMOTE_BACKUPS;
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
