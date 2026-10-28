#!/bin/bash
# Phase 1 baseline sim — host orchestrator.
# Starts a fresh Fedora Lima VM, runs sim-inside-vm.sh, tears down.
#
# Driven from the Makefile (`make test-sim-baseline`), which passes
# BMUG2_SOURCE=$(CURDIR). Running directly also works: set
# BMUG2_SOURCE to the bmug2 repo root, or let the fallback resolve
# it from this script's own location.

set -euo pipefail

# Resolve the sim dir + repo root from this script's own location,
# so running `bash tools/sim/run-baseline.sh` from any cwd works.
sim_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$sim_dir/../.." && pwd)"
inside_script="$sim_dir/sim-inside-vm.sh"

# Default BMUG2_SOURCE to the resolved repo root. Overridable so a
# developer testing against a different checkout can point it there.
BMUG2_SOURCE="${BMUG2_SOURCE:-$repo_root}"

vm="bmug2-sim-fedora-$$"

command -v limactl >/dev/null || { echo "ERROR: lima not installed. 'brew install lima' first."; exit 1; }
[ -r "$inside_script" ] || { echo "ERROR: $inside_script not found."; exit 1; }
[ -d "$BMUG2_SOURCE" ] || { echo "ERROR: BMUG2_SOURCE=$BMUG2_SOURCE not found."; exit 1; }

trap 'echo "==> Cleaning up VM $vm..."; limactl stop "$vm" 2>/dev/null || true; limactl delete "$vm" 2>/dev/null || true' EXIT

echo "==> Starting Lima VM $vm (fedora, 2 CPU / 2 GiB / 20 GiB)..."
limactl start --name="$vm" --cpus=2 --memory=2 --disk=20 template://fedora

echo "==> Running Phase 1 baseline sim inside VM..."
# $BMUG2_SOURCE is a host-side path; Lima mounts the host $HOME at
# the same path inside the VM, so this path works inside too. The
# guest's own $HOME is `/home/mariotti.guest`, a DIFFERENT path — the
# inside script explicitly uses BMUG2_SOURCE, not $HOME.
limactl shell --workdir "$HOME" "$vm" -- \
    env BMUG2_SOURCE="$BMUG2_SOURCE" bash "$inside_script"
