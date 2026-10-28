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

# Factor tree generation + data-dir reset into functions so the trial
# loop (Phase 2.5) can call them fresh per trial without re-installing
# bmug2 each time.
generate_tree() {
    rm -rf "$SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"
    case "$PRESET" in
        flat-few)  gen_flat_few ;;
        flat-many) gen_flat_many ;;
        deep)      gen_deep ;;
        *) echo "ERROR: unknown PRESET='$PRESET' (expected: flat-few | flat-many | deep)" >&2; exit 2 ;;
    esac
}

reset_data_dirs() {
    rm -rf "$SYNC_DIR" "$BACKUP_DIR"
    mkdir -p "$SYNC_DIR" "$BACKUP_DIR" "$INDEX_DIR"
}

echo "==> Generating tree (preset: $PRESET)..."
generate_tree
tree_bytes=$(du -sb "$SOURCE_DIR" | cut -f1)
tree_count=$(find "$SOURCE_DIR" -type f | wc -l)
tree_dirs=$(find "$SOURCE_DIR" -type d | wc -l)
echo "Tree ($PRESET): ${tree_count} files in ${tree_dirs} dirs, ${tree_bytes} bytes"
echo "Edit targets: ${#edit_files[@]} files"
for ef in "${edit_files[@]}"; do echo "  ${ef%%|*}: ${ef#*|}"; done
echo

project=$(basename "$SOURCE_DIR")

# ------------------------------------------------------------------
# 3. Scenario + Trials setup
# ------------------------------------------------------------------
# SCENARIO=baseline — original: 10 cycles of edits + SYNC + verify
# SCENARIO=deletion — baseline PLUS: at cycle $delete_at_cycle, delete
#                     the SECOND tracked file instead of editing it.
#                     Verify (a) SYNC drops it, (b) HISTORY captures
#                     its pre-delete version, (c) retrieve pulls it
#                     back out to a scratch dir with matching content.
SCENARIO="${SCENARIO:-baseline}"
SEED="${SEED:-42}"
TRIALS="${TRIALS:-1}"
cycles=10

# The deletion target is the SECOND file in edit_files (first stays
# alive and keeps proving the baseline mechanics through to cycle 10
# even after we delete this one). Set once; stable across trials.
if [ "$SCENARIO" = "deletion" ]; then
    deletion_entry="${edit_files[1]}"
    deletion_label="${deletion_entry%%|*}"
    deletion_path="${deletion_entry#*|}"
fi

echo "==> Scenario: ${SCENARIO} (SEED=${SEED}, TRIALS=${TRIALS})"

# Aggregates across trials (Phase 2.5):
agg_pass=0            # trials where fail==0
agg_fail=0            # trials where fail>0
declare -a agg_cycles=()        # delete_at_cycle per trial (deletion scenario)
declare -a agg_recoveries=()    # retrieve elapsed per trial (deletion scenario)
declare -a agg_cal=()           # per-trial calibration SYNC time
declare -a agg_sync_avg=()      # per-trial avg SYNC
declare -a agg_hist_size=()     # per-trial HISTORY du after 10 cycles

# ------------------------------------------------------------------
# 4. Trial loop (Phase 2.5)
# ------------------------------------------------------------------
for trial in $(seq 1 "$TRIALS"); do
    [ "$TRIALS" -gt 1 ] && echo "---------- Trial ${trial}/${TRIALS} ----------"

    # Reset per-trial state. First trial already has a fresh tree
    # (generated at setup); subsequent trials regen it to erase any
    # cross-trial residue.
    if [ "$trial" -gt 1 ]; then
        reset_data_dirs
        generate_tree
    fi

    # Per-trial seed: SEED for trial 1, SEED+trial-1 for later trials.
    # Each trial's delete_at_cycle is a deterministic function of its
    # own seed, so re-running with the same base SEED reproduces
    # exactly the same per-trial sequence of events.
    trial_seed=$((SEED + trial - 1))

    if [ "$SCENARIO" = "deletion" ]; then
        if [ -n "${DELETE_AT_CYCLE:-}" ]; then
            delete_at_cycle="$DELETE_AT_CYCLE"
        else
            RANDOM="$trial_seed"
            delete_at_cycle=$((3 + RANDOM % 6))
        fi
    fi

    # Calibration SYNC (once per trial — the fresh tree has never
    # been synced yet; measures the cold-first-run cost separately
    # from the warm cycle times).
    cal_start=$(date +%s.%N)
    backmeup.sh "$SOURCE_DIR" > /dev/null
    cal_end=$(date +%s.%N)
    cal_elapsed=$(awk "BEGIN{printf \"%.3f\", $cal_end - $cal_start}")
    agg_cal+=("$cal_elapsed")
    if awk "BEGIN{exit !($cal_elapsed > 2.5)}"; then
        echo "WARNING: trial ${trial} calibration SYNC ${cal_elapsed}s exceeds 2.5s"
    fi

    # Per-trial sim-loop state.
    pass=0
    fail=0
    declare -a sync_times=()
    deletion_recovery_elapsed=""

    # Buffer sleep: ensure the first cycle's edit has a visibly later
    # mtime than the calibration SYNC. Without this, a fast first
    # edit can land within rsync's mtime-comparison window and get
    # skipped as "unchanged" - a real property of rsync, not a sim
    # bug, that a human user won't hit because humans don't type
    # faster than rsync.
    sleep 1

    if [ "$SCENARIO" = "deletion" ]; then
        printf "Trial %d: seed=%d delete_at_cycle=%d target=%s\n" "$trial" "$trial_seed" "$delete_at_cycle" "$deletion_path"
    fi
# Determine per-file payload size from the preset (match the generator
# so overwrites keep the same size - rsync won't skip-on-size-match
# in that case; it still has to compare content via mtime+size).
case "$PRESET" in
    flat-few)  payload_size=1048566 ;;
    flat-many) payload_size=10200   ;;
    deep)      payload_size=102390  ;;
esac
for cycle in $(seq 1 $cycles); do
    # Edit each tracked file to version "v${cycle}". For the deletion
    # scenario: at cycle==delete_at_cycle, delete the target instead
    # of editing. After the deletion cycle, skip the target entirely.
    for entry in "${edit_files[@]}"; do
        label="${entry%%|*}"
        path="${entry#*|}"
        if [ "$SCENARIO" = "deletion" ] && [ "$label" = "$deletion_label" ]; then
            if [ "$cycle" -eq "$delete_at_cycle" ]; then
                rm "$SOURCE_DIR/$path"
                echo "cycle $cycle: deleted $path"
                sleep 2.5
                continue
            fi
            if [ "$cycle" -gt "$delete_at_cycle" ]; then
                continue   # file is gone; don't try to touch it
            fi
        fi
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

        # Deletion scenario: at the deletion cycle, run the three
        # recovery checks against the file we just deleted. After,
        # verify the file stays absent from SYNC.
        if [ "$SCENARIO" = "deletion" ] && [ "$label" = "$deletion_label" ]; then
            if [ "$cycle" -eq "$delete_at_cycle" ]; then
                expected_prev=$((cycle - 1))
                expected_history="file-${label}-v${expected_prev}"

                # (a) SYNC drops it.
                if [ -e "$SYNC_DIR/$project/$path" ]; then
                    echo "FAIL cycle=$cycle $path: SYNC still has deleted file"
                    fail=$((fail + 1))
                else
                    pass=$((pass + 1))
                fi

                # (b) HISTORY captures the pre-delete version.
                if [ -z "$latest_snapshot" ] || [ ! -f "$BACKUP_DIR/$project/$latest_snapshot/$path" ]; then
                    echo "FAIL cycle=$cycle $path: deleted file not in HISTORY snapshot"
                    fail=$((fail + 1))
                elif ! grep -q "^${expected_history}$" "$BACKUP_DIR/$project/$latest_snapshot/$path"; then
                    echo "FAIL cycle=$cycle $path: HISTORY wrong version (expected '$expected_history')"
                    fail=$((fail + 1))
                else
                    pass=$((pass + 1))
                fi

                # (c) retrieve pulls it back + content matches.
                scratch="/tmp/retrieve-$$"
                rm -rf "$scratch"
                recov_start=$(date +%s.%N)
                backmeup.retrieve.sh "$project" "$latest_snapshot" "$path" "$scratch" > /dev/null
                recov_end=$(date +%s.%N)
                deletion_recovery_elapsed=$(awk "BEGIN{printf \"%.3f\", $recov_end - $recov_start}")
                if [ -f "$scratch/$path" ] && grep -q "^${expected_history}$" "$scratch/$path"; then
                    pass=$((pass + 1))
                    echo "cycle $cycle: recovered $path from $latest_snapshot in ${deletion_recovery_elapsed}s"
                else
                    echo "FAIL cycle=$cycle $path: retrieve didn't recover the file (or content mismatch)"
                    fail=$((fail + 1))
                fi
                rm -rf "$scratch"
                continue
            fi

            if [ "$cycle" -gt "$delete_at_cycle" ]; then
                # File stays deleted from SYNC for the rest of the sim.
                if [ -e "$SYNC_DIR/$project/$path" ]; then
                    echo "FAIL cycle=$cycle $path: SYNC resurrected the deleted file"
                    fail=$((fail + 1))
                else
                    pass=$((pass + 1))
                fi
                continue
            fi
        fi

        # Baseline check path (used for the non-deletion-target file
        # on every cycle, and for the target before delete_at_cycle).
        expected_sync="file-${label}-v${cycle}"
        expected_prev=$((cycle - 1))
        expected_history="file-${label}-v${expected_prev}"

        if ! grep -q "^${expected_sync}$" "$SYNC_DIR/$project/$path"; then
            echo "FAIL cycle=$cycle $path: SYNC missing '$expected_sync'"
            fail=$((fail + 1))
            continue
        fi
        pass=$((pass + 1))

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

    # ---- Capture per-trial outcome into aggregate state ----
    trial_total=0
    for t in "${sync_times[@]}"; do
        trial_total=$(awk "BEGIN{printf \"%.3f\", $trial_total + $t}")
    done
    trial_avg=$(awk "BEGIN{printf \"%.3f\", $trial_total / ${#sync_times[@]}}")
    trial_hist=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    if [ "$fail" -eq 0 ]; then
        agg_pass=$((agg_pass + 1))
    else
        agg_fail=$((agg_fail + 1))
    fi
    agg_sync_avg+=("$trial_avg")
    agg_hist_size+=("$trial_hist")
    if [ "$SCENARIO" = "deletion" ]; then
        agg_cycles+=("$delete_at_cycle")
        agg_recoveries+=("$deletion_recovery_elapsed")
    fi

    printf "Trial %d: %d pass / %d fail, SYNC avg %ss, HISTORY %s" \
        "$trial" "$pass" "$fail" "$trial_avg" "$trial_hist"
    if [ "$SCENARIO" = "deletion" ]; then
        printf ", deletion cycle=%d recovered in %ss" "$delete_at_cycle" "$deletion_recovery_elapsed"
    fi
    printf "\n"
done   # <-- end for trial

echo

# ------------------------------------------------------------------
# 5. Aggregate report
# ------------------------------------------------------------------
echo "=== Results ==="
echo "Scenario:  ${SCENARIO}"
echo "Trials:    ${agg_pass}/${TRIALS} passed, ${agg_fail} failed"

if [ "$TRIALS" -gt 1 ]; then
    # Average per-trial SYNC avg + range of per-trial avgs.
    sum=0; min_v=99999; max_v=0
    for v in "${agg_sync_avg[@]}"; do
        sum=$(awk "BEGIN{printf \"%.3f\", $sum + $v}")
        awk "BEGIN{exit !($v > $max_v)}" && max_v="$v"
        awk "BEGIN{exit !($v < $min_v)}" && min_v="$v"
    done
    avg=$(awk "BEGIN{printf \"%.3f\", $sum / ${#agg_sync_avg[@]}}")
    echo "SYNC avg across trials: ${avg}s  (per-trial range ${min_v}s..${max_v}s)"
fi

if [ "$SCENARIO" = "deletion" ] && [ "${#agg_cycles[@]}" -gt 0 ]; then
    rsum=0; rmin=99999; rmax=0
    for v in "${agg_recoveries[@]}"; do
        rsum=$(awk "BEGIN{printf \"%.3f\", $rsum + $v}")
        awk "BEGIN{exit !($v > $rmax)}" && rmax="$v"
        awk "BEGIN{exit !($v < $rmin)}" && rmin="$v"
    done
    ravg=$(awk "BEGIN{printf \"%.3f\", $rsum / ${#agg_recoveries[@]}}")
    echo "Deletion recovery avg: ${ravg}s  (range ${rmin}s..${rmax}s)"
    echo -n "Per-trial cycles: "
    printf "%s " "${agg_cycles[@]}"
    echo
fi

if [ "$agg_fail" -eq 0 ]; then
    echo
    echo "PASS: all ${TRIALS} trial(s) passed."
    exit 0
else
    echo
    echo "FAIL: ${agg_fail}/${TRIALS} trial(s) failed."
    exit 1
fi
