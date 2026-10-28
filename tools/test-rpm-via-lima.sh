#!/bin/bash
# Spin up a Lima VM for an RPM-family distro, install the specified
# bmug2 .rpm via dnf, verify the signature imported from the committed
# docs/bmug2-releases.asc, and confirm the installed package manifest
# matches on disk. Smoke-tests only what's useful without an X server:
# a Lima VM is headless, so launching the Tauri GUI binary itself isn't
# attempted - the real "does the window open" test stays manual.
#
# Usage: $0 <template> <version> <arch>
#   $1 = Lima template name (fedora | rocky | almalinux)
#   $2 = bmug2 version       (e.g. 2.18.13)
#   $3 = architecture        (aarch64 | x86_64 - must match an uploaded asset)
#
# Called from the Makefile's test-rpm-{fedora,rocky,almalinux} targets;
# nothing stops running it directly if you want finer control.
#
# Prerequisites (checked up front, with actionable error messages):
#   - Lima installed:   `brew install lima`
#   - gh authenticated: `gh auth login`
#   - A v<version>-experimental release exists on github.com/mariotti/bmug2
#     with a matching bmug2-<version>-1.<arch>.rpm asset attached.

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <template> <version> <arch>" >&2
    exit 2
fi

distro="$1"
version="$2"
arch="$3"

vm="bmug2-rpmtest-${distro}"
rpm="bmug2-${version}-1.${arch}.rpm"
tag="v${version}-experimental"

# Lima's default template mounts $HOME read-only, so the host-side
# download has to live under $HOME to be visible inside the VM. (The
# /tmp mount in Lima templates is per-VM, not shared with host /tmp.)
work="${HOME}/.cache/bmug2-rpmtest/${distro}-${version}"

# Up-front sanity checks - fail with an actionable message rather than
# halfway through a VM boot.
if ! command -v limactl >/dev/null; then
    echo "ERROR: Lima is not installed." >&2
    echo "  Install:  brew install lima" >&2
    exit 1
fi

if ! command -v gh >/dev/null; then
    echo "ERROR: gh CLI not installed - needed to download release assets." >&2
    echo "  Install:  brew install gh && gh auth login" >&2
    exit 1
fi

# Download the RPM once per (distro, version). The .cache location is
# predictable and swept-aware - matches the project's "known names, not
# scattered /tmp paths" convention.
mkdir -p "$work"
if [ ! -f "$work/$rpm" ]; then
    echo "==> Downloading $rpm from $tag..."
    gh release download "$tag" --repo mariotti/bmug2 --pattern "$rpm" --dir "$work"
else
    echo "==> Reusing cached $work/$rpm."
fi

# Start the VM. Idempotent: if it already exists and is running, no-op;
# if it exists but is stopped, start it; if it doesn't exist, create.
echo "==> Preparing Lima VM: $vm (template://$distro)..."
if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$vm"; then
    status=$(limactl list --format '{{.Status}}' "$vm")
    if [ "$status" != "Running" ]; then
        limactl start "$vm"
    fi
else
    limactl start --name="$vm" "template://$distro"
fi

# Always stop the VM on exit (success OR failure) so a run doesn't
# leave a 4-CPU/4GiB/100GiB VM idling after the test completes - the
# project's clean-environment discipline. Config + disk are preserved
# (fast restart next run); full deletion stays behind
# `make test-rpm-clean`. If the test fails and you want to inspect,
# `limactl start $vm` resumes with everything the install left behind.
trap 'echo "==> Stopping Lima VM: $vm (preserved for fast restart; make test-rpm-clean to delete)..."; limactl stop "$vm" 2>/dev/null || true' EXIT

# Run the install + verification inside the VM. $HOME on the host is
# mounted at the same path inside the VM (Lima's default), so $work is
# directly accessible.
echo "==> Importing public key, verifying signature, installing..."
limactl shell "$vm" -- bash -euxo pipefail <<REMOTE
sudo rpm --import https://raw.githubusercontent.com/mariotti/bmug2/main/docs/bmug2-releases.asc

# Signature check against rpm's trust db (not just gpg's). Expect
# "digests signatures OK".
sudo rpm --checksig "$work/$rpm"

# Real install - pulls in webkit2gtk/gtk/appindicator deps the first
# time (couple minutes on a fresh cloud image, cached afterwards).
sudo dnf install -y "$work/$rpm"

# Package is registered. rpm -q <name> is a direct lookup rather than
# the previous "rpm -qa | grep" pipeline, which raced dnf5's commit-
# visibility window on Fedora 44 (verified on a real Lima run: the
# pipeline returned no match immediately after dnf's "Complete!"
# message, even though the package WAS registered a moment later).
rpm -q bmug2 > /dev/null || { echo "ERROR: bmug2 not in rpm db after install"; exit 1; }

# All installed files still match the RPM's manifest (catches a mangled
# install - no .5. prefix on verify output = all good).
rpm -V bmug2 || { echo "ERROR: rpm -V bmug2 flagged file mismatches"; exit 1; }

# NOT run: the GUI binary itself. A Lima VM is headless (no X), so
# launching Tauri's bmug2 window isn't meaningful here. Verifying the
# window actually opens stays a manual pre-release step - run the
# .dmg/.deb/.AppImage/.rpm on a real desktop or a Linux VM with a
# display server before promoting.
REMOTE

echo "==> OK: $distro installed bmug2 v$version ($arch) cleanly."
