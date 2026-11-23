"""Native reimplementation of backmeup.disk.sh, returning structured
data instead of the padded text table / shell JSON.

Mirrors the shell script's exact logic (see bin/backmeup.disk.sh) so
the two stay behaviorally equivalent - the same discipline status.py
follows.

Phase 1 of the disk-size project: aggregated SYNC+HISTORY totals +
a local-proxy replicate estimate. Phase 2 added per-project +
global budgets (sidecar override of a backmeup.setup.sh default)
and per-volume info (df-based). This module exposes both from the
MCP side; the shell layer stays the source of truth for the actual
WARNING: emitted at the end of every backmeup.sh run.

Deliberately NOT exposing budget WRITE operations through MCP for
now - matches docs/PROJECT_disk-size.md's "shell is read-only +
warn-only" discipline at the MCP boundary too. Budget editing stays
GUI-only until a specific request appears.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from .config import Config
from .models import (
    DiskUsageBudget,
    DiskUsageProject,
    DiskUsageResult,
    DiskUsageVolume,
    DiskUsageVolumes,
)


def _dir_size_bytes(path: Path) -> int:
    total = 0
    for entry in path.rglob("*"):
        if entry.is_file() and not entry.is_symlink():
            try:
                total += entry.stat().st_size
            except OSError:
                # Same tolerance as status.py: a file that vanished
                # between listing and stat just doesn't count.
                continue
    return total


def _read_budget_sidecar(project_history: Path) -> tuple[int | None, int | None]:
    """Read SYNC_WARN_BYTES / HISTORY_WARN_BYTES from
    `<project>/.bmubudget`. Same permissive discipline as the shell's
    bmuReadBudgetKey: a malformed or typo'd sidecar reads as "unset",
    never raises - broken warnings are worse than no warnings.
    """
    path = project_history / ".bmubudget"
    if not path.is_file():
        return (None, None)
    sync_val: int | None = None
    hist_val: int | None = None
    try:
        contents = path.read_text()
    except OSError:
        return (None, None)
    for line in contents.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, raw = line.partition("=")
        key = key.strip()
        val = raw.strip().strip('"').strip("'")
        if not val.isdigit():
            continue
        parsed = int(val)
        if key == "SYNC_WARN_BYTES":
            sync_val = parsed
        elif key == "HISTORY_WARN_BYTES":
            hist_val = parsed
    return (sync_val, hist_val)


def _volume_info(path: Path) -> DiskUsageVolume:
    """Wraps Python's shutil.disk_usage. Returns an empty DiskUsageVolume
    when the path doesn't resolve (missing dir, external drive not
    mounted) - matches the shell's "empty on failure" contract.
    """
    if not path.exists():
        return DiskUsageVolume()
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return DiskUsageVolume()
    # Resolve the mount point by walking up until the parent is on
    # a different filesystem - shutil doesn't give us this directly,
    # but os.path.ismount + walking up does. Deliberately matches
    # what `df -P` prints (the actual mountpoint, not the containing
    # dir of `path`).
    try:
        import os as _os

        current = path.resolve()
        while current != current.parent and not _os.path.ismount(current):
            current = current.parent
        mount = str(current)
    except OSError:
        mount = None
    return DiskUsageVolume(
        mount=mount,
        total_bytes=usage.total,
        avail_bytes=usage.free,
    )


def collect(cfg: Config) -> DiskUsageResult:
    """Produce the disk usage snapshot. Walks every project in SYNC
    once; reads each project's .bmureplicate-class + .bmubudget
    sidecar for budget + replicate class; sums into grand totals;
    probes the two root volumes via shutil.disk_usage.
    """
    sync_dir = Path(cfg.sync_dir)
    history_dir = Path(cfg.history_dir)

    sync_total = 0
    hist_total = 0
    estimate_total = 0
    projects: list[DiskUsageProject] = []

    if sync_dir.is_dir():
        for child in sorted(sync_dir.iterdir()):
            if not child.is_dir():
                continue
            # Skip the IndexDB dir - same as backmeup.disk.sh (it
            # only globs projects, which have no leading-dot name).
            if child.name.startswith("."):
                continue
            name = child.name
            sync_bytes = _dir_size_bytes(child)
            hist_proj = history_dir / name
            hist_bytes = _dir_size_bytes(hist_proj) if hist_proj.is_dir() else 0

            replicate_class: str = "default"
            sidecar = hist_proj / ".bmureplicate-class"
            if sidecar.is_file():
                try:
                    raw = sidecar.read_text().splitlines()[0].strip()
                    if raw == "none":
                        replicate_class = "none"
                except OSError:
                    pass

            # Global defaults from setup.sh fall back to the sidecar
            # override. Phase 2 contract: sidecar key beats global
            # BMU_*_WARN_BYTES for that one project.
            prj_sync_budget, prj_hist_budget = _read_budget_sidecar(hist_proj)
            if prj_sync_budget is None:
                prj_sync_budget = cfg.sync_warn_bytes
            if prj_hist_budget is None:
                prj_hist_budget = cfg.history_warn_bytes

            projects.append(
                DiskUsageProject(
                    name=name,
                    sync_bytes=sync_bytes,
                    history_bytes=hist_bytes,
                    replicate_class="none" if replicate_class == "none" else "default",
                    sync_warn_bytes=prj_sync_budget,
                    history_warn_bytes=prj_hist_budget,
                    sync_over=prj_sync_budget is not None and sync_bytes > prj_sync_budget,
                    history_over=prj_hist_budget is not None and hist_bytes > prj_hist_budget,
                )
            )
            sync_total += sync_bytes
            hist_total += hist_bytes
            if replicate_class != "none":
                estimate_total += sync_bytes + hist_bytes

    budget = DiskUsageBudget(
        sync_warn_bytes=cfg.sync_warn_bytes,
        history_warn_bytes=cfg.history_warn_bytes,
        sync_over=cfg.sync_warn_bytes is not None and sync_total > cfg.sync_warn_bytes,
        history_over=cfg.history_warn_bytes is not None and hist_total > cfg.history_warn_bytes,
    )
    sync_vol = _volume_info(sync_dir)
    hist_vol = _volume_info(history_dir)
    same_volume: bool | None = None
    if sync_vol.mount is not None and hist_vol.mount is not None:
        same_volume = sync_vol.mount == hist_vol.mount

    return DiskUsageResult(
        sync_dir=str(sync_dir),
        history_dir=str(history_dir),
        sync_total_bytes=sync_total,
        history_total_bytes=hist_total,
        replicate_estimate_bytes=estimate_total,
        projects=projects,
        budget=budget,
        volumes=DiskUsageVolumes(sync=sync_vol, history=hist_vol, same_volume=same_volume),
    )
