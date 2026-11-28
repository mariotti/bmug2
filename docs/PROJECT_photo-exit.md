# Project: photo-exit

A planning doc, not a spec. Captures a new product direction built
on top of bmug2's shell backend: a dedicated tool for users
migrating OUT of iCloud / Google Photos / OneDrive, who need to
trust that their local copy actually contains everything they had
in the cloud, in full fidelity. Phases are deliberately
independent: Phase 1 is read-only confidence; later phases add
action.

## Status

- **Phase 1 — Scan + confidence report**: proposed, awaiting the
  decisions at the bottom of this doc.
- **Phases 2+**: sketched, not committed on.

## Why this is a different product from bmug2

bmug2 is an **ongoing backup tool**: it runs on a schedule, mirrors
to a drive, keeps history. Users who adopt it are in "I need to
protect what I have" mode.

Photo-exit users are in a different mode: **"I'm trapped in a
walled-garden photo cloud and I want out — without losing or
silently downgrading anything."** It's a one-shot migration with a
sharp before/after. The mental model is "import, verify, keep the
originals, cancel the subscription." Different funnel, different
onboarding, different success metric.

Trying to do both in the same app would dilute both:

- bmug2's identity as a backup tool blurs into "photo app"
- Photo-exit users wouldn't find it under "backup tool" searches
- Settings, dashboards, and language fight each other

So: **photo-exit ships as a separate application**, with its own
installer, its own Tauri binary, its own UI. It reuses bmug2's
shell backend for anything they share (file walking, hashing,
sidecar reads, verification primitives). New photo-specific logic
(EXIF parsing, classification, duplicate detection) lives in new
shell scripts under `bin/` and new Rust helpers that bundle
alongside.

### Core architectural decision: shared shell backend, two UIs

Locked 2026-11-28.

The shell CLI layer stays the single source of truth for operations.
Photo-exit adds new scripts under `bin/` following the same
conventions as the rest of bmug2:

- POSIX `/bin/sh`
- Read-only + warn-only (even stricter here: Phase 1 does no writes
  at all, not even sidecars)
- JSON output on stdout with `--json` flag
- Testable from `tests/test_backmeup.sh`

Both the main bmug2 GUI and the new photo-exit GUI talk to the same
shell layer via `Command::new()`. The two GUIs are separate Tauri
crates (likely `gui/` and `gui-photo-exit/` as siblings),
independently versioned and released. This also leaves the door
open for a third UI later (web, mobile) without rewriting backends.

The cost of this split is real but modest: one extra Tauri setup,
one extra release workflow, one extra installer matrix. The payoff
is product clarity — each app can be onboarded, marketed, and
evolved without the other.

## Phase 1 — Scan + confidence report

**Scope**: read-only analysis of a photo library (iCloud sync
folder, Google Takeout extraction, Photos.app library bundle,
generic directory). Output: a confidence report the user can read
before deciding whether to cancel their cloud subscription.

### What Phase 1 answers

1. **Can every photo be read right now?** EXIF parse per file; flag
   anything unreadable so bit-rot / silent corruption shows up
   before the user commits to the migration.
2. **Are these originals or cloud-downgraded derivatives?** Camera
   EXIF presence + resolution + file size per format are strong
   signals. iCloud's "Optimize Mac Storage" silently replaces
   originals with downsized versions; users often don't know.
3. **Is the chronology coherent?** Range of `DateTimeOriginal`,
   outliers (photos dated 1970 or 2099), count of files with no
   date-taken.
4. **How many duplicates are there, roughly?** Same
   `DateTimeOriginal + camera + size bucket` within a 2-second
   window. Perceptual-hash dedupe is Phase 2; this is the cheap
   EXIF-only signal.
5. **What's in this library, in one page?** Format mix (JPEG /
   HEIC / RAW / PNG), count, total bytes, oldest/newest date-taken,
   camera list, GPS-tagged count.

### What Phase 1 does NOT do

- No copy, no move, no delete, no format conversion.
- No sidecar writes, no new config files, no state on disk.
- No perceptual hashing (visual similarity). Phase 2.
- No OCR / face detection / AI anything.

Strictly read-only is both a safety stance and a scope-control
one. The user gets a trustworthy health check first; Phase 2+
build on it.

### Shell layer: new scripts

- `backmeup.photo-scan.sh <dir>` — walks the directory, emits one
  JSON line per photo (file path, size, parsed EXIF fields, parse
  status). Streams output so a 50k-photo scan shows progress.
- `backmeup.photo-report.sh <dir>` — calls scan, aggregates into a
  single summary JSON answering the five questions above.

The actual EXIF parsing is delegated to a small bundled Rust binary
(`bmug2-exif-scan`) using the `kamadak-exif` crate. Shell
orchestrates the walk + aggregation; Rust does the per-file parse.
This matches how existing scripts like `backmeup.locate.sh` already
delegate to system binaries for operations POSIX sh can't do.

Reason for Rust (not `exiftool`): zero system-dep install step, and
a 50k-photo scan completes in seconds rather than minutes.

### GUI layer: new Tauri app

A new `gui-photo-exit/` directory with its own Tauri setup:

- **Welcome**: "Point me at your photo library. I'll tell you
  what's actually there."
- **Scan progress**: live count, current directory, parse errors.
- **Report**: tabs for Overview / Classification / Chronology /
  Duplicates / Issues. Each tab is a view on the same scan JSON.
- **Export**: save the report as JSON / CSV for later reference.

Separate installer naming scheme:
`photo-exit_<version>_<arch>.{dmg,deb,rpm,AppImage}`. Separate
release workflow. Separate versioning (starts at `0.1.0-experimental`,
follows bmug2's odd=experimental convention).

### Phase 1 deliverables

1. Two new shell scripts + the Rust `bmug2-exif-scan` helper under
   `bin/` (or a sibling `exif-scan/` crate), with tests in
   `tests/test_backmeup.sh`.
2. New `gui-photo-exit/` Tauri app with the four pages above.
3. New release workflow at `.github/workflows/photo-exit-release.yml`
   that produces 7 installers on the same matrix as bmug2.
4. New onboarding doc `docs/GETTING_STARTED_photo-exit.md` targeted
   at the "I want out of iCloud" user, in the same spirit as
   `docs/GETTING_STARTED.md`.

## Later phases (sketched, not committed)

- **Phase 2 — Perceptual duplicate detection**: visual-similarity
  clustering (pHash/dHash) on top of EXIF-based grouping. Needed
  for real dedupe on libraries where the same photo has ten
  slightly-different exports (WhatsApp recompressions, social
  downloads, etc.).
- **Phase 3 — Import with verify**: copy from source into a
  destination directory, hash every file before and after, replay
  the scan on the destination, assert exact-match on
  count/sizes/EXIF. Produces a cryptographic "migration receipt" the
  user can trust before cancelling their cloud subscription.
- **Phase 4 — Format preservation policy**: user-controlled rules
  for HEIC → JPEG conversion with originals kept, RAW retention,
  etc. Reuses bmug2's budget/policy sidecar pattern.
- **Phase 5 — Cross-source consolidation**: scan multiple libraries
  (iCloud + Google Takeout + old iPhoto + a NAS folder from 2015),
  produce a unified dedup'd archive with full provenance.

Phase 2+ shape will be driven by what Phase 1's reports actually
reveal about typical libraries.

## Decisions needed before Phase 1 implementation

1. **Repo layout**: new Tauri crate as a sibling `gui-photo-exit/`
   directory in this repo (monorepo), or a separate repo
   altogether? Monorepo is simpler for shared-shell-backend
   iteration; separate repo makes the product-separation clearer
   to outside users and avoids diluting the bmug2 repo's
   positioning.
2. **App name**: "photo-exit" is a working label, not a product
   name. Candidates: "bmug2 photo salvage", "photovault",
   "exilib", "lockpick" (play on walled-garden). Marketing-side
   decision.
3. **Supported inputs for Phase 1**: pick the subset. Options:
   (a) generic directory — easy, covers most cases; (b) Google
   Takeout extraction — needs the sidecar JSON handling; (c)
   Apple `.photoslibrary` bundle — opaque, needs reverse
   engineering of the internal SQLite; (d) iCloud sync folder on
   disk — same as (a) if the user has "Download Originals"
   enabled. Recommendation: start with (a) + (b); add (c) in a
   later phase if demand is there.
4. **EXIF parsing crate**: `kamadak-exif` is Rust-native, actively
   maintained, good JPEG/HEIC/TIFF coverage. Alternative is
   binding to `exiv2` (C++, more formats including some RAWs,
   bigger dep chain + build complexity). Recommendation:
   `kamadak-exif` for Phase 1; revisit if RAW coverage becomes a
   blocker for real users.
5. **Release cadence**: tie photo-exit releases to bmug2 shell
   changes, or release independently? Shared shell backend means
   any shell change that affects photo-exit forces a photo-exit
   rebuild — but a photo-exit-only UI change shouldn't need a
   bmug2 release. Recommendation: independent cadence, both pull
   from `main`; releases are tagged with their own `photo-exit-vX.Y.Z`
   prefix.
