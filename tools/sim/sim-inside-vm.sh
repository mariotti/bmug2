#!/bin/bash
# Phase 1 baseline sim — runs INSIDE a Lima Fedora VM.
#
# Verifies the deterministic claim: between SYNC runs, bmug2 captures
# the file state at the moment of the SYNC into the live mirror, and
# the state replaced by that SYNC into a fresh HISTORY snapshot. No
# disruptions in this phase; just measure performance and confirm the
# recovery is actually there.
#
# Time compression: 1 real day = 60 sim seconds (1440×).
#   - Edit interval:  2.5s sim = ~1 real hour per edit
#   - SYNC interval:  5.0s sim = ~2 real hours per SYNC
#   - 10 cycles × (2 edits + 1 SYNC) ≈ 50-70s sim ≈ ~5 real days

set -euo pipefail

# Lima mounts the host's $HOME at the host-side path (e.g.
# /Users/mariotti) inside the VM — NOT at the guest's $HOME, which
# resolves to /home/mariotti.guest. The host orchestrator passes the
# correct path via BMUG2_SOURCE.
HOST_REPO="${BMUG2_SOURCE:-$HOME/GIT/bmug2}"
[ -d "$HOST_REPO" ] || { echo "ERROR: bmug2 source not found at $HOST_REPO"; exit 1; }
# /tmp on Fedora is tmpfs (~1 GiB cap on a 2 GiB VM); bmug2 + .git
# alone can exceed that. Use $HOME/sim instead - disk-backed, plenty
# of room on the 20 GiB VM disk. This is the GUEST's $HOME
# (/home/mariotti.guest), writable, NOT the host-mounted read-only
# path at /Users/mariotti.
SIM_ROOT="$HOME/sim"
INSTALL_DIR="$SIM_ROOT/bmu-install"
SOURCE_DIR="$SIM_ROOT/src/project"
SYNC_DIR="$SIM_ROOT/sync"
BACKUP_DIR="$SIM_ROOT/sync-BP"
INDEX_DIR="$SIM_ROOT/sync/.locate.dir"

echo "=== Phase 1 baseline sim (bmug2) ==="
echo "VM:  $(uname -srm)"
echo "Date: $(date -u +%FT%TZ)"
echo "bmug2 source (host-mounted): $HOST_REPO"
echo

# ------------------------------------------------------------------
# 1. Install bmug2 non-interactively
# ------------------------------------------------------------------
# Lima mounts the host's $HOME read-only, but configure.sh writes
# `backmeup.setup.sh.new` inside the source `bin/` directory before
# the install step relocates things. Copy the source tree to a
# writable VM-local path first so configure.sh can write.
echo "==> Copying bmug2 source to writable location..."
rm -rf "$SIM_ROOT"
mkdir -p "$SIM_ROOT/src"
# rsync + --exclude keeps .git out (saves ~70% of the copy time and
# space; the sim doesn't need it) and gives better errors than cp.
rsync -a --exclude='.git/' --exclude='target/' --exclude='node_modules/' \
    "$HOST_REPO/" "$SIM_ROOT/src/bmug2/"
LOCAL_REPO="$SIM_ROOT/src/bmug2"

echo "==> Installing bmug2..."
cd "$LOCAL_REPO"
sh install.sh \
    --sync-dir="$SYNC_DIR" \
    --backup-dir="$BACKUP_DIR" \
    --index-dir="$INDEX_DIR" \
    --install-dir="$INSTALL_DIR" \
    < /dev/null
export PATH="$INSTALL_DIR/bin:$PATH"
installed_version=$(grep -E '^BMU_VERSION=' "$INSTALL_DIR/bin/backmeup.setup.sh" | head -1)
echo "Installed: $installed_version"
echo

# ------------------------------------------------------------------
# 2. Generate controlled tree (flat-many preset: 100 files × 10 KB)
# ------------------------------------------------------------------
echo "==> Generating tree (flat-many: 100 files × 10 KB)..."
mkdir -p "$SOURCE_DIR"
for i in $(seq -w 1 100); do
    { echo "file-${i}-v0"; head -c 10200 /dev/zero | tr '\0' 'a'; } > "$SOURCE_DIR/f${i}.txt"
done
tree_bytes=$(du -sb "$SOURCE_DIR" | cut -f1)
tree_count=$(find "$SOURCE_DIR" -type f | wc -l)
echo "Tree: ${tree_count} files, ${tree_bytes} bytes"
echo

project=$(basename "$SOURCE_DIR")

# ------------------------------------------------------------------
# 3. Calibration: one baseline SYNC to measure the floor
# ------------------------------------------------------------------
echo "==> Calibration SYNC (initial, cold)..."
cal_start=$(date +%s.%N)
backmeup.sh "$SOURCE_DIR" > /dev/null
cal_end=$(date +%s.%N)
cal_elapsed=$(awk "BEGIN{printf \"%.3f\", $cal_end - $cal_start}")
echo "Calibration SYNC elapsed: ${cal_elapsed}s"
if awk "BEGIN{exit !($cal_elapsed > 2.5)}"; then
    echo "WARNING: baseline SYNC exceeds the 2.5s edit interval."
    echo "         The sim will stretch; actual compression ratio will be lower."
fi
echo

# ------------------------------------------------------------------
# 4. Sim loop
# ------------------------------------------------------------------
cycles=10
edit_files=(f001.txt f002.txt)
pass=0
fail=0
declare -a sync_times=()

# Buffer sleep: ensure the first cycle's edit has a visibly later
# mtime than the calibration SYNC. Without this, a fast first edit
# can land within rsync's mtime-comparison window and get skipped as
# "unchanged" - a real property of rsync, not a sim bug, that
# a human user won't hit because humans don't type faster than
# rsync.
sleep 1

echo "==> Sim loop: ${cycles} cycles, SYNC every 5s sim..."
for cycle in $(seq 1 $cycles); do
    # Edit each tracked file to version "v${cycle}".
    for fn in "${edit_files[@]}"; do
        num="${fn#f}"; num="${num%.txt}"
        { echo "file-${num}-v${cycle}"; head -c 10200 /dev/zero | tr '\0' 'b'; } > "$SOURCE_DIR/$fn"
        sleep 2.5
    done

    sync_start=$(date +%s.%N)
    backmeup.sh "$SOURCE_DIR" > /dev/null
    sync_end=$(date +%s.%N)
    sync_elapsed=$(awk "BEGIN{printf \"%.3f\", $sync_end - $sync_start}")
    sync_times+=("$sync_elapsed")

    # Verify: the latest HISTORY snapshot DIRECTORY (not its sibling
    # .filelist file) captures the version replaced by this SYNC
    # (i.e. "v$((cycle - 1))" on cycle ≥ 2; "v0" on cycle 1).
    latest_snapshot=$(find "$BACKUP_DIR/$project/" -maxdepth 1 -type d -name 'B-*' -printf '%f\n' 2>/dev/null | sort | tail -1 || true)
    for fn in "${edit_files[@]}"; do
        num="${fn#f}"; num="${num%.txt}"
        expected_sync="file-${num}-v${cycle}"
        expected_prev=$((cycle - 1))
        expected_history="file-${num}-v${expected_prev}"

        # Check SYNC has current version.
        if ! grep -q "^${expected_sync}$" "$SYNC_DIR/$project/$fn"; then
            echo "FAIL cycle=$cycle $fn: SYNC missing '$expected_sync'"
            fail=$((fail + 1))
            continue
        fi
        pass=$((pass + 1))

        # Check HISTORY has prior version (always exists from cycle 1 onwards).
        if [ -z "$latest_snapshot" ] || [ ! -f "$BACKUP_DIR/$project/$latest_snapshot/$fn" ]; then
            echo "FAIL cycle=$cycle $fn: no HISTORY snapshot file"
            fail=$((fail + 1))
            continue
        fi
        if ! grep -q "^${expected_history}$" "$BACKUP_DIR/$project/$latest_snapshot/$fn"; then
            echo "FAIL cycle=$cycle $fn: HISTORY has wrong version (expected '$expected_history')"
            fail=$((fail + 1))
            continue
        fi
        pass=$((pass + 1))
    done

    printf "cycle %2d: SYNC %.3fs  snapshot=%s\n" "$cycle" "$sync_elapsed" "$latest_snapshot"
done

echo

# ------------------------------------------------------------------
# 5. Report
# ------------------------------------------------------------------
# sync_times stats
total=0
max=0
min=99999
for t in "${sync_times[@]}"; do
    total=$(awk "BEGIN{printf \"%.3f\", $total + $t}")
    awk "BEGIN{exit !($t > $max)}" && max="$t"
    awk "BEGIN{exit !($t < $min)}" && min="$t"
done
avg=$(awk "BEGIN{printf \"%.3f\", $total / ${#sync_times[@]}}")

sync_size=$(du -sh "$SYNC_DIR" 2>/dev/null | cut -f1)
history_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
snapshot_count=$(find "$BACKUP_DIR/$project/" -maxdepth 1 -type d -name 'B-*' 2>/dev/null | wc -l | tr -d ' ')

echo "=== Results ==="
echo "Checks:   ${pass} passed / ${fail} failed  (expected: 0 failed)"
echo "SYNC avg: ${avg}s  min: ${min}s  max: ${max}s  (cal: ${cal_elapsed}s)"
echo "After ${cycles} cycles: SYNC=${sync_size}, HISTORY=${history_size}, snapshots=${snapshot_count}"

if [ "$fail" -eq 0 ]; then
    echo
    echo "PASS: all cycle checks passed."
    exit 0
else
    echo
    echo "FAIL: ${fail} check(s) failed."
    exit 1
fi
