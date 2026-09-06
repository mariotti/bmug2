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
    assertEquals "hello v2 with different length" \
        "`cat \"${SB}/sync/myproject/myproject/file1.txt\" 2>/dev/null`"
}

testMirrorDropsDeletedFile() {
    # openrsync regression: with --backup active it ignores --delete and
    # the deleted file stays in the mirror forever
    [ -e "${SB}/sync/myproject/myproject/sub/file2.txt" ]
    assertFalse "deleted file still present in the mirror" $?
}

testChangedFileOldVersionArchived() {
    assertNotNull "no B-<date> backup dir was created" "${BKDIR}"
    assertEquals "hello v1" \
        "`cat \"${BKDIR}/myproject/file1.txt\" 2>/dev/null`"
}

testDeletedFileArchived() {
    # rsync >= 3.4 regression: delete-phase make_backup failed with
    # "File exists" when the backup dir path had 2+ missing components
    assertEquals "doomed file" \
        "`cat \"${BKDIR}/myproject/sub/file2.txt\" 2>/dev/null`"
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
    echo "${l_out}" | grep -q "sync/myproject/myproject/file1.txt"
    assertTrue "search misses the current version of file1" $?
    echo "${l_out}" | grep -q "sync-BP/myproject/B-.*/myproject/file1.txt"
    assertTrue "search misses the archived version of file1" $?
}

testSearchFindsDeletedFile() {
    [ -z "${BMU_CMDUPDATEDB}" ] && startSkipping
    "${SB}/bin/backmeup.locate.sh" file2 2>/dev/null \
        | grep -q "sync-BP/myproject/B-.*/myproject/sub/file2.txt"
    assertTrue "search misses the deleted (archived) file2" $?
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
