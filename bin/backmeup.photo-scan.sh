#! /bin/sh
#
# Thin shell wrapper around the bmug2-exif-scan Rust binary
# (exif-scan/ crate). Walks a directory recursively and emits one
# JSON line (NDJSON) per photo to stdout. See the crate's README and
# docs/PROJECT_photo-exit.md for the record shape.
#
#   usage: backmeup.photo-scan.sh <directory>
#
# This script exists so every shell-level caller (including
# backmeup.photo-report.sh, future test harnesses, and ad-hoc CLI
# use) resolves the binary in one place. The Rust binary is not yet
# installed by install.sh - at the moment it must be on PATH, pointed
# to by $BMUG2_EXIF_SCAN_BIN, dropped next to this script, or built
# in the repo's exif-scan/ release target.
#
# Resolution order:
#   1. $BMUG2_EXIF_SCAN_BIN if set and executable
#   2. "bmug2-exif-scan" on $PATH
#   3. ${script_dir}/bmug2-exif-scan        (future packaged layout)
#   4. ${script_dir}/../exif-scan/target/release/bmug2-exif-scan (dev)
#
MY_PATH="`dirname \"$0\"`"
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"
if [ -z "$MY_PATH" ] ; then
  exit 1
fi

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat <<EOF >&2
usage: $0 <directory>

Walks <directory> recursively and emits one JSON line (NDJSON) per
photo to stdout. Non-photo files are silently skipped; parse errors
are surfaced as records with parse_status="parse_error".

See backmeup.photo-report.sh for aggregated summary output.
EOF
    case "$1" in -h|--help) exit 0 ;; esac
    exit 2
fi

if [ -n "${BMUG2_EXIF_SCAN_BIN}" ] && [ -x "${BMUG2_EXIF_SCAN_BIN}" ]; then
    BIN="${BMUG2_EXIF_SCAN_BIN}"
elif command -v bmug2-exif-scan >/dev/null 2>&1; then
    BIN="bmug2-exif-scan"
elif [ -x "${MY_PATH}/bmug2-exif-scan" ]; then
    BIN="${MY_PATH}/bmug2-exif-scan"
elif [ -x "${MY_PATH}/../exif-scan/target/release/bmug2-exif-scan" ]; then
    BIN="${MY_PATH}/../exif-scan/target/release/bmug2-exif-scan"
else
    echo "backmeup.photo-scan.sh: bmug2-exif-scan not found; set BMUG2_EXIF_SCAN_BIN or put it on PATH" >&2
    exit 1
fi

exec "${BIN}" "$1"
