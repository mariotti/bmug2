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
	@echo ""
	@echo "  Examples:"
	@echo "    make test-rpm-fedora"
	@echo "    make test-rpm-fedora VERSION=2.18.13"
	@echo "    make test-rpm-all"

test-rpm-fedora:
	tools/test-rpm-via-lima.sh fedora $(VERSION) $(ARCH)

test-rpm-rocky:
	tools/test-rpm-via-lima.sh rocky $(VERSION) $(ARCH)

test-rpm-alma:
	tools/test-rpm-via-lima.sh almalinux $(VERSION) $(ARCH)

test-rpm-all: test-rpm-fedora test-rpm-rocky test-rpm-alma
	@echo "All three RPM-family distros installed bmug2 v$(VERSION) ($(ARCH)) cleanly."

test-rpm-clean:
	-limactl stop   bmug2-rpmtest-fedora bmug2-rpmtest-rocky bmug2-rpmtest-almalinux 2>/dev/null || true
	-limactl delete bmug2-rpmtest-fedora bmug2-rpmtest-rocky bmug2-rpmtest-almalinux 2>/dev/null || true
	@echo "Deleted any Lima VMs this Makefile created (unknown-VM errors are harmless)."
