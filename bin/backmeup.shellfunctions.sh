#! /bin/sh
#
#
# bmuJsonEscape()
# Escapes backslash and double-quote for embedding a value inside a
# JSON string (backslash first, so a literal backslash in the input
# doesn't get double-escaped by the second substitution). Used by the
# --json output modes of backmeup.status.sh/backmeup.locate.sh - not a
# full JSON encoder, just enough for the plain paths/names those
# scripts ever embed.
bmuJsonEscape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
#
# bmuDetectRsync()
# Sets BMU_CMDRSYNC to the first usable rsync found on PATH or in the
# common Homebrew/system locations, always resolved to its absolute
# path via "command -v" - even a bare-name match, since none of these
# detect functions are called again at backup/index/replicate time:
# whatever string ends up here is baked verbatim into the generated
# backmeup.setup.sh and run as-is on every future invocation. Baking in
# a bare name instead of its resolved path is a real bug, confirmed
# on this machine: a normal interactive install bakes in bare "rsync";
# a cron job's minimal PATH later resolves that same bare name to
# Apple's openrsync at /usr/bin/rsync instead of the Homebrew rsync
# used at configure time - openrsync silently drops --delete under
# --backup, so a deleted source file quietly stays in the mirror
# forever, with the run still reporting exit 0. Resolving to an
# absolute path once, here, pins the exact binary verified at
# configure time regardless of what PATH looks like later.
# Apple's openrsync itself is still skipped on sight (same
# --delete-under-backup problem, whichever path it's found at). Stays
# empty if no real rsync is usable; callers warn/refuse accordingly.
# Used by backmeup.configure.sh. backmeup.setup.sh.template keeps an
# identical inline copy rather than calling this - see the comment
# there for why (it must stay sourceable without shellfunctions.sh).
# Keep both copies in sync if you change this.
bmuDetectRsync() {
    BMU_CMDRSYNC=""
    for l_bmu_rsync in rsync /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync; do
        l_bmu_resolved="$(command -v "${l_bmu_rsync}" 2>/dev/null)" || continue
        if "${l_bmu_resolved}" --version 2>/dev/null | head -1 | grep -qi openrsync; then
            continue
        fi
        BMU_CMDRSYNC="${l_bmu_resolved}"
        break
    done
}
#
# bmuDetectIndexer()
# Sets BMU_CMDUPDATEDB/BMU_UPDBOPT/BMU_CMDLOCATE based on whichever
# updatedb/locate dialect is actually installed (GNU findutils vs.
# mlocate/plocate) - capability based, not uname based: solves the old
# "gnu or bsd?" guessing game, since "locate -i -d <db> <pattern>"
# behaves the same across all of them even though the updatedb
# invocation differs. Same absolute-path resolution and fallback
# search as bmuDetectRsync (bare name, then /opt/homebrew/bin,
# /usr/local/bin, /usr/bin; whatever's found is resolved to its
# absolute path via "command -v" before being baked into
# backmeup.setup.sh, for the same reason documented on bmuDetectRsync).
# All three stay empty if no updatedb is found anywhere.
# Used by backmeup.configure.sh. backmeup.setup.sh.template keeps an
# identical inline copy rather than calling this - see the comment
# there for why (it must stay sourceable without shellfunctions.sh).
# Keep both copies in sync if you change this.
bmuDetectIndexer() {
    BMU_CMDUPDATEDB=''
    BMU_UPDBOPT=''
    BMU_CMDLOCATE=''
    for l_bmu_dir in '' /opt/homebrew/bin/ /usr/local/bin/ /usr/bin/; do
        l_bmu_gupdatedb="$(command -v "${l_bmu_dir}gupdatedb" 2>/dev/null)"
        l_bmu_updatedb="$(command -v "${l_bmu_dir}updatedb" 2>/dev/null)"
        if [ -n "${l_bmu_gupdatedb}" ]; then
            BMU_CMDUPDATEDB="${l_bmu_gupdatedb}"
            BMU_UPDBOPT='--localpaths='
            BMU_CMDLOCATE="$(command -v "${l_bmu_dir}glocate" 2>/dev/null)"
            break
        elif [ -n "${l_bmu_updatedb}" ]; then
            if "${l_bmu_updatedb}" --version 2>/dev/null | head -1 | grep -q 'GNU findutils'; then
                BMU_CMDUPDATEDB="${l_bmu_updatedb}"
                BMU_UPDBOPT='--localpaths='
            else
                BMU_CMDUPDATEDB="${l_bmu_updatedb} -l 0"
                BMU_UPDBOPT='-U '
            fi
            BMU_CMDLOCATE="$(command -v "${l_bmu_dir}locate" 2>/dev/null)"
            break
        fi
    done
}
#
# bmuDetectRclone()
# Sets BMU_CMDRCLONE to the first usable rclone found on PATH or in the
# common Homebrew/system locations, resolved to its absolute path via
# "command -v" - same reasoning as bmuDetectRsync/bmuDetectIndexer:
# BMU_CMDREPLICATE is baked in verbatim at configure time and never
# re-detected, so a bare "rclone" would silently stop resolving (or
# resolve to a different binary) the moment backmeup.replicate.sh runs
# from cron/launchd's minimal PATH instead. Stays empty if rclone isn't
# found anywhere. Used by backmeup.configure.sh only.
bmuDetectRclone() {
    BMU_CMDRCLONE=''
    for l_bmu_dir in '' /opt/homebrew/bin/ /usr/local/bin/ /usr/bin/; do
        l_bmu_resolved="$(command -v "${l_bmu_dir}rclone" 2>/dev/null)" || continue
        BMU_CMDRCLONE="${l_bmu_resolved}"
        break
    done
}
#
# bmuAcquireLock()
# $1 = lock directory path. Uses mkdir as the atomicity primitive -
# not flock/lockf, which aren't both available on every platform this
# project targets (confirmed: no flock(1) on macOS, no shlock on
# Linux) - mkdir needs no external binary and is atomic on every POSIX
# filesystem, matching the capability-based (not uname-based) approach
# already used for rsync/indexer/rclone detection above.
# On success, writes $$ into <lockdir>/pid and returns 0 - the caller
# is expected to release it via bmuReleaseLock, normally through
# `trap 'bmuReleaseLock "$dir"' EXIT` so it fires on normal exit and
# most signals.
# Stale-lock recovery: if mkdir fails because the directory already
# exists, but its pid file names a process that's no longer running
# (e.g. killed with SIGKILL, which no EXIT trap can clean up after),
# reclaim it instead of blocking forever. The reclaiming mkdir is still
# the atomic gate - if two callers both decide the lock is stale at
# the same time, only one of their post-rm mkdir calls can succeed.
# Returns 1 (caller prints its own clear error) only when the lock is
# genuinely held by a still-running process.
bmuAcquireLock() {
    l_bmu_lockdir="$1"
    if mkdir "${l_bmu_lockdir}" 2>/dev/null; then
        echo $$ > "${l_bmu_lockdir}/pid"
        return 0
    fi
    l_bmu_lockpid=''
    if [ -f "${l_bmu_lockdir}/pid" ]; then
        l_bmu_lockpid=`cat "${l_bmu_lockdir}/pid" 2>/dev/null`
    fi
    if [ -n "${l_bmu_lockpid}" ] && ! kill -0 "${l_bmu_lockpid}" 2>/dev/null; then
        echo "WARNING: removing a stale lock left by pid ${l_bmu_lockpid} (no longer running)"
        rm -rf "${l_bmu_lockdir}"
        if mkdir "${l_bmu_lockdir}" 2>/dev/null; then
            echo $$ > "${l_bmu_lockdir}/pid"
            return 0
        fi
    fi
    return 1
}
#
# bmuReleaseLock()
# $1 = lock directory path, as passed to bmuAcquireLock.
bmuReleaseLock() {
    rm -rf "$1"
}
#
# bmuConfigureDirFromFlag()
# Non-interactive counterpart to a bmuPromptValue "-d" while-loop: given
# a flag's value (already known non-empty by the caller), validates
# it's an absolute path and creates it if missing, or exits with a
# clear error - no retry loop, since a flag-driven caller has no user
# to ask again. $1=value $2=flag name (for the error message)
# $3=variable name to export the validated value into.
bmuConfigureDirFromFlag() {
    val="$1"
    flagname="$2"
    storevar="$3"
    case "$val" in
        /*) ;;
        *)
            echo "ERROR: ${flagname} must be an absolute path (starting with /): $val"
            exit 1
            ;;
    esac
    if ! bmuMkDir "$val" "y"; then
        echo "ERROR: cannot create directory for ${flagname}: $val"
        exit 1
    fi
    export $storevar="$val"
}
#
# bmuMkDir()
# This function tries to create a directory and returns the success
# of the command. The default behavior is just exactly as mkdir, but
# you can ask to force a positive response if the directory exists
# already, or check that the newly "forced" created directory is empty.
bmuMkDir() {
    newdir=$1
    force=$2
    case ${force} in
	"y" | "Y" | "yes" | "YES" | "Yes")
	    mkdir -p "$newdir"; return $?
	    ;;
	"empy" | "empty" | "EMPTY" | "Empty")
	    mkdir -p "$newdir"
	    [ "$(ls -A "$newdir")" ] && return 1 || return 0
	    ;;
	"n" | "N" | "no" | "NO" | "No" | *)
	    mkdir "$newdir"; return $?
	    ;;
    esac
}
#
# bmuSetIndirectVar()
# Sets the variable named $1 to the current value of the variable whose
# NAME is given by $2 - i.e. $2 is itself a variable holding a name.
# Given:
#   MYDIR="/tmp"
#   WHICHDIR="MYDIR"
#	bmuSetIndirectVar "target" "$WHICHDIR"
# `target` ends up set to "/tmp" (the value of the variable MYDIR names).
#
bmuSetIndirectVar(){
    tmpVarName=$1
    locVarName=$1
    extVarName=$2
    #echo "debug Ind Input >$1< >$2<"
    eval tmpVarName=\$$extVarName
    #echo "debug Ind Output >$tmpVarName< >$extVarName<"
    export $locVarName="${tmpVarName}"
}
#
# bmuPromptyNexit()
# This function accept a prompt message and exit if the
# read string is anything different from a yes.
# The yes is detected by a case like:
#	"y" | "Y" | "yes" | "YES" | "Yes")
# The code distinguish also a "yes" version but
# at present it behaves like any other input.
bmuPromptyNexit() {
    msg="$1"
    echo "$msg"
    read val
    if [ -z "$val" ]; then
	echo "Exiting ..."
	exit 1
    fi
    #
    case ${val} in
	"n" | "N" | "no" | "NO" | "No")
	    echo "Exiting ..."
	    exit 1
	    ;;
	"y" | "Y" | "yes" | "YES" | "Yes")
	    ;;
	*)
	    echo "Exiting ..."
	    exit 1
	    ;;
    esac
    return 0    
}
#
# bmuPromptyN()
# Same y/N convention as bmuPromptyNexit, but for a decline that should
# NOT abort the caller - returns 1 instead of exiting. Use this when
# declining is a shrug ("skip this optional step"), not a fatal input;
# use bmuPromptyNexit when declining really should stop the script.
# EOF/empty input also falls through to "no" rather than hanging or
# erroring (POSIX `read` on EOF sets the target variable empty and
# returns nonzero, which this function doesn't need to check itself -
# an empty $val already lands in the wildcard case below).
bmuPromptyN() {
    msg="$1"
    echo "$msg"
    read val
    case ${val} in
	"y" | "Y" | "yes" | "YES" | "Yes")
	    return 0
	    ;;
	*)
	    return 1
	    ;;
    esac
}
#
# bmuPromptValue()
# - Get user prompt using the read function
#   Use it inside a while loop like:
#   while bmuPromptValue "Please type the SYNC directory: (${BMU_DIRRSYNC_TMP})" "BMU_DIRRSYNC_TMP" "d"
#   do
#       echo "not valid SYNC directory: >${BMU_DIRRSYNC_TMP}<"
#   done
#
#   The third option can be used to add a test within the read directly.
#   At present are implemented:
#   -d input must be an existing directory
#   -f input must be an existing file
#   -z input must be empty
#   -n input cannot be empty (implemented as ! -z )
#
bmuPromptValue() {
    msg="$1"
    storevar="$2"
    ttest="$3"
    # Capture the caller's original default before anything below can
    # overwrite $storevar - the dir-test retry loop further down needs
    # the true, pristine default to fall back to on a blank re-answer,
    # not whatever (possibly invalid) value the first read just stored.
    bmuSetIndirectVar "origval" "$storevar"
    echo "$msg"
    read val
    # POSIX `read` returns nonzero on real end-of-input (distinct from a
    # blank line, which is empty $val but a zero exit) - the "-n"/notzero
    # test below has no default to fall back to, so without this a caller
    # looping on it (e.g. a required free-text answer, first exercised by
    # backmeup.configure.sh's replication prompt) would spin forever once
    # stdin runs out, exactly as a scripted/non-interactive run can.
    l_bmu_read_rc=$?

    #echo "debug Input >$1< >$2< >$3<"
    
    if [ -z "$val" ]; then
	bmuSetIndirectVar "val" "$storevar"
	#echo "debug storevar: >$val<>$storevar<"
	#echo "debug val >${val}<"
    fi

    export $storevar="$val"

    case $ttest in
        "-f" | "f" | "file" | "FILE" | "File")
            if [ -z "$val" ]; then
                echo "Input is empty for file test"
                return 0
            fi
            if [ ! -f "$val" ]; then
                echo "Input is not a file"
                return 0
            fi
            ;;
        "-d" | "d" | "dir" | "DIR" | "Dir" | "directory" | "DIRECTORY" | "Directory")
            # Loop here (re-prompt), rather than returning to the caller
            # or exiting: the caller's own while-loop always offers to
            # mkdir -p whatever comes back as non-empty, so a bad value
            # like "(/some/path" (a real case seen from a copy-paste of a
            # shown default that included its surrounding parens) or a
            # plain relative path - or, seen in the wild, a stray "y"
            # typed out of habit from the previous prompt's y/N answer -
            # must never reach that flow, since a relative path would also
            # break later whenever the scripts run from a different
            # working directory, e.g. under cron. Exiting outright on a
            # single bad keystroke is needlessly harsh: it aborted the
            # whole multi-question configure run, forcing a full restart.
            while : ; do
                if [ -z "$val" ]; then
                    echo "Input is empty for dir test"
                    return 0
                fi
                case "$val" in
                    /*) break ;;
                    *)
                        echo "Input must be an absolute path (starting with /): $val"
                        echo "$msg"
                        read val
                        if [ -z "$val" ]; then
                            val="$origval"
                        fi
                        export $storevar="$val"
                        ;;
                esac
            done
            if [ ! -d "$val" ]; then
                echo "Input is not a dir"
                return 0
            fi
            ;;
        "-n" | "n" | "notzero" | "not-zero" | "NotZero" | "NOTZERO")
            if [ -z "$val" ]; then
                if [ ${l_bmu_read_rc} -ne 0 ]; then
                    echo "ERROR: no input received, exiting."
                    exit 1
                fi
                echo "Input is empty"
                return 0
            fi
            ;;
        "-z" | "z" | "zero" | "zerolen" | "Zero" | "ZERO")
            if [ ! -z "$val" ]; then
                echo "Input is not empty"
                return 0
            fi
            ;;
        *)
    esac
    export $storevar="$val"
    return 1
}
#
# bmuConfigureDir()
# Prompts for one of configure.sh's directory settings (SYNC, HISTORY,
# IndexDB, install dir), offering to create it if missing and tracking
# the creation in BMU_CONFIGURE_ROLLBACK (accumulated for a possible
# future rollback-on-abort - nothing consumes it yet). Replaces four
# copy-pasted ~20-line blocks in configure.sh that differed only in
# which variable/flag/prompt text they used.
#   $1 noun      - human label, e.g. "SYNC" - becomes "SYNC directory"
#                  in prompts, "SYNC Directory is:" in the summary line
#   $2 varname   - the BMU_* variable to set, e.g. BMU_DIRRSYNC
#   $3 default   - suggested value shown in the prompt
#   $4 flagname  - the --xxx-dir= flag name for bmuConfigureDirFromFlag
#   $5 clivalue  - already-extracted CLI flag value, empty if none given
bmuConfigureDir() {
    l_bcd_noun=$1
    l_bcd_varname=$2
    l_bcd_default=$3
    l_bcd_flagname=$4
    l_bcd_clivalue=$5
    if [ -n "${l_bcd_clivalue}" ]; then
        bmuConfigureDirFromFlag "${l_bcd_clivalue}" "${l_bcd_flagname}" "${l_bcd_varname}"
    else
        BMU_CONFIGURE_TMPVAL=${l_bcd_default}
        while bmuPromptValue "Please type the ${l_bcd_noun} directory: (${BMU_CONFIGURE_TMPVAL})" "BMU_CONFIGURE_TMPVAL" "d"
        do
            echo "not valid or not existing ${l_bcd_noun} directory: ${BMU_CONFIGURE_TMPVAL}"
            if [ -z "$BMU_CONFIGURE_TMPVAL" ]; then
                echo "Empty input value: Exiting the configuration ..."
                exit 1
            fi
            bmuPromptyNexit "Shall I create the directory for you (y/N)?"
            if bmuMkDir "${BMU_CONFIGURE_TMPVAL}" "empty"; then
                BMU_CONFIGURE_ROLLBACK="${BMU_CONFIGURE_ROLLBACK} rm -rf ${BMU_CONFIGURE_TMPVAL};"
                break
            else
                echo "cannot create the directory."
            fi
        done
        bmuSetIndirectVar "${l_bcd_varname}" "BMU_CONFIGURE_TMPVAL"
    fi
    eval "echo \"${l_bcd_noun} Directory is: \${${l_bcd_varname}}\""
}
