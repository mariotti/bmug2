#! /bin/sh
#
# Regression tests for the bmu core workflow, run with the bundled shunit2:
#
#   sh tests/test_backmeup.sh
#
# The suite replays the scenario that caught the two big bugs fixed in
# bmug2 (openrsync dropping --delete with --backup, and rsync >= 3.4
# failing delete-phase backups into a deep --backup-dir):
#
#   run 1: back up a project with two files
#   run 2: back up again after changing one file and deleting the other
#
# then asserts on the mirror, the archived versions, the filelists and,
# when an updatedb is available, on indexing and search. Index/search
# tests are skipped (not failed) on machines without findutils.
#
# Detect test path
# ----------------
TESTS_PATH="`dirname \"$0\"`"
TESTS_PATH="`( cd \"$TESTS_PATH\" && pwd )`"
if [ -z "${TESTS_PATH}" ] ; then
  exit 1
fi
BMU_BIN_SRC="${TESTS_PATH}/../bin"

oneTimeSetUp() {
    SB="${SHUNIT_TMPDIR}/bmu"
    mkdir -p "${SB}/src/myproject/sub" "${SB}/sync/.locate.dir" "${SB}/sync-BP"
    cp -R "${BMU_BIN_SRC}" "${SB}/bin"
    sed -e "s|\${HOME}/tmp/rsyncBackup|${SB}/sync|" \
        "${SB}/bin/backmeup.setup.sh.template" > "${SB}/bin/backmeup.setup.sh"

    # run 1: initial backup
    echo "hello v1" > "${SB}/src/myproject/file1.txt"
    echo "doomed file" > "${SB}/src/myproject/sub/file2.txt"
    "${SB}/bin/backmeup.sh" "${SB}/src/myproject" > "${SB}/run1.log" 2>&1
    RUN1_EXIT=$?

    # rsync's quick check is mtime+size based: force a different mtime
    sleep 1

    # run 2: change one file, delete the other
    echo "hello v2 with different length" > "${SB}/src/myproject/file1.txt"
    rm "${SB}/src/myproject/sub/file2.txt"
    "${SB}/bin/backmeup.sh" "${SB}/src/myproject" > "${SB}/run2.log" 2>&1
    RUN2_EXIT=$?

    # the only B-<date> dir: run 1 starts from empty so only run 2 archives
    BKDIR=`ls -d "${SB}/sync-BP/myproject"/B-*/ 2>/dev/null | head -1`
    BKDIR=${BKDIR%/}

    # import the detected commands (BMU_CMDRSYNC, BMU_CMDUPDATEDB, ...)
    . "${SB}/bin/backmeup.setup.sh"
}

#
# rsync detection and core backup behaviour
# -----------------------------------------

testRealRsyncDetected() {
    assertNotNull "no usable rsync detected (BMU_CMDRSYNC empty)" \
        "${BMU_CMDRSYNC}"
    ${BMU_CMDRSYNC} --version 2>/dev/null | head -1 | grep -qi openrsync
    assertFalse "detected rsync identifies as openrsync" $?
}

testBackupRunsExitZero() {
    assertEquals "run 1 (initial backup) failed, see run1.log" 0 ${RUN1_EXIT}
    assertEquals "run 2 (change+delete) failed, see run2.log" 0 ${RUN2_EXIT}
}

testMirrorHasCurrentVersion() {
    # bmug2 layout: the mirror lives directly in sync/<project>, without
    # the old <project>/<project> double nesting
    assertEquals "hello v2 with different length" \
        "`cat \"${SB}/sync/myproject/file1.txt\" 2>/dev/null`"
}

testMirrorIsNotDoubleNested() {
    [ -d "${SB}/sync/myproject/myproject" ]
    assertFalse "old double-nested layout was created" $?
}

testMirrorDropsDeletedFile() {
    # openrsync regression: with --backup active it ignores --delete and
    # the deleted file stays in the mirror forever
    [ -e "${SB}/sync/myproject/sub/file2.txt" ]
    assertFalse "deleted file still present in the mirror" $?
}

testChangedFileOldVersionArchived() {
    assertNotNull "no B-<date> backup dir was created" "${BKDIR}"
    assertEquals "hello v1" \
        "`cat \"${BKDIR}/file1.txt\" 2>/dev/null`"
}

testDeletedFileArchived() {
    # rsync >= 3.4 regression: delete-phase make_backup failed with
    # "File exists" when the backup dir path had 2+ missing components
    assertEquals "doomed file" \
        "`cat \"${BKDIR}/sub/file2.txt\" 2>/dev/null`"
}

testFilelistCreated() {
    l_filelist="${BKDIR}.filelist"
    assertTrue "missing filelist ${l_filelist}" "[ -f '${l_filelist}' ]"
    grep -q "file1.txt" "${l_filelist}" 2>/dev/null
    assertTrue "filelist does not mention file1.txt" $?
}

testRefusesWithoutUsableRsync() {
    # simulate a machine where detection finds nothing: override the
    # detected command with an empty one at the end of the setup file
    l_dir="${SHUNIT_TMPDIR}/bmu-norsync"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    echo 'BMU_CMDRSYNC=""' >> "${l_dir}/backmeup.setup.sh"
    "${l_dir}/backmeup.sh" "${SB}/src/myproject" > "${l_dir}/run.log" 2>&1
    assertEquals "must refuse to run without a usable rsync" 1 $?
    grep -q "ERROR" "${l_dir}/run.log"
    assertTrue "no ERROR message shown to the user" $?
}

#
# indexing and search (skipped when no updatedb is available)
# -----------------------------------------------------------

testPerRunIndexCreated() {
    [ -z "${BMU_CMDUPDATEDB}" ] && startSkipping
    l_count=`ls "${SB}/sync/.locate.dir/".locate.db.myproject.* 2>/dev/null | wc -l`
    assertEquals "expected exactly one per-run index db" 1 `expr ${l_count}`
}

testSearchFindsCurrentAndHistory() {
    [ -z "${BMU_CMDUPDATEDB}" ] && startSkipping
    "${SB}/bin/backmeup.updatedb.sh" > "${SB}/updatedb.log" 2>&1
    assertEquals "backmeup.updatedb.sh failed, see updatedb.log" 0 $?
    l_out=`"${SB}/bin/backmeup.locate.sh" file1 2>/dev/null`
    echo "${l_out}" | grep -q "sync/myproject/file1.txt"
    assertTrue "search misses the current version of file1" $?
    echo "${l_out}" | grep -q "sync-BP/myproject/B-.*/file1.txt"
    assertTrue "search misses the archived version of file1" $?
}

testSearchFindsDeletedFile() {
    [ -z "${BMU_CMDUPDATEDB}" ] && startSkipping
    "${SB}/bin/backmeup.locate.sh" file2 2>/dev/null \
        | grep -q "sync-BP/myproject/B-.*/sub/file2.txt"
    assertTrue "search misses the deleted (archived) file2" $?
}

#
# old-layout compatibility: detection, migration, no re-transfer
# --------------------------------------------------------------

testOldLayoutRefusedAndMigrated() {
    # build a fake old-layout mirror for a second project
    l_src="${SHUNIT_TMPDIR}/bmu/src/oldproj"
    mkdir -p "${l_src}/sub"
    echo "old data" > "${l_src}/keep.txt"
    echo "old deep" > "${l_src}/sub/deep.txt"
    mkdir -p "${SB}/sync/oldproj"
    cp -Rp "${l_src}" "${SB}/sync/oldproj/oldproj"

    # 1. backmeup.sh must refuse, not churn the old mirror
    "${SB}/bin/backmeup.sh" "${l_src}" > "${SB}/oldrun.log" 2>&1
    assertEquals "must refuse to run on an old-layout mirror" 1 $?
    grep -q "old bmu layout detected" "${SB}/oldrun.log"
    assertTrue "no old-layout explanation shown" $?
    assertTrue "old mirror was modified by the refused run" \
        "[ -f '${SB}/sync/oldproj/oldproj/keep.txt' ]"

    # 2. migration is an instant rename to the new layout
    "${SB}/bin/backmeup.migrate.sh" oldproj > "${SB}/migrate.log" 2>&1
    assertEquals "migration failed, see migrate.log" 0 $?
    assertTrue "[ -f '${SB}/sync/oldproj/keep.txt' ]"
    [ -d "${SB}/sync/oldproj/oldproj" ]
    assertFalse "nested dir still present after migration" $?

    # 3. the next backup runs clean and re-transfers nothing
    "${SB}/bin/backmeup.sh" "${l_src}" > "${SB}/oldrun2.log" 2>&1
    assertEquals "backup after migration failed" 0 $?
    grep -q "keep.txt\|deep.txt" "${SB}/oldrun2.log"
    assertFalse "files were re-transferred after migration" $?
}

testMigrateRefusesAmbiguousLayout() {
    # a project dir with more than the nested mirror inside could be a
    # new-layout project containing a same-named subdirectory: hands off
    l_dir="${SB}/sync/ambiproj"
    mkdir -p "${l_dir}/ambiproj"
    echo x > "${l_dir}/extra.txt"
    "${SB}/bin/backmeup.migrate.sh" ambiproj > "${SB}/ambi.log" 2>&1
    assertEquals "must refuse ambiguous layout" 1 $?
    assertTrue "ambiguous mirror was modified" \
        "[ -f '${l_dir}/extra.txt' -a -d '${l_dir}/ambiproj' ]"
}

testDryRunChangesNothing() {
    l_src="${SHUNIT_TMPDIR}/bmu/src/dryproj"
    mkdir -p "${l_src}"
    echo "dry data" > "${l_src}/d1.txt"

    # phase 1: dry-run on a project never backed up -> nothing created
    "${SB}/bin/backmeup.sh" --dry-run "${l_src}" > "${SB}/dry1.log" 2>&1
    assertEquals "dry-run failed, see dry1.log" 0 $?
    grep -q "d1.txt" "${SB}/dry1.log"
    assertTrue "dry-run does not preview the transfer" $?
    grep -q "DRY RUN" "${SB}/dry1.log"
    assertTrue "dry-run does not announce itself" $?
    [ -e "${SB}/sync/dryproj" ]
    assertFalse "dry-run created the mirror" $?
    [ -e "${SB}/sync-BP/dryproj" ]
    assertFalse "dry-run created the backup project dir" $?
    l_count=`ls "${SB}/sync/.locate.dir/".locate.db.dryproj.* 2>/dev/null | wc -l`
    assertEquals "dry-run created an index" 0 `expr ${l_count}`

    # phase 2: real backup, delete a file, dry-run (-n alias) must preview
    # the deletion but leave the mirror untouched
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1
    rm "${l_src}/d1.txt"
    "${SB}/bin/backmeup.sh" -n "${l_src}" > "${SB}/dry2.log" 2>&1
    assertEquals "-n dry-run failed, see dry2.log" 0 $?
    grep -q "deleting d1.txt" "${SB}/dry2.log"
    assertTrue "dry-run does not preview the deletion" $?
    assertTrue "dry-run removed the file from the mirror" \
        "[ -f '${SB}/sync/dryproj/d1.txt' ]"
    # restore so the deletion cannot leak into later tests
    echo "dry data" > "${l_src}/d1.txt"
}

testWorksWithSpacesInPaths() {
    # everything spaced: install dir, sync dirs, project name, file names
    l_sb="${SHUNIT_TMPDIR}/bmu sp"
    mkdir -p "${l_sb}/src/my project/sub dir" \
             "${l_sb}/sync/.locate.dir" "${l_sb}/sync-BP"
    cp -R "${BMU_BIN_SRC}" "${l_sb}/bin"
    sed -e "s|\${HOME}/tmp/rsyncBackup|${l_sb}/sync|" \
        "${l_sb}/bin/backmeup.setup.sh.template" > "${l_sb}/bin/backmeup.setup.sh"

    echo "sp v1" > "${l_sb}/src/my project/a file.txt"
    echo "sp doomed" > "${l_sb}/src/my project/sub dir/gone file.txt"
    "${l_sb}/bin/backmeup.sh" "${l_sb}/src/my project" > "${l_sb}/run1.log" 2>&1
    assertEquals "run 1 with spaces failed, see run1.log" 0 $?
    sleep 1
    echo "sp v2 changed" > "${l_sb}/src/my project/a file.txt"
    rm "${l_sb}/src/my project/sub dir/gone file.txt"
    "${l_sb}/bin/backmeup.sh" "${l_sb}/src/my project" > "${l_sb}/run2.log" 2>&1
    assertEquals "run 2 with spaces failed, see run2.log" 0 $?

    assertEquals "sp v2 changed" \
        "`cat \"${l_sb}/sync/my project/a file.txt\" 2>/dev/null`"
    [ -e "${l_sb}/sync/my project/sub dir/gone file.txt" ]
    assertFalse "deleted file still in mirror (spaced paths)" $?
    l_bk=`ls -d "${l_sb}/sync-BP/my project"/B-*/ 2>/dev/null | head -1`
    assertEquals "sp v1" "`cat \"${l_bk}a file.txt\" 2>/dev/null`"
    assertEquals "sp doomed" "`cat \"${l_bk}sub dir/gone file.txt\" 2>/dev/null`"
}

testStatusReport() {
    # the real backup runs in oneTimeSetUp recorded a last-run stamp
    assertTrue "no .bmulastrun stamp recorded by backmeup.sh" \
        "[ -f '${SB}/sync-BP/myproject/.bmulastrun' ]"

    l_out=`"${SB}/bin/backmeup.status.sh" 2>&1`
    assertEquals "status script failed" 0 $?
    echo "${l_out}" | grep -q "^myproject "
    assertTrue "status misses the myproject row" $?
    # last-change column shows the snapshot timestamp, humanized
    l_stamp=`basename "${BKDIR}" | sed 's/^B-\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/'`
    echo "${l_out}" | grep -q "${l_stamp}"
    assertTrue "status misses last-change timestamp '${l_stamp}'" $?

    # old-layout mirrors are flagged with the migration command
    mkdir -p "${SB}/sync/legacyproj/legacyproj"
    l_out=`"${SB}/bin/backmeup.status.sh" 2>&1`
    echo "${l_out}" | grep -q "OLD LAYOUT: run backmeup.migrate.sh legacyproj"
    assertTrue "old-layout project not flagged" $?
    rm -rf "${SB}/sync/legacyproj"
}

testUpdatedbFailsCleanlyWithoutUpdatedb() {
    l_dir="${SHUNIT_TMPDIR}/bmu-noupdatedb"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    echo 'BMU_CMDUPDATEDB=""' >> "${l_dir}/backmeup.setup.sh"
    "${l_dir}/backmeup.updatedb.sh" > "${l_dir}/run.log" 2>&1
    assertEquals "must fail without an updatedb" 1 $?
    grep -q "ERROR" "${l_dir}/run.log"
    assertTrue "no ERROR message shown to the user" $?
}

#
# archive facility: compress old snapshots, keep them searchable, restore
# ------------------------------------------------------------------------

testArchiveSearchAndRestore() {
    l_src="${SHUNIT_TMPDIR}/bmu/src/archproj"
    mkdir -p "${l_src}/sub"
    echo "arch v1" > "${l_src}/keep.txt"
    echo "arch bye" > "${l_src}/sub/vanish.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1
    sleep 1
    echo "arch v2" > "${l_src}/keep.txt"
    rm "${l_src}/sub/vanish.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1
    l_bk=`ls -d "${SB}/sync-BP/archproj"/B-*/ 2>/dev/null | head -1`
    l_bk="${l_bk%/}"
    assertNotNull "no snapshot created for archproj" "${l_bk}"
    l_name=`basename "${l_bk}"`

    # dry-run: reports but changes nothing
    "${SB}/bin/backmeup.archive.sh" -n archproj 0 > "${SB}/arch-dry.log" 2>&1
    assertEquals "archive dry-run failed" 0 $?
    assertTrue "dry-run removed the snapshot dir" "[ -d '${l_bk}' ]"
    [ -f "${l_bk}.tar.gz" ]
    assertFalse "dry-run created a tarball" $?

    # real archive, days=0 so every existing snapshot is "old"
    "${SB}/bin/backmeup.archive.sh" archproj 0 > "${SB}/arch.log" 2>&1
    assertEquals "archive failed, see arch.log" 0 $?
    assertTrue "tarball missing after archive" "[ -f '${l_bk}.tar.gz' ]"
    [ -d "${l_bk}" ]
    assertFalse "snapshot dir still on disk after archive" $?
    assertTrue "searchable filelist was lost" "[ -f '${l_bk}.filelist' ]"
    tar -tzf "${l_bk}.tar.gz" | grep -q "sub/vanish.txt"
    assertTrue "archived tar misses the deleted file" $?

    # archived snapshots stay searchable via plain grep of the filelist,
    # marked as archived - works even with no locate installed
    "${SB}/bin/backmeup.locate.sh" vanish 2>/dev/null \
        | grep -q "archproj/${l_name}/sub/vanish.txt (archived)"
    assertTrue "archived file not found by backmeup.locate.sh" $?

    # restore brings back the exact content and removes the tarball
    "${SB}/bin/backmeup.unarchive.sh" archproj "${l_name}" > "${SB}/unarch.log" 2>&1
    assertEquals "unarchive failed, see unarch.log" 0 $?
    assertEquals "arch bye" "`cat \"${l_bk}/sub/vanish.txt\" 2>/dev/null`"
    [ -f "${l_bk}.tar.gz" ]
    assertFalse "tarball still present after restore" $?
}

testArchiveKeepsFreshSnapshots() {
    # with the default age (no days argument) nothing here is old enough
    "${SB}/bin/backmeup.archive.sh" archproj > "${SB}/arch-fresh.log" 2>&1
    assertEquals "archive with default age failed" 0 $?
    grep -q "No snapshots older than" "${SB}/arch-fresh.log"
    assertTrue "fresh snapshots were considered for archiving" $?
    l_count=`ls "${SB}/sync-BP/archproj"/B-*.tar.gz 2>/dev/null | wc -l`
    assertEquals "a fresh snapshot was archived" 0 `expr ${l_count}`
}

#
# load shunit2
# ------------
. "${TESTS_PATH}/shunit2"
