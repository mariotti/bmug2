"""Thin subprocess wrappers around bmug2's own scripts.

No parsing of their prose output - status.py/locate.py are the only
Python-owned reimplementations. Here, stdout/stderr/exit_code are passed
through verbatim; `success` and `exit_code` always reflect the real
process result, never overridden into a green result.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import TypeVar

from .models import (
    ArchivePreviewResult,
    ArchiveResult,
    BackupPreviewResult,
    BackupResult,
    CommandResult,
    MigrateResult,
    UnarchiveResult,
)

T = TypeVar("T", bound=CommandResult)


def _run_script(
    bin_dir: Path,
    script_name: str,
    args: list[str],
    result_cls: type[T],
    verb: str,
    **extra_fields: object,
) -> T:
    """Runs bin_dir/script_name with args, wrapping the real subprocess
    result into result_cls. `verb` only shapes the human-readable message
    ("Backup completed."/"Backup failed (exit 1).") - success/exit_code
    always reflect the actual process result, never overridden into a
    green result. extra_fields fills whatever result_cls adds on top of
    CommandResult (project, days, snapshot, ...).
    """
    result = subprocess.run(
        [str(bin_dir / script_name), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return result_cls(
        success=success,
        exit_code=result.returncode,
        message=f"{verb} completed." if success else f"{verb} failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
        **extra_fields,
    )


def run_backup_preview(bin_dir: Path, path: str) -> BackupPreviewResult:
    return _run_script(
        bin_dir, "backmeup.sh", ["--dry-run", path], BackupPreviewResult, "Dry run", project=Path(path).name
    )


def run_archive_preview(bin_dir: Path, project: str, days: int = 180) -> ArchivePreviewResult:
    return _run_script(
        bin_dir,
        "backmeup.archive.sh",
        ["--dry-run", project, str(days)],
        ArchivePreviewResult,
        "Dry run",
        project=project,
        days=days,
    )


def run_backup(bin_dir: Path, path: str) -> BackupResult:
    return _run_script(bin_dir, "backmeup.sh", [path], BackupResult, "Backup", project=Path(path).name)


def run_archive(bin_dir: Path, project: str, days: int = 180) -> ArchiveResult:
    return _run_script(
        bin_dir, "backmeup.archive.sh", [project, str(days)], ArchiveResult, "Archive", project=project, days=days
    )


def run_unarchive(bin_dir: Path, project: str, snapshot: str) -> UnarchiveResult:
    return _run_script(
        bin_dir,
        "backmeup.unarchive.sh",
        [project, snapshot],
        UnarchiveResult,
        "Restore",
        project=project,
        snapshot=snapshot,
    )


def run_migrate(bin_dir: Path, project: str) -> MigrateResult:
    return _run_script(bin_dir, "backmeup.migrate.sh", [project], MigrateResult, "Migration", project=project)
