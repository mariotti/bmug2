"""Thin subprocess wrappers around bmug2's own scripts.

No parsing of their prose output - status.py/locate.py are the only
Python-owned reimplementations. Here, stdout/stderr/exit_code are passed
through verbatim; `success` and `exit_code` always reflect the real
process result, never overridden into a green result.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from .models import (
    ArchivePreviewResult,
    ArchiveResult,
    BackupPreviewResult,
    BackupResult,
    MigrateResult,
    UnarchiveResult,
)


def run_backup_preview(bin_dir: Path, path: str) -> BackupPreviewResult:
    project = Path(path).name
    result = subprocess.run(
        [str(bin_dir / "backmeup.sh"), "--dry-run", path],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return BackupPreviewResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        message="Dry run completed." if success else f"Dry run failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )


def run_archive_preview(bin_dir: Path, project: str, days: int = 180) -> ArchivePreviewResult:
    result = subprocess.run(
        [str(bin_dir / "backmeup.archive.sh"), "--dry-run", project, str(days)],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return ArchivePreviewResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        days=days,
        message="Dry run completed." if success else f"Dry run failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )


def run_backup(bin_dir: Path, path: str) -> BackupResult:
    project = Path(path).name
    result = subprocess.run(
        [str(bin_dir / "backmeup.sh"), path],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return BackupResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        message="Backup completed." if success else f"Backup failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )


def run_archive(bin_dir: Path, project: str, days: int = 180) -> ArchiveResult:
    result = subprocess.run(
        [str(bin_dir / "backmeup.archive.sh"), project, str(days)],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return ArchiveResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        days=days,
        message="Archive completed." if success else f"Archive failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )


def run_unarchive(bin_dir: Path, project: str, snapshot: str) -> UnarchiveResult:
    result = subprocess.run(
        [str(bin_dir / "backmeup.unarchive.sh"), project, snapshot],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return UnarchiveResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        snapshot=snapshot,
        message="Restore completed." if success else f"Restore failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )


def run_migrate(bin_dir: Path, project: str) -> MigrateResult:
    result = subprocess.run(
        [str(bin_dir / "backmeup.migrate.sh"), project],
        capture_output=True,
        text=True,
        check=False,
    )
    success = result.returncode == 0
    return MigrateResult(
        success=success,
        exit_code=result.returncode,
        project=project,
        message="Migration completed." if success else f"Migration failed (exit {result.returncode}).",
        stdout=result.stdout,
        stderr=result.stderr,
    )
