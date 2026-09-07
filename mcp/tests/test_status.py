from __future__ import annotations

from bmug2_mcp.config import Config
from bmug2_mcp.status import get_status


def _config(tmp_path, **overrides):
    defaults = dict(
        bin_dir=tmp_path,
        sync_dir=tmp_path / "sync",
        history_dir=tmp_path / "sync-BP",
        index_dir=tmp_path / "sync" / ".locate.dir",
        locate_cmd="locate",
    )
    defaults.update(overrides)
    return Config(**defaults)


def test_empty_sync_dir_returns_no_projects(tmp_path):
    config = _config(tmp_path)
    config.sync_dir.mkdir(parents=True)
    result = get_status(config)
    assert result.projects == []


def test_sync_dir_missing_returns_no_projects(tmp_path):
    config = _config(tmp_path)
    result = get_status(config)
    assert result.projects == []


def test_index_dir_excluded_from_projects(tmp_path):
    # SYNC/.locate.dir is a real directory inside SYNC by default - it must
    # never show up as a "project". Regression test for a real bug found
    # while smoke-testing against a real sandbox.
    config = _config(tmp_path)
    (config.sync_dir / ".locate.dir").mkdir(parents=True)
    (config.sync_dir / "realproject").mkdir(parents=True)
    result = get_status(config)
    names = [p.name for p in result.projects]
    assert names == ["realproject"]


def test_mirror_only_project_has_null_history_fields(tmp_path):
    # A project dropped into SYNC by hand, never run through backmeup.sh.
    config = _config(tmp_path)
    project = config.sync_dir / "manual"
    project.mkdir(parents=True)
    (project / "x.txt").write_text("x")
    result = get_status(config)
    assert len(result.projects) == 1
    p = result.projects[0]
    assert p.name == "manual"
    assert p.last_run is None
    assert p.last_change is None
    assert p.snapshot_count == 0
    assert p.history_size_bytes is None
    assert p.mirror_size_bytes == 1


def test_last_run_parsed_from_bmulastrun(tmp_path):
    config = _config(tmp_path)
    project_sync = config.sync_dir / "proj"
    project_sync.mkdir(parents=True)
    project_history = config.history_dir / "proj"
    project_history.mkdir(parents=True)
    (project_history / ".bmulastrun").write_text("2026-01-02 03:04:05\n")
    result = get_status(config)
    assert result.projects[0].last_run == "2026-01-02T03:04:05"


def test_last_change_from_newest_snapshot(tmp_path):
    config = _config(tmp_path)
    (config.sync_dir / "proj").mkdir(parents=True)
    history = config.history_dir / "proj"
    (history / "B-20260101-000000").mkdir(parents=True)
    (history / "B-20260301-120000").mkdir(parents=True)
    result = get_status(config)
    p = result.projects[0]
    assert p.snapshot_count == 2
    assert p.last_change == "2026-03-01T12:00:00"


def test_archived_snapshot_tarball_not_counted_as_snapshot(tmp_path):
    # Matches the shell script's own `B-*/` glob (trailing slash: dirs
    # only) - an archived (tar.gz-only, directory removed) snapshot must
    # not inflate the count.
    config = _config(tmp_path)
    (config.sync_dir / "proj").mkdir(parents=True)
    history = config.history_dir / "proj"
    history.mkdir(parents=True)
    (history / "B-20260101-000000.tar.gz").write_bytes(b"fake")
    (history / "B-20260101-000000.filelist").write_text("proj/B-20260101-000000/x\n")
    result = get_status(config)
    assert result.projects[0].snapshot_count == 0
    assert result.projects[0].last_change is None


def test_old_layout_detected(tmp_path):
    config = _config(tmp_path)
    project = config.sync_dir / "old"
    (project / "old").mkdir(parents=True)
    (project / "old" / "f.txt").write_text("x")
    result = get_status(config)
    assert result.projects[0].old_layout is True


def test_old_layout_false_when_source_legitimately_has_same_named_subdir(tmp_path):
    # The exact carve-out backmeup.sh itself implements: a project dir
    # containing the nested name AND something else is not the old layout,
    # it's a project that legitimately has a same-named subdirectory.
    config = _config(tmp_path)
    project = config.sync_dir / "legit"
    (project / "legit").mkdir(parents=True)
    (project / "extra.txt").write_text("x")
    result = get_status(config)
    assert result.projects[0].old_layout is False
