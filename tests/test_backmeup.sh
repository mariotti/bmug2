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
# load shunit2
# ------------
. "${TESTS_PATH}/shunit2"
