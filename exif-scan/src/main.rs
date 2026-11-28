use std::env;
use std::io::{self, Write};
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args.first().map(String::as_str).unwrap_or("bmug2-exif-scan");

    if args.len() != 2 || args[1] == "-h" || args[1] == "--help" {
        let usage = format!(
            "usage: {} <directory>\n\n\
             Walks <directory> recursively, parses EXIF from each photo it finds,\n\
             and emits one JSON line (NDJSON) per photo to stdout. Non-photo files\n\
             and files it can't stat are silently skipped; parse errors are\n\
             surfaced as JSON records with parse_status=\"parse_error\".\n\n\
             Supported extensions (case-insensitive): jpg jpeg heic heif png tiff\n\
             tif dng arw cr2 cr3 nef raf orf rw2.\n",
            program
        );
        if args.len() == 2 && (args[1] == "-h" || args[1] == "--help") {
            let _ = io::stdout().write_all(usage.as_bytes());
            process::exit(0);
        }
        let _ = io::stderr().write_all(usage.as_bytes());
        process::exit(2);
    }

    let dir = &args[1];
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    if let Err(e) = exif_scan::scan_dir(dir, &mut handle) {
        let _ = writeln!(io::stderr(), "bmug2-exif-scan: {}", e);
        process::exit(1);
    }
}
