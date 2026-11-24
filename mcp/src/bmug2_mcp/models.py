"""Pydantic models for MCP tool inputs/outputs.

Returned directly from tool functions - MCPServer serializes a BaseModel
return value to the tool call's structured content automatically.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class StatusProject(BaseModel):
    name: str
    last_run: str | None = Field(
        description="ISO 8601 timestamp of the last successful backmeup.sh run, "
        "or null if this project was never backed up through it."
    )
    last_change: str | None = Field(
        description="ISO 8601 timestamp of the newest snapshot, or null if no "
        "run has ever changed anything for this project."
    )
    snapshot_count: int = Field(description="Number of B-<date> snapshot directories.")
    mirror_size_bytes: int = Field(
        description="Total apparent size of the live mirror, in bytes. Note: "
        "this is a plain sum of file sizes, not `du`'s disk-block usage, so "
        "it can differ slightly from `du -sh` for the same directory."
    )
    history_size_bytes: int | None = Field(
        description="Total apparent size of this project's history, in bytes, "
        "or null if it has no history directory yet."
    )
    old_layout: bool = Field(
        description="True if this project's mirror is still in the pre-bmug2 "
        "nested layout and needs backmeup.migrate.sh."
    )


class StatusResult(BaseModel):
    sync_dir: str
    history_dir: str
    projects: list[StatusProject]


class DiskUsageProject(BaseModel):
    """Per-project row in the disk usage report. Mirrors the shell JSON
    produced by backmeup.disk.sh at bin/ (Phase 1-3 of the disk-size
    project; see docs/PROJECT_disk-size.md). Byte-denominated, like
    StatusProject - the shell layer emits KB, but we convert here so
    callers get one consistent unit across MCP tools.
    """

    name: str
    sync_bytes: int = Field(description="Size of this project's live mirror, bytes.")
    history_bytes: int = Field(description="Size of this project's history dir, bytes.")
    replicate_class: Literal["default", "none"] = Field(
        description="'none' = project is excluded from off-site "
        "replication per its .bmureplicate-class sidecar; 'default' "
        "otherwise. Does NOT affect local backup behavior."
    )
    sync_warn_bytes: int | None = Field(
        default=None,
        description="Effective per-project SYNC budget in bytes. "
        "Sidecar override if set, else the global BMU_SYNC_WARN_BYTES. "
        "Null when no budget is configured for this project.",
    )
    history_warn_bytes: int | None = Field(
        default=None,
        description="Same shape as sync_warn_bytes, for HISTORY.",
    )
    sync_over: bool = Field(
        default=False,
        description="True iff sync_bytes exceeds sync_warn_bytes.",
    )
    history_over: bool = Field(
        default=False,
        description="True iff history_bytes exceeds history_warn_bytes.",
    )


class DiskUsageBudget(BaseModel):
    """Global budget totals (sum across every project) and the over-
    budget flags. Null members mean the corresponding
    BMU_*_WARN_BYTES isn't set in backmeup.setup.sh - shell layer
    stays silent, no warning.
    """

    sync_warn_bytes: int | None = None
    history_warn_bytes: int | None = None
    sync_over: bool = False
    history_over: bool = False


class DiskUsageVolume(BaseModel):
    """Which filesystem a root (SYNC or HISTORY) lives on. mount is
    None when df couldn't resolve it (missing path, external drive
    not plugged in). total/avail reported in bytes.
    """

    mount: str | None = None
    total_bytes: int | None = None
    avail_bytes: int | None = None


class DiskUsageVolumes(BaseModel):
    """Volume info for SYNC and HISTORY. same_volume is None (unknown)
    when at least one side couldn't be resolved.
    """

    sync: DiskUsageVolume = Field(default_factory=DiskUsageVolume)
    history: DiskUsageVolume = Field(default_factory=DiskUsageVolume)
    same_volume: bool | None = None


class DiskUsageResult(BaseModel):
    """Full disk usage snapshot. Phase 1-3 of the disk-size project.
    Mirrors backmeup.disk.sh --json. Deliberately a reimplementation
    rather than a shell-out, matching status.py's discipline.
    """

    sync_dir: str
    history_dir: str
    sync_total_bytes: int = Field(description="Sum of per-project sync_bytes.")
    history_total_bytes: int = Field(description="Sum of per-project history_bytes.")
    replicate_estimate_bytes: int = Field(
        description="Local proxy of what off-site replication would "
        "push: SYNC + HISTORY minus any project with "
        "replicate_class=none. No remote call - real figure may "
        "differ. See docs/PROJECT_disk-size.md Phase 1 for the "
        "rationale."
    )
    projects: list[DiskUsageProject]
    budget: DiskUsageBudget
    volumes: DiskUsageVolumes


class LocateHit(BaseModel):
    path: str
    source: Literal["index", "live", "archived_filelist"] = Field(
        description="'index' = found via the locate database (only as fresh "
        "as the last backmeup.updatedb.sh run); 'live' = found by grepping "
        "a project's live filelist, refreshed on every backup run - covers "
        "anything too new for the index; 'archived_filelist' = found by "
        "grepping a kept snapshot filelist after archiving. The same path "
        "can legitimately appear from more than one source at once - not "
        "deduplicated."
    )


class LocateCounts(BaseModel):
    index: int
    live: int
    archived_filelist: int


class LocateResult(BaseModel):
    patterns: list[str]
    indexed: bool = Field(
        description="Whether a locate binary was available at all. When "
        "false, index results are unavailable, but live/archived-filelist "
        "results are unaffected."
    )
    counts: LocateCounts
    results: list[LocateHit]


class CommandResult(BaseModel):
    success: bool
    exit_code: int
    message: str = Field(
        description="Short human/LLM-readable summary of the outcome, e.g. "
        "'Backup completed.' or 'Backup failed (exit 1).' - distinct from "
        "stdout/stderr, which carry the script's raw output verbatim."
    )
    stdout: str
    stderr: str


class BackupPreviewResult(CommandResult):
    project: str


class ArchivePreviewResult(CommandResult):
    project: str
    days: int


class BackupResult(CommandResult):
    project: str


class ArchiveResult(CommandResult):
    project: str
    days: int


class UnarchiveResult(CommandResult):
    project: str
    snapshot: str


class MigrateResult(CommandResult):
    project: str


class RetrievePreviewResult(CommandResult):
    project: str
    snapshot: str
    destination: str
    relative_path: str | None = Field(
        default=None,
        description="Path within the snapshot that was (or would be) "
        "retrieved. Null means the whole snapshot.",
    )


class RetrieveResult(CommandResult):
    project: str
    snapshot: str
    destination: str
    relative_path: str | None = Field(
        default=None,
        description="Path within the snapshot that was retrieved. Null "
        "means the whole snapshot.",
    )
