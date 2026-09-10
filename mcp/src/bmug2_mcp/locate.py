"""Native reimplementation of backmeup.locate.sh, returning tagged,
structured hits instead of bare paths with an " (archived)" suffix.

Two deliberate differences from the shell version, both worth calling out
rather than silently diverging:

  - One locate subprocess call per pattern, not one call with all patterns
    bundled together. The shell version passes every pattern to a single
    `locate` invocation; while building this project's test suite we found
    that multi-pattern locate calls behave inconsistently across locate
    implementations (GNU findutils vs. plocate) - see the "one locate
    pattern per call" fix in the test suite history. Calling once per
    pattern sidesteps that entirely and gives clean per-pattern semantics.

  - The archived-filelist fallback uses a case-insensitive literal
    substring match, not grep -i's basic-regex semantics. An LLM-supplied
    search term is not guaranteed to be regex-safe, and "does this path
    contain this text" is what a search tool should mean here regardless.
    The indexed half still uses whatever matching rules the underlying
    `locate` binary itself implements - that's inherent to shelling out to
    it, not a choice made here.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from .config import Config
from .models import LocateCounts, LocateHit, LocateResult


def _run_locate(locate_cmd: str, db: Path, pattern: str) -> list[str]:
    if not db.is_file():
        return []
    result = subprocess.run(
        [locate_cmd, "-i", "-d", str(db), pattern],
        capture_output=True,
        text=True,
        check=False,
    )
    return [line for line in result.stdout.splitlines() if line]


def _archived_filelist_hits(config: Config, patterns: list[str]) -> list[str]:
    hits: list[str] = []
    if not config.history_dir.is_dir():
        return hits
    lowered_patterns = [p.lower() for p in patterns]
    for filelist in sorted(config.history_dir.glob("*/B-*.filelist")):
        snapshot_dir = filelist.with_suffix("")
        if snapshot_dir.is_dir():
            # Snapshot still on disk (not archived yet) - the indexed
            # half already covers it, same as the shell version's
            # "[ -d ... ] && continue" guard.
            continue
        try:
            lines = filelist.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line:
                continue
            lowered = line.lower()
            if any(p in lowered for p in lowered_patterns):
                # `line` is already relative to history_dir: bin/backmeup.
                # archive.sh generates each .filelist via
                # `cd "$BMU_DIRBACKUPS" && find "$project/$snapshot"`, so
                # this join isn't a coincidence - it depends on that.
                hits.append(str(config.history_dir / line))
    return hits


def _live_filelist_hits(config: Config, patterns: list[str]) -> list[str]:
    """Every project's live filelist (HISTORY/<project>.filelist, flat -
    not the nested HISTORY/<project>/B-<date>.filelist snapshots
    _archived_filelist_hits reads) is refreshed by bin/backmeup.sh on
    every successful run, so a file backed up seconds ago is findable
    here immediately - unlike the locate index above, which is only
    ever rebuilt by the separate, slower backmeup.updatedb.sh.
    """
    hits: list[str] = []
    if not config.history_dir.is_dir():
        return hits
    lowered_patterns = [p.lower() for p in patterns]
    for filelist in sorted(config.history_dir.glob("*.filelist")):
        try:
            lines = filelist.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line:
                continue
            lowered = line.lower()
            if any(p in lowered for p in lowered_patterns):
                # `line` is relative to sync_dir: bin/backmeup.sh writes
                # each live filelist via `cd "$BMU_DIRRSYNC" && find
                # "$project"`.
                hits.append(str(config.sync_dir / line))
    return hits


def do_locate(config: Config, patterns: list[str]) -> LocateResult:
    indexed = bool(config.locate_cmd) and config.index_dir is not None
    index_hits: list[str] = []
    if indexed:
        # Narrows the Optional[...] types for the type checker - `indexed`
        # being true already guarantees both, this doesn't re-check anything.
        assert config.index_dir is not None
        assert config.locate_cmd is not None
        for pattern in patterns:
            for db_name in (".locate.db", ".locate.dbb"):
                index_hits.extend(
                    _run_locate(config.locate_cmd, config.index_dir / db_name, pattern)
                )

    live_hits = _live_filelist_hits(config, patterns)
    archived_hits = _archived_filelist_hits(config, patterns)

    results = [LocateHit(path=p, source="index") for p in index_hits]
    results.extend(LocateHit(path=p, source="live") for p in live_hits)
    results.extend(LocateHit(path=p, source="archived_filelist") for p in archived_hits)

    return LocateResult(
        patterns=patterns,
        indexed=indexed,
        counts=LocateCounts(
            index=len(index_hits), archived_filelist=len(archived_hits), live=len(live_hits)
        ),
        results=results,
    )
