# exif-scan

bmug2 photo-exit — read-only EXIF scanner. Walks a directory
recursively, parses EXIF metadata from each photo it finds, and
emits one JSON line (NDJSON) per photo to stdout.

Standalone binary, no configuration, no state on disk, no writes
anywhere. Part of the [photo-exit project](../docs/PROJECT_photo-exit.md)
(Phase 1); the main `bmug2` backup tool does not depend on this crate.

## Usage

```sh
bmug2-exif-scan /path/to/photo/library
```

Emits one JSON record per supported file to stdout. Non-photo files
are silently skipped. Parse errors are surfaced as records with
`parse_status: "parse_error"`.

Supported extensions (case-insensitive):
`jpg jpeg heic heif png tiff tif dng arw cr2 cr3 nef raf orf rw2`.

## Output shape

```json
{
  "path": "/abs/path/to/IMG_0001.heic",
  "size_bytes": 3145728,
  "format": "HEIC",
  "exif": {
    "date_taken": "2024:03:15 14:22:11",
    "camera_make": "Apple",
    "camera_model": "iPhone 15 Pro",
    "width": 4032,
    "height": 3024,
    "gps_present": true,
    "orientation": 6
  },
  "parse_status": "ok"
}
```

Fields in `exif` are all optional (`None`-valued fields are omitted).
`gps_present` is a boolean — Phase 1 does not surface coordinates
themselves, only that a GPS tag is present. `parse_status` is one of
`ok`, `no_exif`, or `parse_error`.

## Build

```sh
cargo build --release --manifest-path exif-scan/Cargo.toml
```

Binary lands at `exif-scan/target/release/bmug2-exif-scan`.

## Test

```sh
cargo test --manifest-path exif-scan/Cargo.toml
```
