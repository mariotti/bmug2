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
#
# --replicate-backend=/--replicate-remote-sync=/--replicate-remote-backups=/
# --replicate-proton-remote= are gated independently of the four
# directory flags above (BMU_CLI_REPLICATE_FLAGGED, not
# BMU_NONINTERACTIVE) - see the replication section below for why: a
# directory-flagged call with no --replicate-backend= must keep
# skipping replication exactly as before (e.g. the GUI's install flow,
# which always passes all four directory flags and has never offered
# replication setup), while a --replicate-backend= call with no
# directory flags (the GUI's reconfigure-replication-only use case)
# must still prompt interactively for anything directory-related.
BMU_CLI_DIRRSYNC=""
BMU_CLI_DIRBACKUPS=""
BMU_CLI_DIRDBLOCATE=""
BMU_CLI_INSTDIR=""
BMU_CLI_REPLICATE_BACKEND=""
BMU_CLI_REPLICATE_REMOTE_SYNC=""
BMU_CLI_REPLICATE_REMOTE_BACKUPS=""
BMU_CLI_REPLICATE_PROTON_REMOTE=""
for l_bmu_arg in "$@"; do
    case "$l_bmu_arg" in
        --sync-dir=*)                 BMU_CLI_DIRRSYNC="${l_bmu_arg#--sync-dir=}" ;;
        --backup-dir=*)               BMU_CLI_DIRBACKUPS="${l_bmu_arg#--backup-dir=}" ;;
        --index-dir=*)                BMU_CLI_DIRDBLOCATE="${l_bmu_arg#--index-dir=}" ;;
        --install-dir=*)              BMU_CLI_INSTDIR="${l_bmu_arg#--install-dir=}" ;;
        --replicate-backend=*)        BMU_CLI_REPLICATE_BACKEND="${l_bmu_arg#--replicate-backend=}" ;;
        --replicate-remote-sync=*)    BMU_CLI_REPLICATE_REMOTE_SYNC="${l_bmu_arg#--replicate-remote-sync=}" ;;
        --replicate-remote-backups=*) BMU_CLI_REPLICATE_REMOTE_BACKUPS="${l_bmu_arg#--replicate-remote-backups=}" ;;
        --replicate-proton-remote=*)  BMU_CLI_REPLICATE_PROTON_REMOTE="${l_bmu_arg#--replicate-proton-remote=}" ;;
        *)
            echo "ERROR: unrecognized argument: $l_bmu_arg" >&2
            exit 1
            ;;
    esac
done
# Any DIRECTORY flag given at all switches the whole run non-interactive:
# the optional replication prompt below is skipped too (rather than left
# to bmuPromptyN's EOF-safe decline), since a flag-driven caller has no
# tty to ask on. This is unchanged from before --replicate-backend=
# existed - see above for why replication has its own, separate gate.
BMU_NONINTERACTIVE=""
if [ -n "$BMU_CLI_DIRRSYNC" ] || [ -n "$BMU_CLI_DIRBACKUPS" ] || [ -n "$BMU_CLI_DIRDBLOCATE" ] \
   || [ -n "$BMU_CLI_INSTDIR" ]; then
    BMU_NONINTERACTIVE="yes"
fi
BMU_CLI_REPLICATE_FLAGGED=""
if [ -n "$BMU_CLI_REPLICATE_BACKEND" ]; then
    BMU_CLI_REPLICATE_FLAGGED="yes"
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
BMU_VERSION="2.15.3"
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
# it to wherever the actual backup disk is (external drive, NAS, cloud)
# - see docs/DESTINATIONS.md. Opt-in, skipped entirely if neither backend
# tool is installed; re-run backmeup.configure.sh later to enable it once
# one is available. Two backends, mutually exclusive per install:
#   rclone   - mirrors SYNC and HISTORY to any rclone remote
#   proton   - uploads HISTORY only, natively, to Proton Drive (no SYNC
#              leg - see backmeup.replicate.proton.sh)
#
# Deliberately NOT reset to empty here before branching (a real, shipped
# bug fixed by removing that reset - confirmed live: a non-interactive
# reconfigure with only directory flags and no --replicate-backend= used
# to silently wipe an already-configured backend back to empty, since
# every branch below used to inherit that reset including the two
# "skip" branches and the interactive decline). Each branch that
# actually CHANGES the backend now explicitly sets/clears every one of
# these six vars itself; every branch that means "leave it alone" does
# nothing to them at all, so sourcing backmeup.setup.sh above - which
# already populated these vars with the real existing config, or the
# template's empty defaults for a fresh install - is what wins.
echo ""
echo "Optional: bmug2 can automate copying SYNC/HISTORY to an off-site"
echo "destination (S3, Google Drive, a remote host, Proton Drive, etc.),"
echo "on top of the local versioning above - see docs/DESTINATIONS.md"
echo "for the full picture."
echo ""
bmuDetectRclone
bmuDetectProton
if [ -n "${BMU_CLI_REPLICATE_FLAGGED}" ]; then
    case "${BMU_CLI_REPLICATE_BACKEND}" in
        none)
            BMU_REPLICATE_BACKEND=""
            BMU_CMDREPLICATE=""
            BMU_REPLICATE_REMOTE_SYNC=""
            BMU_REPLICATE_REMOTE_BACKUPS=""
            BMU_REPLICATE_PROTON_BIN=""
            BMU_REPLICATE_PROTON_REMOTE=""
            echo "Off-site replication disabled (--replicate-backend=none)."
            ;;
        rclone)
            if [ -z "${BMU_CMDRCLONE}" ]; then
                echo "ERROR: --replicate-backend=rclone given but no rclone was detected on this machine." >&2
                echo "  Install it (e.g. brew/apt install rclone) and re-run." >&2
                exit 1
            fi
            if [ -z "${BMU_CLI_REPLICATE_REMOTE_SYNC}" ] || [ -z "${BMU_CLI_REPLICATE_REMOTE_BACKUPS}" ]; then
                echo "ERROR: --replicate-backend=rclone requires both --replicate-remote-sync= and --replicate-remote-backups=." >&2
                exit 1
            fi
            BMU_REPLICATE_PROTON_BIN=""
            BMU_REPLICATE_PROTON_REMOTE=""
            BMU_REPLICATE_BACKEND="rclone"
            BMU_CMDREPLICATE="${BMU_CMDRCLONE} sync"
            BMU_REPLICATE_REMOTE_SYNC="${BMU_CLI_REPLICATE_REMOTE_SYNC}"
            BMU_REPLICATE_REMOTE_BACKUPS="${BMU_CLI_REPLICATE_REMOTE_BACKUPS}"
            echo "Off-site replication configured (rclone, non-interactive)."
            ;;
        proton)
            if [ -z "${BMU_CMDPROTON}" ]; then
                echo "ERROR: --replicate-backend=proton given but no proton-drive was detected on this machine." >&2
                echo "  Install it (proton.me/download/drive/cli) and re-run." >&2
                exit 1
            fi
            BMU_CMDREPLICATE=""
            BMU_REPLICATE_REMOTE_SYNC=""
            BMU_REPLICATE_REMOTE_BACKUPS=""
            BMU_REPLICATE_BACKEND="proton"
            BMU_REPLICATE_PROTON_BIN="${BMU_CMDPROTON}"
            BMU_REPLICATE_PROTON_REMOTE="${BMU_CLI_REPLICATE_PROTON_REMOTE:-/bmug2/`hostname -s 2>/dev/null`}"
            echo "Off-site replication configured (proton, HISTORY only, non-interactive)."
            ;;
        *)
            echo "ERROR: --replicate-backend= must be rclone, proton, or none (got: ${BMU_CLI_REPLICATE_BACKEND})" >&2
            exit 1
            ;;
    esac
elif [ -n "${BMU_NONINTERACTIVE}" ]; then
    echo "Non-interactive run: skipping optional replication setup."
    echo "  Re-run backmeup.configure.sh interactively later to enable it."
elif [ -z "${BMU_CMDRCLONE}" ] && [ -z "${BMU_CMDPROTON}" ]; then
    echo "No rclone or proton-drive detected - skipping replication setup."
    echo "  Install one later (e.g. brew/apt install rclone, or download"
    echo "  proton-drive from proton.me/download/drive/cli) and re-run"
    echo "  backmeup.configure.sh to enable this."
elif bmuPromptyN "Set up off-site replication now (y/N)?"; then
    l_bmu_backend_choice="1"
    if [ -n "${BMU_CMDRCLONE}" ] && [ -n "${BMU_CMDPROTON}" ]; then
        echo "Two replication backends are available:"
        echo "  1) rclone  - mirrors SYNC and HISTORY to any rclone remote"
        echo "  2) proton  - uploads HISTORY only, natively, to Proton Drive"
        echo "               (SYNC is not replicated by this backend yet)"
        while bmuPromptValue "Which backend (1=rclone, 2=proton)?" "l_bmu_backend_choice" "n"
        do
            echo "Please answer 1 or 2."
        done
    elif [ -z "${BMU_CMDRCLONE}" ]; then
        l_bmu_backend_choice="2"
        echo "Only proton-drive detected - using it (HISTORY only)."
    else
        echo "Only rclone detected - using it."
    fi;
    case "${l_bmu_backend_choice}" in
        2)
            BMU_CMDREPLICATE=""
            BMU_REPLICATE_REMOTE_SYNC=""
            BMU_REPLICATE_REMOTE_BACKUPS=""
            BMU_REPLICATE_BACKEND="proton"
            BMU_REPLICATE_PROTON_BIN="${BMU_CMDPROTON}"
            BMU_REPLICATE_PROTON_REMOTE="/bmug2/`hostname -s 2>/dev/null`"
            while bmuPromptValue "Proton Drive remote path for HISTORY: (${BMU_REPLICATE_PROTON_REMOTE})" "BMU_REPLICATE_PROTON_REMOTE" "n"
            do
                echo "Empty input: replication needs a destination path."
            done
            echo "Off-site (Proton Drive, HISTORY only) replication configured."
            echo "Run backmeup.replicate.proton.sh to upload new snapshots."
            echo "NOTE: SYNC is NOT replicated by this backend - see docs/DESTINATIONS.md."
            ;;
        *)
            BMU_REPLICATE_PROTON_BIN=""
            BMU_REPLICATE_PROTON_REMOTE=""
            BMU_REPLICATE_BACKEND="rclone"
            BMU_CMDREPLICATE="${BMU_CMDRCLONE} sync"
            while bmuPromptValue "Please type the remote SYNC destination (e.g. remote:bucket/path):" "BMU_REPLICATE_REMOTE_SYNC" "n"
            do
                echo "Empty input: replication needs a destination."
            done
            while bmuPromptValue "Please type the remote BackUp destination (e.g. remote:bucket/path-BP):" "BMU_REPLICATE_REMOTE_BACKUPS" "n"
            do
                echo "Empty input: replication needs a destination."
            done
            echo "Off-site replication configured. Run backmeup.replicate.sh to sync."
            ;;
    esac
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
 BMU_REPLICATE_REMOTE_BACKUPS \
 BMU_REPLICATE_BACKEND \
 BMU_REPLICATE_PROTON_BIN \
 BMU_REPLICATE_PROTON_REMOTE;
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
