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
