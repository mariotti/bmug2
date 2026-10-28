# bmug2 dev-ops helpers.
#
# Primary workflow is still install.sh + the backmeup.*.sh scripts;
# this Makefile only covers extra tooling that doesn't fit inside
# those. Currently: Lima-based RPM-install smoke tests on real
# RPM-family distros, run after an experimental release and before
# promoting it to a plain (non-experimental) tag.
#
# Prerequisites for the test-rpm-* targets:
#   - Lima installed (`brew install lima`)
#   - gh CLI authenticated (for `gh release download`)
#   - A v$(VERSION)-experimental release with matching .rpm assets
#     attached (see .github/workflows/gui-release.yml)

# Auto-detected from the configure script's own BMU_VERSION. Override
# with VERSION=X.Y.Z on the command line to test a specific release.
VERSION ?= $(shell grep -E '^BMU_VERSION=' bin/backmeup.configure.sh | head -1 | sed 's/.*="\([^"]*\)".*/\1/')

# Native-arch default: Apple Silicon → aarch64, Intel → x86_64.
# Override with ARCH=... if you want to cross-test (slow under
# emulation; the Lima aarch64 templates work natively on Apple
# Silicon's VZ backend, so that's the fast path).
ARCH ?= $(shell uname -m | sed 's/arm64/aarch64/')

# Per-VM resource shaping. Lima's defaults (4 CPUs / 4 GiB / 100 GiB)
# are generous for arbitrary workloads; this test only needs enough
# to run dnf install of ~290 packages (mostly webkit/gtk deps) and
# a few rpm queries. Measured: ~7 GB disk, ~1.5 GB peak RAM, barely
# scales past 2 CPUs. Dropping memory in particular is the biggest
# host-friendly win because VZ pins the declared RAM for the VM's
# whole lifetime (not reclaimable), so a 2 GiB VM leaves 2 GiB more
# on the host vs the default 4 GiB. Units are GiB throughout.
CPUS ?= 2
MEMORY ?= 2
DISK ?= 20

.PHONY: help test-rpm-fedora test-rpm-rocky test-rpm-alma test-rpm-all test-rpm-clean

help:
	@echo "bmug2 Makefile targets"
	@echo ""
	@echo "  test-rpm-fedora   Install bmug2 v$(VERSION) $(ARCH) .rpm on a Fedora Lima VM"
	@echo "  test-rpm-rocky    Same, on Rocky Linux"
	@echo "  test-rpm-alma     Same, on AlmaLinux"
	@echo "  test-rpm-all      Run all three in sequence"
	@echo "  test-rpm-clean    Delete every Lima VM this Makefile created"
	@echo ""
	@echo "  Variables (overridable):"
	@echo "    VERSION=$(VERSION)"
	@echo "    ARCH=$(ARCH)"
	@echo "    CPUS=$(CPUS)        # VM vCPUs"
	@echo "    MEMORY=$(MEMORY)    # VM RAM, GiB (biggest host-cost knob: VZ pins this)"
	@echo "    DISK=$(DISK)       # VM disk cap, GiB (sparse: actual use ~7 GB)"
	@echo ""
	@echo "  Examples:"
	@echo "    make test-rpm-fedora"
	@echo "    make test-rpm-fedora VERSION=2.18.13"
	@echo "    make test-rpm-fedora CPUS=4 MEMORY=4    # all-out run"
	@echo "    make test-rpm-all"

test-rpm-fedora:
	CPUS=$(CPUS) MEMORY=$(MEMORY) DISK=$(DISK) tools/test-rpm-via-lima.sh fedora $(VERSION) $(ARCH)

test-rpm-rocky:
	CPUS=$(CPUS) MEMORY=$(MEMORY) DISK=$(DISK) tools/test-rpm-via-lima.sh rocky $(VERSION) $(ARCH)

test-rpm-alma:
	CPUS=$(CPUS) MEMORY=$(MEMORY) DISK=$(DISK) tools/test-rpm-via-lima.sh almalinux $(VERSION) $(ARCH)

test-rpm-all: test-rpm-fedora test-rpm-rocky test-rpm-alma
	@echo "All three RPM-family distros installed bmug2 v$(VERSION) ($(ARCH)) cleanly."

test-rpm-clean:
	@# Glob over the `bmug2-rpmtest-` prefix because the per-run VM names
	@# include a PID suffix for parallel-safety (bmug2-rpmtest-<distro>-<pid>).
	@# `limactl list -q` emits one name per line; the pipeline is a no-op
	@# if none match (xargs -r is GNU-only, so testing emptiness explicitly).
	@vms="$$(limactl list -q 2>/dev/null | grep '^bmug2-rpmtest-' || true)"; \
	if [ -z "$$vms" ]; then \
	    echo "No bmug2-rpmtest-* VMs to clean."; \
	else \
	    echo "Deleting: $$vms"; \
	    echo "$$vms" | xargs limactl stop 2>/dev/null || true; \
	    echo "$$vms" | xargs limactl delete 2>/dev/null || true; \
	fi
