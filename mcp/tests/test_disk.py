"""Tests for bmug2_mcp.disk - the MCP side of the disk-size project.

Same style as test_status.py: real temp directories, no mocks. The
MCP layer reimplements backmeup.disk.sh (rather than shelling out to
it) so the two stay standalone-usable from the server.
"""

from __future__ import annotations

from pathlib import Path

from conftest import _config
from bmug2_mcp.disk import collect


def test_empty_sync_dir_returns_no_projects_and_zero_totals(tmp_path):
    config = _config(tmp_path)
    config.sync_dir.mkdir(parents=True)
    r = collect(config)
    assert r.projects == []
    assert r.sync_total_bytes == 0
    assert r.history_total_bytes == 0
    assert r.replicate_estimate_bytes == 0


def test_sync_dir_missing_returns_no_projects(tmp_path):
    # Matches status.py's tolerance: a missing SYNC dir isn't a hard
    # error from the MCP tool's point of view - it just reports
    # zero projects. A user may be inspecting an install that
    # hasn't been configured on this machine yet.
    config = _config(tmp_path)
    r = collect(config)
    assert r.projects == []


def test_index_dir_excluded_from_projects(tmp_path):
    # Same regression guard as test_status.py: SYNC/.locate.dir must
    # never show up as a "project". Any leading-dot dir is skipped.
    config = _config(tmp_path)
    (config.sync_dir / ".locate.dir").mkdir(parents=True)
    (config.sync_dir / "realproject").mkdir(parents=True)
    r = collect(config)
    assert [p.name for p in r.projects] == ["realproject"]


def test_per_project_bytes_sum_into_grand_totals(tmp_path):
    config = _config(tmp_path)
    sync_a = config.sync_dir / "a"
    sync_a.mkdir(parents=True)
    (sync_a / "x").write_bytes(b"x" * 100)
    hist_a = config.history_dir / "a"
    hist_a.mkdir(parents=True)
    (hist_a / "snap").write_bytes(b"y" * 200)

    sync_b = config.sync_dir / "b"
    sync_b.mkdir(parents=True)
    (sync_b / "z").write_bytes(b"z" * 50)

    r = collect(config)
    names = sorted(p.name for p in r.projects)
    assert names == ["a", "b"]
    assert r.sync_total_bytes == 150
    assert r.history_total_bytes == 200
    # No replicate_class=none sidecars -> both projects count.
    assert r.replicate_estimate_bytes == 150 + 200


def test_replicate_class_none_sidecar_excludes_from_estimate(tmp_path):
    # Mirrors the shell's `.bmureplicate-class` reader: literal "none"
    # (first line, stripped) drops the project from the replicate
    # estimate; grand totals still include it (local backup still
    # runs for that project).
    config = _config(tmp_path)
    sync = config.sync_dir / "media"
    sync.mkdir(parents=True)
    (sync / "f").write_bytes(b"x" * 1000)
    hist = config.history_dir / "media"
    hist.mkdir(parents=True)
    (hist / ".bmureplicate-class").write_text("none\n")

    r = collect(config)
    assert r.sync_total_bytes == 1000
    # Replicate estimate drops the 1000 bytes - project is local-only.
    assert r.replicate_estimate_bytes == 0
    assert r.projects[0].replicate_class == "none"


def test_no_budget_reports_null_everywhere(tmp_path):
    config = _config(tmp_path)
    (config.sync_dir / "p").mkdir(parents=True)
    r = collect(config)
    assert r.budget.sync_warn_bytes is None
    assert r.budget.history_warn_bytes is None
    assert r.budget.sync_over is False
    assert r.budget.history_over is False
    assert r.projects[0].sync_warn_bytes is None
    assert r.projects[0].history_warn_bytes is None
    assert r.projects[0].sync_over is False
    assert r.projects[0].history_over is False


def test_global_budget_over_flag_fires_on_totals(tmp_path):
    config = _config(tmp_path, sync_warn_bytes=100, history_warn_bytes=None)
    sync = config.sync_dir / "p"
    sync.mkdir(parents=True)
    (sync / "x").write_bytes(b"x" * 200)  # 200 > 100 budget
    r = collect(config)
    assert r.budget.sync_over is True
    # History budget unset -> flag stays false.
    assert r.budget.history_over is False


def test_per_source_sidecar_overrides_global_default(tmp_path):
    # Phase 2 precedence contract: a .bmubudget key in HISTORY/<proj>/
    # beats the global default for THAT project. Verified at the
    # per-project row level (sidecar sets a huge number, so the row
    # stays under; a different project with no sidecar still uses
    # the global default and goes over).
    config = _config(tmp_path, history_warn_bytes=1)
    # Project 'videos' has a huge per-source override - won't fire.
    sync_v = config.sync_dir / "videos"
    sync_v.mkdir(parents=True)
    (sync_v / "f").write_bytes(b"x" * 1000)
    hist_v = config.history_dir / "videos"
    hist_v.mkdir(parents=True)
    (hist_v / "big").write_bytes(b"y" * 10_000)
    (hist_v / ".bmubudget").write_text("HISTORY_WARN_BYTES=99999999\n")
    # Project 'docs' uses the tiny global default - will fire.
    sync_d = config.sync_dir / "docs"
    sync_d.mkdir(parents=True)
    (sync_d / "f").write_bytes(b"x" * 10)
    hist_d = config.history_dir / "docs"
    hist_d.mkdir(parents=True)
    (hist_d / "s").write_bytes(b"z" * 500)

    r = collect(config)
    videos = next(p for p in r.projects if p.name == "videos")
    docs = next(p for p in r.projects if p.name == "docs")
    assert videos.history_warn_bytes == 99999999
    assert videos.history_over is False
    assert docs.history_warn_bytes == 1
    assert docs.history_over is True


def test_malformed_sidecar_lines_are_ignored(tmp_path):
    # Same permissive discipline as the shell's bmuReadBudgetKey:
    # typos and non-integer values read as "not set", never raise.
    config = _config(tmp_path, sync_warn_bytes=50)
    sync = config.sync_dir / "p"
    sync.mkdir(parents=True)
    (sync / "f").write_bytes(b"x" * 10)
    hist = config.history_dir / "p"
    hist.mkdir(parents=True)
    (hist / ".bmubudget").write_text(
        "# comment\n"
        "SYNC_WARN_BYTES=twelve-and-a-half\n"
        "UNKNOWN=42\n"
        "HISTORY_WARN_BYTES=\"4096\"\n"
    )

    r = collect(config)
    project = r.projects[0]
    # Malformed SYNC value falls back to the global default (50).
    assert project.sync_warn_bytes == 50
    # Quoted HISTORY value parses.
    assert project.history_warn_bytes == 4096


def test_volumes_populated_when_sync_and_history_exist(tmp_path):
    config = _config(tmp_path)
    config.sync_dir.mkdir(parents=True)
    config.history_dir.mkdir(parents=True)
    r = collect(config)
    assert r.volumes.sync.mount is not None
    assert r.volumes.history.mount is not None
    # Both roots are under the same tmp_path, so same_volume must be true.
    assert r.volumes.same_volume is True
    assert r.volumes.sync.total_bytes is not None and r.volumes.sync.total_bytes > 0
    assert r.volumes.sync.avail_bytes is not None


def test_volume_returns_empty_when_path_missing(tmp_path):
    # If SYNC exists but HISTORY doesn't, SYNC volume info still
    # populates; HISTORY stays empty. same_volume becomes None
    # (unknown).
    config = _config(tmp_path)
    config.sync_dir.mkdir(parents=True)
    # No history dir.
    r = collect(config)
    assert r.volumes.sync.mount is not None
    assert r.volumes.history.mount is None
    assert r.volumes.same_volume is None
