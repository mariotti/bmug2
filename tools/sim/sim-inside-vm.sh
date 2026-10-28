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
# 2. Generate controlled tree (preset-selected)
# ------------------------------------------------------------------
# edit_files is an array of "label|relative-path" pairs - the LABEL is
# used in file content ("file-${label}-v${cycle}") so the sim loop can
# grep for it later; the PATH can contain subdirectories (needed for
# the `deep` preset). Each gen_* function populates edit_files for
# its own tree shape.
PRESET="${PRESET:-flat-many}"
edit_files=()

gen_flat_few() {
    # 10 files × 1 MB flat. Tests "fewer, larger files" - more rsync
    # bytes per file, fewer stats to compare.
    for i in $(seq -w 1 10); do
        { echo "file-f${i}-v0"; head -c 1048566 /dev/zero | tr '\0' 'a'; } > "$SOURCE_DIR/f${i}.txt"
    done
    edit_files=("f01|f01.txt" "f02|f02.txt")
}

gen_flat_many() {
    # 100 files × 10 KB flat. Original baseline. Tests "many, smaller
    # files" - more stats, less rsync bytes per file.
    for i in $(seq -w 1 100); do
        { echo "file-f${i}-v0"; head -c 10200 /dev/zero | tr '\0' 'a'; } > "$SOURCE_DIR/f${i}.txt"
    done
    edit_files=("f001|f001.txt" "f002|f002.txt")
}

gen_deep() {
    # 100 files × 100 KB, placed across a depth-5 / fanout-3 tree.
    # 3^5 = 243 leaf dirs; first 100 (lexicographic) get a file.
    # Tests "path traversal depth" - how rsync + find scale with
    # directory nesting at ~constant file count.
    local count=0 label a b c d e path
    for a in 0 1 2; do for b in 0 1 2; do for c in 0 1 2; do
    for d in 0 1 2; do for e in 0 1 2; do
        if [ "$count" -lt 100 ]; then
            label=$(printf 'deep%02d' "$count")
            path="d${a}/d${b}/d${c}/d${d}/d${e}"
            mkdir -p "$SOURCE_DIR/$path"
            { echo "file-${label}-v0"; head -c 102390 /dev/zero | tr '\0' 'a'; } > "$SOURCE_DIR/$path/f.txt"
            count=$((count + 1))
        fi
    done; done; done; done; done
    # Edit two files: file #0 and file #50 of the 100 generated. File
    # N's path is (N/81, N/27, N/9, N/3, N) each mod 3, in a-e order
    # (outer-to-inner loop). File #50 = (0,1,2,1,2).
    edit_files=("deep00|d0/d0/d0/d0/d0/f.txt" "deep50|d0/d1/d2/d1/d2/f.txt")
}

echo "==> Generating tree (preset: $PRESET)..."
mkdir -p "$SOURCE_DIR"
case "$PRESET" in
    flat-few)  gen_flat_few ;;
    flat-many) gen_flat_many ;;
    deep)      gen_deep ;;
    *) echo "ERROR: unknown PRESET='$PRESET' (expected: flat-few | flat-many | deep)" >&2; exit 2 ;;
esac
tree_bytes=$(du -sb "$SOURCE_DIR" | cut -f1)
tree_count=$(find "$SOURCE_DIR" -type f | wc -l)
tree_dirs=$(find "$SOURCE_DIR" -type d | wc -l)
echo "Tree ($PRESET): ${tree_count} files in ${tree_dirs} dirs, ${tree_bytes} bytes"
echo "Edit targets: ${#edit_files[@]} files"
for ef in "${edit_files[@]}"; do echo "  ${ef%%|*}: ${ef#*|}"; done
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
# Determine per-file payload size from the preset (match the generator
# so overwrites keep the same size - rsync won't skip-on-size-match
# in that case; it still has to compare content via mtime+size).
case "$PRESET" in
    flat-few)  payload_size=1048566 ;;
    flat-many) payload_size=10200   ;;
    deep)      payload_size=102390  ;;
esac
for cycle in $(seq 1 $cycles); do
    # Edit each tracked file to version "v${cycle}".
    for entry in "${edit_files[@]}"; do
        label="${entry%%|*}"
        path="${entry#*|}"
        { echo "file-${label}-v${cycle}"; head -c "$payload_size" /dev/zero | tr '\0' 'b'; } > "$SOURCE_DIR/$path"
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
    for entry in "${edit_files[@]}"; do
        label="${entry%%|*}"
        path="${entry#*|}"
        expected_sync="file-${label}-v${cycle}"
        expected_prev=$((cycle - 1))
        expected_history="file-${label}-v${expected_prev}"

        # Check SYNC has current version.
        if ! grep -q "^${expected_sync}$" "$SYNC_DIR/$project/$path"; then
            echo "FAIL cycle=$cycle $path: SYNC missing '$expected_sync'"
            fail=$((fail + 1))
            continue
        fi
        pass=$((pass + 1))

        # Check HISTORY has prior version (always exists from cycle 1 onwards).
        if [ -z "$latest_snapshot" ] || [ ! -f "$BACKUP_DIR/$project/$latest_snapshot/$path" ]; then
            echo "FAIL cycle=$cycle $path: no HISTORY snapshot file"
            fail=$((fail + 1))
            continue
        fi
        if ! grep -q "^${expected_history}$" "$BACKUP_DIR/$project/$latest_snapshot/$path"; then
            echo "FAIL cycle=$cycle $path: HISTORY has wrong version (expected '$expected_history')"
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
