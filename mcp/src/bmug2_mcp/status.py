"""Native reimplementation of backmeup.status.sh, returning structured data
instead of a padded text table.

Mirrors the shell script's exact logic (see bin/backmeup.status.sh) so the
two stay behaviorally equivalent - deliberately, not just "close enough":

  - snapshot_count only counts B-<date> *directories* (a glob of `B-*/`
    in the shell version), matching that archived snapshots (tar.gz, no
    directory) don't count - same as the original.
  - old_layout uses the identical check backmeup.migrate.sh itself uses:
    a nested <project>/<project> directory AND nothing else inside the
    project directory (ls -A count == 1).

One deliberate difference: sizes are a plain recursive sum of file sizes
computed directly, not `du -sh`'s disk-block usage - see the docstring
on StatusProject.mirror_size_bytes.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from .config import Config
from .models import StatusProject, StatusResult

_SNAPSHOT_STRFTIME = "%Y%m%d-%H%M%S"
_LASTRUN_STRFTIME = "%Y-%m-%d %H:%M:%S"


def _dir_size_bytes(path: Path) -> int:
    total = 0
    for entry in path.rglob("*"):
        if entry.is_file() and not entry.is_symlink():
            try:
                total += entry.stat().st_size
            except OSError:
                # vanished between listing and stat (e.g. a concurrent run) -
                # skip rather than fail the whole status call over one file.
                continue
    return total


def _snapshot_dirs(project_history_dir: Path) -> list[Path]:
    if not project_history_dir.is_dir():
        return []
    return sorted(
        p for p in project_history_dir.glob("B-*") if p.is_dir()
    )


def _last_run(project_history_dir: Path) -> str | None:
    stamp_file = project_history_dir / ".bmulastrun"
    if not stamp_file.is_file():
        return None
    raw = stamp_file.read_text(encoding="utf-8").strip()
    try:
        return datetime.strptime(raw, _LASTRUN_STRFTIME).isoformat()
    except ValueError:
        # Unexpected content in the stamp file - report it as-is rather
        # than hide a real (if malformed) timestamp behind null.
        return raw


def _last_change(snapshots: list[Path]) -> str | None:
    if not snapshots:
        return None
    newest = snapshots[-1].name  # "B-YYYYMMDD-HHMMSS"; sorted() already
    # orders these chronologically since the format sorts as plain strings.
    try:
        return datetime.strptime(newest.removeprefix("B-"), _SNAPSHOT_STRFTIME).isoformat()
    except ValueError:
        return newest


def _is_old_layout(sync_project_dir: Path, project_name: str) -> bool:
    nested = sync_project_dir / project_name
    if not nested.is_dir():
        return False
    entries = list(sync_project_dir.iterdir())
    return len(entries) == 1


def get_status(config: Config) -> StatusResult:
    projects: list[StatusProject] = []
    if config.sync_dir.is_dir():
        for entry in sorted(config.sync_dir.iterdir()):
            if not entry.is_dir():
                continue
            name = entry.name
            if name.startswith("."):
                # backmeup.status.sh's `for l_dir in "${BMU_DIRRSYNC}"/*/`
                # glob doesn't match dotdirs by default (no dotglob) - most
                # importantly this excludes .locate.dir, the index
                # directory that lives inside SYNC itself by default.
                continue
            project_history_dir = config.history_dir / name
            snapshots = _snapshot_dirs(project_history_dir)
            history_size = (
                _dir_size_bytes(project_history_dir)
                if project_history_dir.is_dir()
                else None
            )
            projects.append(
                StatusProject(
                    name=name,
                    last_run=_last_run(project_history_dir),
                    last_change=_last_change(snapshots),
                    snapshot_count=len(snapshots),
                    mirror_size_bytes=_dir_size_bytes(entry),
                    history_size_bytes=history_size,
                    old_layout=_is_old_layout(entry, name),
                )
            )
    return StatusResult(
        sync_dir=str(config.sync_dir),
        history_dir=str(config.history_dir),
        projects=projects,
    )
