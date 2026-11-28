#! /bin/sh
#
# Phase 1 photo-exit confidence report. Aggregates NDJSON output
# from backmeup.photo-scan.sh into a summary JSON answering the
# five questions in docs/PROJECT_photo-exit.md:
#
#   1. Can every photo be read? -> by_parse_status
#   2. Originals vs derivatives? -> cameras + by_format (indirect;
#      Phase 2 will add explicit classification)
#   3. Is the chronology coherent? -> date_range
#   4. How many duplicates? -> deferred to Phase 2 (needs clustering)
#   5. What's in this library in one page? -> all of the above plus
#      total_count / total_bytes / gps_count
#
#   usage: backmeup.photo-report.sh <directory>
#
# Output: one JSON object on stdout with these top-level keys:
#   total_count       - number of photo records scanned
#   total_bytes       - sum of file sizes
#   by_parse_status   - {ok, no_exif, parse_error}
#   by_format         - {JPEG: N, HEIC: N, ...} only formats seen
#   cameras           - {"Apple": N, ...} by camera_make
#   date_range        - {earliest, latest, with_date, without_date}
#                       or null if nothing was dated
#   gps_count         - number of records with gps_present=true
#   parse_errors      - array of paths that failed to parse
#
# This script never writes to disk and never follows symlinks beyond
# whatever the wrapped bmug2-exif-scan binary does (currently: no
# symlink following).
#
MY_PATH="`dirname \"$0\"`"
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"
if [ -z "$MY_PATH" ] ; then
  exit 1
fi

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat <<EOF >&2
usage: $0 <directory>

Scans <directory> and emits a summary JSON report.

See docs/PROJECT_photo-exit.md for the Phase 1 scope and the
field-by-field meaning of each report key.
EOF
    case "$1" in -h|--help) exit 0 ;; esac
    exit 2
fi

"${MY_PATH}/backmeup.photo-scan.sh" "$1" | awk '
BEGIN {
    total_count = 0; total_bytes = 0
    ok = 0; no_exif = 0; parse_err = 0; gps = 0
    with_date = 0; min_date = ""; max_date = ""
    fmt_count = 0; cam_count = 0; err_count = 0
}
/^[[:space:]]*$/ { next }
{
    total_count++
    if (match($0, /"size_bytes":[0-9]+/)) {
        total_bytes += substr($0, RSTART+13, RLENGTH-13) + 0
    }
    if (index($0, "\"parse_status\":\"ok\"")) ok++
    else if (index($0, "\"parse_status\":\"no_exif\"")) no_exif++
    else if (index($0, "\"parse_status\":\"parse_error\"")) {
        parse_err++
        if (match($0, /"path":"[^"]+"/)) {
            err_paths[++err_count] = substr($0, RSTART+8, RLENGTH-9)
        }
    }
    if (match($0, /"format":"[^"]+"/)) {
        f = substr($0, RSTART+10, RLENGTH-11)
        if (!(f in fmts)) { fmts[f] = 0; fmt_keys[++fmt_count] = f }
        fmts[f]++
    }
    if (index($0, "\"gps_present\":true")) gps++
    if (match($0, /"date_taken":"[^"]+"/)) {
        d = substr($0, RSTART+14, RLENGTH-15)
        with_date++
        if (min_date == "" || d < min_date) min_date = d
        if (max_date == "" || d > max_date) max_date = d
    }
    if (match($0, /"camera_make":"[^"]+"/)) {
        c = substr($0, RSTART+15, RLENGTH-16)
        if (!(c in cams)) { cams[c] = 0; cam_keys[++cam_count] = c }
        cams[c]++
    }
}
END {
    printf "{"
    printf "\"total_count\":%d,", total_count
    printf "\"total_bytes\":%d,", total_bytes
    printf "\"by_parse_status\":{\"ok\":%d,\"no_exif\":%d,\"parse_error\":%d},", ok, no_exif, parse_err
    printf "\"by_format\":{"
    sep = ""
    for (i = 1; i <= fmt_count; i++) { k = fmt_keys[i]; printf "%s\"%s\":%d", sep, k, fmts[k]; sep = "," }
    printf "},"
    printf "\"cameras\":{"
    sep = ""
    for (i = 1; i <= cam_count; i++) { k = cam_keys[i]; printf "%s\"%s\":%d", sep, json_escape(k), cams[k]; sep = "," }
    printf "},"
    if (with_date > 0) {
        printf "\"date_range\":{\"earliest\":\"%s\",\"latest\":\"%s\",\"with_date\":%d,\"without_date\":%d},",
            min_date, max_date, with_date, (total_count - with_date)
    } else {
        printf "\"date_range\":null,"
    }
    printf "\"gps_count\":%d,", gps
    printf "\"parse_errors\":["
    sep = ""
    for (i = 1; i <= err_count; i++) { printf "%s\"%s\"", sep, json_escape(err_paths[i]); sep = "," }
    printf "]"
    printf "}\n"
}
function json_escape(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\n/, "\\n", s)
    gsub(/\t/, "\\t", s)
    return s
}
'
