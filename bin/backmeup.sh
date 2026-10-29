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
. "${BMU_PATH}/backmeup.setup.sh"
. "${BMU_PATH}/backmeup.shellfunctions.sh"
#
# Set up the current date
mydate=`date +%Y%m%d-%H%M%S`

# Parsing options
l_BMU_DRYRUN=""
if [ "$1" = "-n" ] || [ "$1" = "--dry-run" ]; then
    l_BMU_DRYRUN="--dry-run"
    shift
fi;
if [ -z "$1" ]; then
    echo "usage: backmeup.sh [-n|--dry-run] <dir>"
    echo "  -n, --dry-run   show what would be copied, deleted and archived"
    echo "                  without changing anything"
    exit 1;
fi;
#Remove trailing / It creates a project directory
l_BMU_TOBACKUP="`dirname \"$1\"`/`basename \"$1\"`"
l_BMU_PRJDIR=`basename "${1}"`

#Refuse to run without a usable rsync (openrsync drops --delete with --backup)
if [ -z "${BMU_CMDRSYNC}" ]; then
    echo "ERROR: no usable rsync found. Apple's openrsync ignores --delete"
    echo "when --backup is active, so deleted files would never be backed up."
    echo "Install a real rsync, e.g.: brew install rsync"
    exit 1
fi;

#Refuse to run if SYNC/HISTORY no longer resolve to the filesystem they
#were configured on - typically an external drive that isn't actually
#mounted right now. Without this check, its mountpoint directory still
#exists (and is writable) on the system disk even when nothing is
#mounted there: mkdir -p below would just recreate it, and rsync would
#happily fill it, silently consuming space on the very disk this backup
#is meant to protect - a real, confirmed gap, not a hypothetical one.
#Skipped entirely when either var is empty: an install that predates
#this check, or was never run through backmeup.configure.sh since -
#re-run it once to opt in, same as any other config refresh. The one
#WARNING below replaces the previous silent-skip for that case (see
#OPEN_ISSUES #3): the user keeps running, but is told the guard is
#off and how to turn it on. Exit code deliberately unchanged so cron
#jobs on older installs stay working across the upgrade.
if [ -z "${BMU_DIRRSYNC_MOUNT}" ] || [ -z "${BMU_DIRBACKUPS_MOUNT}" ]; then
    l_bmu_missing_mount=""
    if [ -z "${BMU_DIRRSYNC_MOUNT}" ]; then
        l_bmu_missing_mount="BMU_DIRRSYNC_MOUNT"
    fi
    if [ -z "${BMU_DIRBACKUPS_MOUNT}" ]; then
        l_bmu_missing_mount="${l_bmu_missing_mount}${l_bmu_missing_mount:+, }BMU_DIRBACKUPS_MOUNT"
    fi
    echo "WARNING: mount check is disabled (empty: ${l_bmu_missing_mount})."
    echo "  Re-run backmeup.configure.sh to populate these and enable"
    echo "  the silent-filling-the-system-disk guard."
fi
if [ -n "${BMU_DIRRSYNC_MOUNT}" ]; then
    l_bmu_live_mount=`bmuMountPoint "${BMU_DIRRSYNC}"`
    if [ "${l_bmu_live_mount}" != "${BMU_DIRRSYNC_MOUNT}" ]; then
        echo "ERROR: SYNC directory (${BMU_DIRRSYNC}) is not on its configured"
        echo "filesystem (expected mount: ${BMU_DIRRSYNC_MOUNT}, found: ${l_bmu_live_mount:-<none>})."
        echo "This usually means its drive isn't connected or mounted right now -"
        echo "refusing to run rather than silently writing to the wrong disk."
        echo "If this location has genuinely changed on purpose, re-run"
        echo "backmeup.configure.sh to confirm the new one."
        exit 1
    fi
fi;
if [ -n "${BMU_DIRBACKUPS_MOUNT}" ]; then
    l_bmu_live_mount=`bmuMountPoint "${BMU_DIRBACKUPS}"`
    if [ "${l_bmu_live_mount}" != "${BMU_DIRBACKUPS_MOUNT}" ]; then
        echo "ERROR: BackUp/HISTORY directory (${BMU_DIRBACKUPS}) is not on its"
        echo "configured filesystem (expected mount: ${BMU_DIRBACKUPS_MOUNT}, found:"
        echo "${l_bmu_live_mount:-<none>}). This usually means its drive isn't"
        echo "connected or mounted right now - refusing to run rather than"
        echo "silently writing to the wrong disk. If this location has genuinely"
        echo "changed on purpose, re-run backmeup.configure.sh to confirm the new one."
        exit 1
    fi
fi;

#Old (pre-bmug2) layout detection: the mirror used to live one level deeper
#(sync/<project>/<project>). Running the fixed layout against it would archive
#the whole old mirror into today's B- dir and re-transfer everything, so
#refuse and point to the migration script instead. If the source project
#really contains a same-named subdirectory we cannot tell the layouts apart;
#that legitimate case also has ${l_BMU_TOBACKUP}/${l_BMU_PRJDIR} and passes.
if [ -d "${BMU_DIRRSYNC}/${l_BMU_PRJDIR}/${l_BMU_PRJDIR}" ] && \
   [ ! -e "${l_BMU_TOBACKUP}/${l_BMU_PRJDIR}" ]; then
    echo "ERROR: old bmu layout detected: ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}/${l_BMU_PRJDIR}"
    echo "bmug2 mirrors the project directly in ${BMU_DIRRSYNC}/${l_BMU_PRJDIR}."
    echo "Migrate once (instant rename, no re-transfer):"
    echo "  ${BMU_PATH}/backmeup.migrate.sh ${l_BMU_PRJDIR}"
    exit 1
fi;

#Define a rsync backup dir. It is new at each time we run up to mydate granularity
l_BMU_DIRBKUP="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate}"
#
#Optional per-project settings (BMU_GITIGNORE/BMU_BMUIGNORE below) - a
#plain sourced shell file, same idiom backmeup.setup.sh itself uses.
#Lives on the destination side (HISTORY/<project>/), not in the source
#tree, since it's a setting about how bmug2 backs the project up, not
#part of the project's own content. Read unconditionally (not gated on
#dry-run) so a --dry-run preview reflects the project's real settings;
#safe to read even before HISTORY/<project>/ has ever been created (the
#-f test just fails and the defaults below apply).
l_BMU_PRJCONFIG="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/.bmuconfig"
if [ -f "${l_BMU_PRJCONFIG}" ]; then
    . "${l_BMU_PRJCONFIG}"
fi
#Pre-create the project level: rsync (>=3.4) fails delete-phase backups with
#"File exists" when the --backup-dir path has 2+ missing components. With the
#project dir in place only B-${mydate} is missing, which rsync handles fine,
#and the dir-exists checks below still tell whether anything was backed up.
if [ -z "${l_BMU_DRYRUN}" ]; then
    mkdir -p "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}"
    #Per-project lock: GUI interval schedules, GUI Run Now, and a cron/
    #launchd/systemd entry can all target this same project, and two
    #overlapping runs would collide on the same second-granularity
    #B-${mydate} snapshot dir. Different projects are never serialized
    #against each other - only this same lock path is.
    l_BMU_LOCKDIR="${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/.bmulock"
    if ! bmuAcquireLock "${l_BMU_LOCKDIR}"; then
        echo "ERROR: another backmeup.sh run for '${l_BMU_PRJDIR}' is already in progress."
        exit 1
    fi
    trap 'bmuReleaseLock "${l_BMU_LOCKDIR}"' EXIT
fi;
#
#Trailing slash on the source: mirror the project content directly into
#${BMU_DIRRSYNC}/<project> instead of the old nested <project>/<project>
#
#Built via `set --`/"$@" rather than appended to a plain variable: the
#dir-merge filter values below each need a required internal space
#("dir-merge,- .gitignore") preserved as one argv word. Word-splitting
#an unquoted variable can't do that - confirmed for real that rsync
#rejects it as "unknown option" if appended to BMU_OPTRSYNC's own
#word-split expansion instead. A literal quoted string in the script's
#own source (below) is parsed correctly once, at parse time, then
#`set --` keeps it as a single positional parameter from then on.
#--delete-excluded: without it, toggling BMU_GITIGNORE/BMU_BMUIGNORE
#"on" for a project that already has matching files sitting in the
#mirror leaves them there forever - confirmed for real that rsync's
#default --delete only re-derives deletions when the merge file
#(.gitignore/.bmuignore) itself changes, not when the *command-line*
#filter referencing an unchanged merge file is newly added. Harmless
#no-op whenever no filter below is actually active (nothing "excluded"
#to force-delete), so always included rather than conditioned on them.
set -- ${BMU_CMDRSYNC} ${l_BMU_DRYRUN} ${BMU_OPTRSYNC} --delete-excluded --backup-dir="${l_BMU_DIRBKUP}"
#.gitignore respected by default (BMU_GITIGNORE unset or anything but
#"no"); .bmuignore is a pure superset on top and off by default (must
#be explicitly activated per project) - both live in the source tree
#itself, walked per-directory by rsync same as a real git checkout.
#Note: rsync's dir-merge filter language isn't byte-identical to git's -
#confirmed a real `!pattern` negation line does NOT re-include a file
#the way git itself would (see docs/EXAMPLES.md).
if [ "${BMU_GITIGNORE:-yes}" != "no" ]; then
    #.git itself is never listed IN a .gitignore - git doesn't need
    #telling to ignore its own metadata directory, it's implicit - so
    #respecting .gitignore alone never excluded it. Real gap, found by
    #the user: every project's full git history got mirrored for no
    #benefit, since the project is already versioned by git itself;
    #there's nothing a file-level snapshot of .git/ gives you that
    #git's own history doesn't, and it can be large. Excluded here,
    #unconditionally whenever gitignore-respecting is on, rather than
    #something every single project's own .bmuignore has to spell out.
    #A plain literal pattern (no wildcard) matches only a path
    #component exactly equal to ".git" - .github (GitHub Actions
    #config, real project content, must stay backed up) is a
    #different, longer name and is never touched by this. Listed
    #before the .gitignore dir-merge filter so it always wins, even if
    #a project's own .gitignore tried to un-ignore .git.
    set -- "$@" --exclude='.git/'
    set -- "$@" --filter='dir-merge,- .gitignore'
fi
if [ "${BMU_BMUIGNORE:-no}" = "yes" ]; then
    set -- "$@" --filter='dir-merge,- .bmuignore'
fi
set -- "$@" "${l_BMU_TOBACKUP}/" "${BMU_DIRRSYNC}/${l_BMU_PRJDIR}"
"$@"
l_BMU_RSYNCRC=$?
#
#In a dry run rsync only reported what it would do: skip the filelist and
#the indexing, which key off a backup dir that was never created.
if [ -n "${l_BMU_DRYRUN}" ]; then
    echo ""
    echo "DRY RUN: no files were copied, deleted, archived or indexed."
    exit 0
fi;
#
#Record the last successful run for backmeup.status.sh. Kept outside the
#mirror on purpose: anything inside it would be deleted (and archived!) by
#the next --delete run. Written as text because reading a file's mtime
#portably (BSD vs GNU date/stat) is not worth the trouble.
if [ ${l_BMU_RSYNCRC} -eq 0 ]; then
    date "+%Y-%m-%d %H:%M:%S" > "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/.bmulastrun"
fi;
#
# Create List Files
if [ -d "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}/B-${mydate}" ]; then
  cd "${BMU_DIRBACKUPS}"
  find "${l_BMU_PRJDIR}/B-${mydate}" > "${l_BMU_PRJDIR}/B-${mydate}.filelist"
  cd - > /dev/null
fi;
#
# Live filelist: a plain `find` over the just-updated mirror, refreshed on
# every successful run - not the slow full `bmu updatedb`/cron reindex,
# which can be a day away. Without this, a file backed up seconds ago
# is invisible to backmeup.locate.sh until that next full reindex
# happens, since the index it queries (.locate.db) is only ever built by
# backmeup.updatedb.sh, never incrementally by this script. Same
# zero-dependency "grep a plain filelist" trick already used for
# archived snapshots below, just for the live mirror instead of history.
if [ ${l_BMU_RSYNCRC} -eq 0 ]; then
    ( cd "${BMU_DIRRSYNC}" && find "${l_BMU_PRJDIR}" > "${BMU_DIRBACKUPS}/${l_BMU_PRJDIR}.filelist" )
fi;
#
### END OF RSYNC JOB ###
#
#Exit with rsync's own status: a cron job checking $? should see a real
#rsync failure, not the unrelated exit code of whichever "if" ran last
#(POSIX: an if/elif with no branch taken exits 0, masking rsync's rc).
exit ${l_BMU_RSYNCRC}
