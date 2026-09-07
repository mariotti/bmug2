#! /bin/sh
#
# Regression tests for the bmu core workflow, run with the bundled shunit2:
#
#   sh tests/test_backmeup.sh
#
# Two kinds of tests:
#
#  - testUserJourneyEndToEnd drives an install through backmeup.install.sh
#    with scripted answers, then exercises the full command set (dry-run,
#    backup, status, search, archive, unarchive) through the installed
#    copy - the only test covering install.sh/configure.sh at all.
#
#  - Everything else targets one command's behavior or edge case against
#    a shared sandbox (oneTimeSetUp), pre-populated by two real backup
#    runs (one file changed, one deleted) that also caught the two big
#    bugs fixed early in bmug2: openrsync dropping --delete with
#    --backup, and rsync >= 3.4 failing delete-phase backups into a deep
#    --backup-dir.
#
# Index/search tests are skipped (not failed) on machines without
# findutils, except where a test explicitly simulates that case.
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
    sed -e "s|\${HOME}/Backups/rsyncBackup|${SB}/sync|" \
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
# full user journey: install, configure, backup, search, archive, restore
# -------------------------------------------------------------------------
# Everything above and below reuses a sandbox pre-configured by
# oneTimeSetUp with a hand-written setup file. This test instead drives
# the actual entry point a new user runs: backmeup.install.sh, answering
# its prompts exactly as a human would, then exercises the full command
# set through the installed copy. It is the only test covering
# install.sh/configure.sh/shellfunctions.sh at all, which matters: the
# two real configure.sh bugs found earlier (BMU_CMDRSYNC never written
# to the generated setup, and the "empy"/"empty" mkdir typo) were caught
# by hand-testing, not by the suite - this closes that coverage hole.

testUserJourneyEndToEnd() {
    # a realistic space-free layout, like the README's Quick start.
    # (Spaces in paths are covered separately by testWorksWithSpacesInPaths;
    # keeping them out here avoids a real, unrelated limitation: GNU
    # findutils' updatedb treats --localpaths as a space-*separated list*
    # of roots by design, so it cannot index a root whose own path
    # contains a space - confirmed independently of our scripts by
    # calling gupdatedb directly. Backup, search-via-filelist, migrate
    # and archive are unaffected; only glocate-backed search over such a
    # path is. Noted in docs/MANUAL.md.)
    l_home="${SHUNIT_TMPDIR}/journeyhome"
    l_checkout="${SHUNIT_TMPDIR}/journeycheckout"
    mkdir -p "${SHUNIT_TMPDIR}/journey" "${l_home}/usr" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"

    # Answers, in prompt order: SYNC (default, doesn't exist) -> y to
    # create; BACKUP (default) -> y; INDEX (default) -> y; base INSTALL
    # path (pre-created above, so accepted immediately, no create
    # prompt); INSTALL dir (default, doesn't exist) -> y to create.
    printf '\ny\n\ny\n\ny\n\n\ny\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" \
        > "${SHUNIT_TMPDIR}/journey/install.log" 2>&1
    assertEquals "install failed, see install.log" 0 $?

    l_bmu="${l_home}/usr/bmu/bin"
    assertTrue "install did not create ${l_bmu}/backmeup.sh" \
        "[ -x '${l_bmu}/backmeup.sh' ]"

    # regression guard for the two bugs found by hand: configure must
    # detect and persist both tools into the generated setup file
    grep -q 'BMU_CMDRSYNC="[^"]' "${l_bmu}/backmeup.setup.sh"
    assertTrue "configure did not persist a detected rsync" $?
    if [ -n "${BMU_CMDUPDATEDB}" ]; then
        grep -q 'BMU_CMDUPDATEDB="[^"]' "${l_bmu}/backmeup.setup.sh"
        assertTrue "configure did not persist a detected updatedb" $?
    fi

    l_src="${SHUNIT_TMPDIR}/journey/docs"
    mkdir -p "${l_src}/reports"
    echo "quarterly numbers v1" > "${l_src}/reports/report.pdf"
    echo "scratch notes" > "${l_src}/notes.txt"

    # preview first, like a cautious new user
    "${l_bmu}/backmeup.sh" --dry-run "${l_src}" \
        > "${SHUNIT_TMPDIR}/journey/dry.log" 2>&1
    assertEquals "dry-run failed, see dry.log" 0 $?
    grep -q "DRY RUN" "${SHUNIT_TMPDIR}/journey/dry.log"
    assertTrue "dry-run did not announce itself" $?
    assertFalse "dry-run already created the mirror" \
        "[ -e '${l_home}/Backups/rsyncBackup/docs' ]"

    # first real backup
    "${l_bmu}/backmeup.sh" "${l_src}" \
        > "${SHUNIT_TMPDIR}/journey/backup1.log" 2>&1
    assertEquals "first backup failed, see backup1.log" 0 $?

    sleep 1
    echo "quarterly numbers v2, corrected" > "${l_src}/reports/report.pdf"
    rm "${l_src}/notes.txt"
    "${l_bmu}/backmeup.sh" "${l_src}" \
        > "${SHUNIT_TMPDIR}/journey/backup2.log" 2>&1
    assertEquals "second backup failed, see backup2.log" 0 $?

    assertEquals "quarterly numbers v2, corrected" \
        "`cat \"${l_home}/Backups/rsyncBackup/docs/reports/report.pdf\" 2>/dev/null`"
    assertFalse "notes.txt still in the mirror after deletion" \
        "[ -e '${l_home}/Backups/rsyncBackup/docs/notes.txt' ]"

    l_snap=`ls -d "${l_home}/Backups/rsyncBackup-BP/docs"/B-*/ 2>/dev/null | head -1`
    l_snap="${l_snap%/}"
    assertNotNull "no snapshot recorded for the second backup" "${l_snap}"
    l_snapname=`basename "${l_snap}"`

    # status: a new user checking on things
    l_status=`"${l_bmu}/backmeup.status.sh" 2>&1`
    echo "${l_status}" | grep -q "^docs "
    assertTrue "status does not list the docs project" $?

    # index, then search for the current file and the deleted one. The
    # full-index search only exists with findutils installed; without it
    # there is no fallback for *live* files (only archived ones have a
    # filelist), so skip just this part on a machine without updatedb.
    "${l_bmu}/backmeup.updatedb.sh" > "${SHUNIT_TMPDIR}/journey/updatedb.log" 2>&1
    if [ -n "${BMU_CMDUPDATEDB}" ]; then
        assertEquals "updatedb failed, see updatedb.log" 0 $?
        # one pattern per call: multi-pattern locate semantics differ
        # across implementations (GNU/mlocate/plocate), and every other
        # test in this suite already sticks to the portable single form
        "${l_bmu}/backmeup.locate.sh" report.pdf 2>/dev/null \
            | grep -q "rsyncBackup/docs/reports/report.pdf"
        assertTrue "search misses the current report.pdf" $?
        "${l_bmu}/backmeup.locate.sh" notes.txt 2>/dev/null \
            | grep -q "rsyncBackup-BP/docs/B-.*/notes.txt"
        assertTrue "search misses the deleted notes.txt in history" $?
    fi

    # archive the (now old enough) snapshot, confirm it stays searchable
    sleep 1
    "${l_bmu}/backmeup.archive.sh" docs 0 \
        > "${SHUNIT_TMPDIR}/journey/archive.log" 2>&1
    assertEquals "archive failed, see archive.log" 0 $?
    assertTrue "archive did not produce a tarball" \
        "[ -f '${l_snap}.tar.gz' ]"
    "${l_bmu}/backmeup.locate.sh" notes.txt 2>/dev/null | grep -q "(archived)"
    assertTrue "archived notes.txt not found by search" $?

    # restore it back
    "${l_bmu}/backmeup.unarchive.sh" docs "${l_snapname}" \
        > "${SHUNIT_TMPDIR}/journey/unarchive.log" 2>&1
    assertEquals "unarchive failed, see unarchive.log" 0 $?
    assertTrue "snapshot not restored to a directory" "[ -d '${l_snap}' ]"
}

testInstallOffersToCreateCustomInstpath() {
    # The base INSTALL directory prompt used to be the only one of the
    # four directory prompts that didn't offer to create a missing
    # directory - it just printed "not existing installation path." and
    # exited, which only went unnoticed because every other test (and the
    # journey test above) pre-creates the default path or accepts an
    # already-existing default. Typing a custom, nonexistent path is the
    # scenario that actually exposed it.
    l_home="${SHUNIT_TMPDIR}/custominstpathhome"
    l_checkout="${SHUNIT_TMPDIR}/custominstpathcheckout"
    mkdir -p "${l_home}" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"

    # Answers: SYNC (default) -> y; BACKUP (default) -> y; INDEX
    # (default) -> y; base INSTALL path -> a custom, nonexistent path,
    # then y to create it; INSTALL dir (default under that custom
    # path) -> y to create.
    printf '\ny\n\ny\n\ny\n%s\ny\n\ny\n' "${l_home}/custom-instpath" | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" \
        > "${SHUNIT_TMPDIR}/custominstpath-install.log" 2>&1
    assertEquals "install with a custom INSTPATH failed, see custominstpath-install.log" \
        0 $?
    assertTrue "custom INSTPATH was not created" \
        "[ -d '${l_home}/custom-instpath' ]"
    assertTrue "install did not create backmeup.sh under the custom INSTPATH" \
        "[ -x '${l_home}/custom-instpath/bmu/bin/backmeup.sh' ]"
}

testInstallAbortsCleanlyWhenConfigureFails() {
    # configure.sh can fail for any reason (declining to create a
    # directory, in this case); install.sh must abort immediately rather
    # than pressing on into `cp` with stale defaults from the template
    # and only noticing something was wrong several steps later.
    l_home="${SHUNIT_TMPDIR}/abortcleanlyhome"
    l_checkout="${SHUNIT_TMPDIR}/abortcleanlycheckout"
    mkdir -p "${l_home}" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"

    # Decline to create the SYNC directory (default, doesn't exist).
    printf '\nn\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" \
        > "${SHUNIT_TMPDIR}/abortcleanly-install.log" 2>&1
    assertEquals "install must fail when configure.sh fails" 1 $?
    grep -q "configuration did not complete" "${SHUNIT_TMPDIR}/abortcleanly-install.log"
    assertTrue "no clear abort message when configure.sh fails" $?
    grep -q "^cp:" "${SHUNIT_TMPDIR}/abortcleanly-install.log"
    assertFalse "install attempted cp after configure.sh failed" $?
    assertFalse "backmeup.setup.sh written despite the failed configure run" \
        "[ -f '${l_checkout}/backmeup.setup.sh' ]"
}

testConfigureRejectsNonAbsoluteDirectoryAnswer() {
    # Real corruption found in the wild: a user copy-pasted a shown
    # default including its surrounding parens, typing "(/some/path" as
    # their answer. The old behavior accepted it as if it were "not a dir
    # yet", offered to create it, and mkdir -p happily created a literal
    # directory named "(/some/path" (interpreted as relative, since it
    # doesn't start with /) - then persisted that garbage into
    # backmeup.setup.sh forever, corrupting every later run that reads it
    # back. A plain relative path has the same problem and would also
    # silently break later under cron (different working directory).
    l_home="${SHUNIT_TMPDIR}/rejectbadpathhome"
    l_checkout="${SHUNIT_TMPDIR}/rejectbadpathcheckout"
    mkdir -p "${l_home}" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"

    # Answer the SYNC directory prompt with a corrupted-looking value.
    printf '(/Users/nobody/rsyncBackup\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" \
        > "${SHUNIT_TMPDIR}/rejectbadpath-install.log" 2>&1
    assertEquals "must reject a non-absolute directory answer" 1 $?
    grep -q "must be an absolute path" "${SHUNIT_TMPDIR}/rejectbadpath-install.log"
    assertTrue "no clear message rejecting the bad path" $?
    assertFalse "backmeup.setup.sh written despite the rejected answer" \
        "[ -f '${l_checkout}/backmeup.setup.sh' ]"
}

testInstallCopiesOnlyRealFilesNoHousekeepingCruft() {
    # configure.sh's own write-out leaves a backmeup.setup.sh.old backup
    # of the previous config in the SOURCE checkout by design (run it
    # twice to actually produce one) - install.sh copying the whole
    # source directory used to bring .old (and .template, and any stray
    # hand-made backup file) along into the installed copy too, none of
    # which have any purpose there. Also checks the new explanatory
    # header lands in the generated setup.sh, answering the "why can't I
    # just run this file" confusion directly in the file itself.
    l_home="${SHUNIT_TMPDIR}/cleaninstallhome"
    l_checkout="${SHUNIT_TMPDIR}/cleaninstallcheckout"
    mkdir -p "${l_home}/usr" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"
    # a stray hand-made backup, the kind a manual edit can leave behind
    echo "leftover" > "${l_checkout}/backmeup.setup.sh.bak"

    printf '\ny\n\ny\n\ny\n\n\ny\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" > /dev/null 2>&1
    assertEquals "first install failed" 0 $?
    # reconfigure once more so backmeup.setup.sh.old actually gets created
    printf '\n\n\n\n\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.configure.sh" > /dev/null 2>&1
    assertTrue "expected backmeup.setup.sh.old to exist after reconfiguring" \
        "[ -f '${l_checkout}/backmeup.setup.sh.old' ]"
    assertFalse "backmeup.setup.sh.new left behind after configure.sh finished" \
        "[ -f '${l_checkout}/backmeup.setup.sh.new' ]"

    l_bmu="${l_home}/usr/bmu/bin"
    assertTrue "install did not create backmeup.sh" "[ -x '${l_bmu}/backmeup.sh' ]"
    assertTrue "install did not copy the live setup file" \
        "[ -f '${l_bmu}/backmeup.setup.sh' ]"
    assertFalse "install copied backmeup.setup.sh.old into the install dir" \
        "[ -f '${l_bmu}/backmeup.setup.sh.old' ]"
    assertFalse "install copied a stray .bak file into the install dir" \
        "[ -f '${l_bmu}/backmeup.setup.sh.bak' ]"

    grep -q "do not run this file directly" "${l_bmu}/backmeup.setup.sh"
    assertTrue "generated setup.sh is missing the explanatory header" $?
}

testConfigureExplainsDestinationsAndDefaultIsNotNamedTmp() {
    # The default used to be "${HOME}/tmp/rsyncBackup" - not literally
    # /tmp (not auto-cleared by the OS), but the name alone reads as
    # "disposable" to anyone glancing at the prompt and hitting enter.
    # Also checks the explanatory tips actually appear, so a user is
    # told what each directory is for and where the two kinds (data vs.
    # the program itself) should live, not just handed bare prompts.
    l_home="${SHUNIT_TMPDIR}/tipshome"
    l_checkout="${SHUNIT_TMPDIR}/tipscheckout"
    mkdir -p "${l_home}/usr" "${l_checkout}"
    cp -R "${BMU_BIN_SRC}/." "${l_checkout}"

    printf '\ny\n\ny\n\ny\n\n\ny\n' | \
        HOME="${l_home}" "${l_checkout}/backmeup.install.sh" \
        > "${SHUNIT_TMPDIR}/tips-install.log" 2>&1
    assertEquals "install failed, see tips-install.log" 0 $?

    grep -q "actual backup destination" "${SHUNIT_TMPDIR}/tips-install.log"
    assertTrue "no tip explaining where the data directories should live" $?
    grep -q "PROGRAM itself lives, not your data" "${SHUNIT_TMPDIR}/tips-install.log"
    assertTrue "no tip distinguishing the install dir from the data dirs" $?

    grep -q "Please type the SYNC directory: (${l_home}/Backups/rsyncBackup)" \
        "${SHUNIT_TMPDIR}/tips-install.log"
    assertTrue "default SYNC directory is not under Backups/" $?
    grep -q "tmp/rsyncBackup" "${SHUNIT_TMPDIR}/tips-install.log"
    assertFalse "default SYNC directory still suggests a tmp/ path" $?
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

testBackupNoOpRunCreatesNoSnapshot() {
    l_src="${SHUNIT_TMPDIR}/bmu/src/noopproj"
    mkdir -p "${l_src}"
    echo "steady" > "${l_src}/steady.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1
    sleep 1
    # run again with nothing changed at all
    "${SB}/bin/backmeup.sh" "${l_src}" > "${SB}/noop.log" 2>&1
    assertEquals "a no-op backup run must still exit 0" 0 $?
    l_count=`ls -d "${SB}/sync-BP/noopproj"/B-*/ 2>/dev/null | wc -l`
    assertEquals "a snapshot was created for a run that changed nothing" \
        0 `expr ${l_count}`
    assertTrue ".bmulastrun not written by a successful no-op run" \
        "[ -f '${SB}/sync-BP/noopproj/.bmulastrun' ]"
}

testBackupPropagatesRsyncFailureExitCode() {
    # a script wrapping rsync should surface rsync's own failure, not
    # whichever unrelated "if" happened to run last in the script
    l_dir="${SHUNIT_TMPDIR}/bmu-rsyncfail"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    l_fake="${SHUNIT_TMPDIR}/fake-failing-rsync"
    mkdir -p "${l_fake}"
    printf '#!/bin/sh\nexit 2\n' > "${l_fake}/fakersync"
    chmod +x "${l_fake}/fakersync"
    echo "BMU_CMDRSYNC=\"${l_fake}/fakersync\"" >> "${l_dir}/backmeup.setup.sh"

    l_src="${SHUNIT_TMPDIR}/bmu/src/rsyncfailproj"
    mkdir -p "${l_src}"
    echo x > "${l_src}/x.txt"
    "${l_dir}/backmeup.sh" "${l_src}" > "${l_dir}/run.log" 2>&1
    assertEquals "script must exit with rsync's own failure code" 2 $?
    assertFalse ".bmulastrun written despite rsync failing" \
        "[ -f '${SB}/sync-BP/rsyncfailproj/.bmulastrun' ]"
}

testOldLayoutGuardIgnoresLegitimateSameNamedSubdir() {
    # a project whose SOURCE legitimately contains a subdirectory with
    # the same name as itself ends up looking exactly like the old
    # double-nested layout by coincidence; the guard must not refuse it
    l_src="${SHUNIT_TMPDIR}/bmu/src/legitproj"
    mkdir -p "${l_src}/legitproj"
    echo "nested legit file" > "${l_src}/legitproj/inner.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > "${SB}/legit1.log" 2>&1
    assertEquals "first backup of legit same-named-subdir project failed" 0 $?
    assertTrue "expected coincidental nesting in the mirror" \
        "[ -d '${SB}/sync/legitproj/legitproj' ]"

    "${SB}/bin/backmeup.sh" "${l_src}" > "${SB}/legit2.log" 2>&1
    assertEquals "legit same-named-subdir project was wrongly refused" 0 $?
    grep -q "old bmu layout detected" "${SB}/legit2.log"
    assertFalse "false positive: legit project flagged as old layout" $?
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

testUpdatedbClearsOldPartIndexes() {
    [ -z "${BMU_CMDUPDATEDB}" ] && startSkipping
    # a fresh, dedicated project so this test does not depend on whether
    # some other test already ran a full reindex over myproject's index
    l_src="${SHUNIT_TMPDIR}/bmu/src/partindexproj"
    mkdir -p "${l_src}"
    echo x > "${l_src}/x.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1
    sleep 1
    echo y > "${l_src}/x.txt"
    "${SB}/bin/backmeup.sh" "${l_src}" > /dev/null 2>&1

    l_count=`ls "${SB}/sync/.locate.dir/".locate.db.partindexproj.* 2>/dev/null | wc -l`
    assertNotEquals "expected a per-run index to clear" 0 `expr ${l_count}`
    "${SB}/bin/backmeup.updatedb.sh" > /dev/null 2>&1
    l_count=`ls "${SB}/sync/.locate.dir/".locate.db.partindexproj.* 2>/dev/null | wc -l`
    assertEquals "a full reindex must clear old per-run indexes" \
        0 `expr ${l_count}`
}

testLocateWorksWithoutLocateInstalled() {
    # simulate a machine with no locate: the archived-filelist grep
    # fallback must still work, with zero dependency on findutils
    l_dir="${SHUNIT_TMPDIR}/bmu-nolocate"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    echo 'BMU_CMDLOCATE=""' >> "${l_dir}/backmeup.setup.sh"

    l_src="${SHUNIT_TMPDIR}/bmu/src/nolocateproj"
    mkdir -p "${l_src}"
    echo "findable" > "${l_src}/needle.txt"
    "${l_dir}/backmeup.sh" "${l_src}" > /dev/null 2>&1
    sleep 1
    rm "${l_src}/needle.txt"
    "${l_dir}/backmeup.sh" "${l_src}" > /dev/null 2>&1
    l_bk=`ls -d "${SB}/sync-BP/nolocateproj"/B-*/ 2>/dev/null | head -1`
    l_bk="${l_bk%/}"
    sleep 1
    "${l_dir}/backmeup.archive.sh" nolocateproj 0 > /dev/null 2>&1

    "${l_dir}/backmeup.locate.sh" needle 2>/dev/null \
        | grep -q "`basename \"${l_bk}\"`/needle.txt (archived)"
    assertTrue "grep fallback did not find the archived file without locate" $?
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

testMigrateNothingToMigrate() {
    # a normal, already-flat project: nothing to do, refuse and don't touch it
    l_dir="${SB}/sync/flatproj"
    mkdir -p "${l_dir}"
    echo x > "${l_dir}/x.txt"
    "${SB}/bin/backmeup.migrate.sh" flatproj > "${SB}/flatmigrate.log" 2>&1
    assertEquals "must refuse when there is no old layout to migrate" 1 $?
    grep -q "no old-layout nesting found" "${SB}/flatmigrate.log"
    assertTrue "no explanation shown for nothing-to-migrate" $?
    assertTrue "flat project was modified" "[ -f '${l_dir}/x.txt' ]"
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
    sed -e "s|\${HOME}/Backups/rsyncBackup|${l_sb}/sync|" \
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

testStatusNoProjectsFound() {
    l_dir="${SHUNIT_TMPDIR}/bmu-emptystatus"
    rm -rf "${l_dir}"
    mkdir -p "${l_dir}/sync/.locate.dir" "${l_dir}/sync-BP"
    cp -R "${SB}/bin" "${l_dir}/bin"
    sed -e "s|${SB}/sync|${l_dir}/sync|" "${SB}/bin/backmeup.setup.sh" \
        > "${l_dir}/bin/backmeup.setup.sh"
    l_out=`"${l_dir}/bin/backmeup.status.sh" 2>&1`
    assertEquals "status failed on an empty SYNC dir" 0 $?
    echo "${l_out}" | grep -q "no projects found"
    assertTrue "status did not report an empty SYNC dir" $?
}

testStatusHandlesMirrorOnlyProject() {
    # a project dropped straight into SYNC by hand, never backed up via
    # backmeup.sh: no history dir at all exists for it yet
    mkdir -p "${SB}/sync/manualproj"
    echo x > "${SB}/sync/manualproj/x.txt"
    l_out=`"${SB}/bin/backmeup.status.sh" 2>&1`
    echo "${l_out}" | grep -q "^manualproj *- *- *0"
    assertTrue "mirror-only project not reported with '-' placeholders" $?
    rm -rf "${SB}/sync/manualproj"
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

    # the days=0 cutoff is "now" at second granularity: let the clock
    # tick so the snapshot is strictly older than the cutoff
    sleep 1

    # dry-run: reports but changes nothing
    "${SB}/bin/backmeup.archive.sh" -n archproj 0 > "${SB}/arch-dry.log" 2>&1
    assertEquals "archive dry-run failed" 0 $?
    grep -q "would archive ${l_name}" "${SB}/arch-dry.log"
    assertTrue "dry-run did not report the archivable snapshot" $?
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

testArchiveRejectsNonNumericDays() {
    "${SB}/bin/backmeup.archive.sh" archproj notanumber > "${SB}/arch-bad.log" 2>&1
    assertEquals "must reject a non-numeric days argument" 1 $?
    grep -q "ERROR" "${SB}/arch-bad.log"
    assertTrue "no ERROR message for a non-numeric days argument" $?
}

testArchiveMissingProjectFails() {
    "${SB}/bin/backmeup.archive.sh" doesnotexistproj \
        > "${SB}/arch-noproj.log" 2>&1
    assertEquals "must fail archiving a project with no history" 1 $?
    grep -q "no history for" "${SB}/arch-noproj.log"
    assertTrue "no explanation for the missing-history project" $?
}

testArchiveCreatesMissingFilelist() {
    # a snapshot created without going through backmeup.sh (or one whose
    # filelist was lost) must still get a filelist before being archived
    l_bp="${SB}/sync-BP/barefilelistproj"
    mkdir -p "${l_bp}/B-20200101-000000/sub"
    echo "bare" > "${l_bp}/B-20200101-000000/sub/f.txt"
    assertFalse "unexpected pre-existing filelist" \
        "[ -f '${l_bp}/B-20200101-000000.filelist' ]"

    "${SB}/bin/backmeup.archive.sh" barefilelistproj 0 \
        > "${SB}/arch-nofilelist.log" 2>&1
    assertEquals "archive failed, see arch-nofilelist.log" 0 $?
    assertTrue "archive did not create the missing filelist" \
        "[ -f '${l_bp}/B-20200101-000000.filelist' ]"
    grep -q "sub/f.txt" "${l_bp}/B-20200101-000000.filelist"
    assertTrue "created filelist does not mention the snapshot's content" $?
}

testArchiveLeavesSnapshotOnTarFailure() {
    l_bp="${SB}/sync-BP/tarfailproj"
    mkdir -p "${l_bp}/B-20200101-000000"
    echo "precious" > "${l_bp}/B-20200101-000000/keep.txt"

    l_dir="${SHUNIT_TMPDIR}/bmu-tarfail"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    l_faketar="${SHUNIT_TMPDIR}/faketar-archive"
    mkdir -p "${l_faketar}"
    printf '#!/bin/sh\nexit 1\n' > "${l_faketar}/tar"
    chmod +x "${l_faketar}/tar"

    PATH="${l_faketar}:${PATH}" "${l_dir}/backmeup.archive.sh" \
        tarfailproj 0 > "${l_dir}/run.log" 2>&1
    assertEquals "must fail when tar fails" 1 $?
    grep -q "ERROR: tar failed" "${l_dir}/run.log"
    assertTrue "no ERROR message when tar fails" $?
    assertTrue "snapshot directory removed despite tar failing" \
        "[ -d '${l_bp}/B-20200101-000000' ]"
    [ -f "${l_bp}/B-20200101-000000.tar.gz" ]
    assertFalse "a tarball was kept despite tar failing" $?
    [ -f "${l_bp}/B-20200101-000000.tar.gz.part" ]
    assertFalse "a partial tarball was left behind" $?
}

#
# unarchive edge cases
# ---------------------

testUnarchiveMissingArchiveFails() {
    mkdir -p "${SB}/sync-BP/nosucharchiveproj"
    "${SB}/bin/backmeup.unarchive.sh" nosucharchiveproj B-20200101-000000 \
        > "${SB}/unarch-missing.log" 2>&1
    assertEquals "must fail restoring a nonexistent archive" 1 $?
    grep -q "no archive found" "${SB}/unarch-missing.log"
    assertTrue "no explanation for the missing archive" $?
}

testUnarchiveRefusesExistingDir() {
    l_bp="${SB}/sync-BP/unarchclashproj"
    mkdir -p "${l_bp}/B-20200101-000000"
    echo "already here" > "${l_bp}/B-20200101-000000/x.txt"
    # a tarball happens to exist too (e.g. a stale leftover from a prior,
    # incomplete restore) - the directory clash must still win
    ( cd "${l_bp}" && tar -czf B-20200101-000000.tar.gz B-20200101-000000 )

    "${SB}/bin/backmeup.unarchive.sh" unarchclashproj B-20200101-000000 \
        > "${SB}/unarch-clash.log" 2>&1
    assertEquals "must refuse to overwrite an existing snapshot dir" 1 $?
    grep -q "already exists as a directory" "${SB}/unarch-clash.log"
    assertTrue "no explanation for the directory clash" $?
    assertEquals "already here" "`cat \"${l_bp}/B-20200101-000000/x.txt\" 2>/dev/null`"
    assertTrue "archive removed despite refusing to restore" \
        "[ -f '${l_bp}/B-20200101-000000.tar.gz' ]"
}

testUnarchiveLeavesArchiveOnExtractFailure() {
    l_bp="${SB}/sync-BP/unarchfailproj"
    mkdir -p "${l_bp}"
    touch "${l_bp}/B-20200101-000000.tar.gz"

    l_dir="${SHUNIT_TMPDIR}/bmu-unarchfail"
    rm -rf "${l_dir}"
    cp -R "${SB}/bin" "${l_dir}"
    l_faketar="${SHUNIT_TMPDIR}/faketar-unarchive"
    mkdir -p "${l_faketar}"
    printf '#!/bin/sh\nexit 1\n' > "${l_faketar}/tar"
    chmod +x "${l_faketar}/tar"

    PATH="${l_faketar}:${PATH}" "${l_dir}/backmeup.unarchive.sh" \
        unarchfailproj B-20200101-000000 > "${l_dir}/run.log" 2>&1
    assertEquals "must fail when extraction fails" 1 $?
    grep -q "ERROR: extraction failed" "${l_dir}/run.log"
    assertTrue "no ERROR message when extraction fails" $?
    assertTrue "archive removed despite extraction failing" \
        "[ -f '${l_bp}/B-20200101-000000.tar.gz' ]"
    [ -d "${l_bp}/B-20200101-000000" ]
    assertFalse "a snapshot directory appeared despite extraction failing" $?
}

#
# load shunit2
# ------------
. "${TESTS_PATH}/shunit2"
