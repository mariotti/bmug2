from __future__ import annotations

import os
import stat

from bmug2_mcp.config import Config
from bmug2_mcp.locate import do_locate


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


def _fake_locate(tmp_path, lines_by_pattern: dict[str, list[str]]):
    """A stand-in `locate` binary: prints canned lines for a pattern,
    regardless of which db it was pointed at, so index-path tests don't
    depend on a real locate database format being available in CI.
    """
    script = tmp_path / "fake-locate"
    body = ["#!/bin/sh", 'pattern="$4"', "case \"$pattern\" in"]
    for pattern, lines in lines_by_pattern.items():
        body.append(f'  "{pattern}")')
        for line in lines:
            body.append(f'    echo "{line}"')
        body.append("    ;;")
    body.append("esac")
    script.write_text("\n".join(body) + "\n")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return str(script)


def test_no_locate_cmd_means_not_indexed(tmp_path):
    config = _config(tmp_path, locate_cmd=None)
    config.history_dir.mkdir(parents=True)
    result = do_locate(config, ["anything"])
    assert result.indexed is False
    assert result.counts.index == 0


def test_index_hits_tagged_and_counted(tmp_path):
    fake = _fake_locate(tmp_path, {"report": ["/sync/docs/report.pdf"]})
    config = _config(tmp_path, locate_cmd=fake)
    config.index_dir.mkdir(parents=True)
    (config.index_dir / ".locate.db").write_bytes(b"x")
    (config.index_dir / ".locate.dbb").write_bytes(b"x")
    result = do_locate(config, ["report"])
    assert result.indexed is True
    # queried against both .locate.db and .locate.dbb -> same fake output twice
    assert result.counts.index == 2
    assert all(h.source == "index" for h in result.results)


def test_index_skipped_when_db_file_missing(tmp_path):
    fake = _fake_locate(tmp_path, {"report": ["/sync/docs/report.pdf"]})
    config = _config(tmp_path, locate_cmd=fake)
    config.index_dir.mkdir(parents=True)
    # neither .locate.db nor .locate.dbb exists yet
    result = do_locate(config, ["report"])
    assert result.counts.index == 0


def test_one_locate_call_per_pattern_not_bundled(tmp_path, monkeypatch):
    # Regression guard for the cross-implementation inconsistency found
    # while building the shell test suite: never bundle multiple patterns
    # into a single locate invocation.
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)

        class R:
            stdout = ""

        return R()

    import bmug2_mcp.locate as locate_mod

    monkeypatch.setattr(locate_mod.subprocess, "run", fake_run)
    config = _config(tmp_path)
    config.index_dir.mkdir(parents=True)
    (config.index_dir / ".locate.db").write_bytes(b"x")
    (config.index_dir / ".locate.dbb").write_bytes(b"x")
    do_locate(config, ["alpha", "beta"])
    patterns_passed = [cmd[-1] for cmd in calls]
    assert patterns_passed == ["alpha", "alpha", "beta", "beta"]
    assert all(len(cmd) == 5 for cmd in calls)  # locate -i -d <db> <one pattern>


def test_archived_filelist_hit_tagged_and_case_insensitive(tmp_path):
    config = _config(tmp_path, locate_cmd=None)
    snap = config.history_dir / "proj" / "B-20260101-000000"
    filelist = config.history_dir / "proj" / "B-20260101-000000.filelist"
    filelist.parent.mkdir(parents=True)
    filelist.write_text("proj/B-20260101-000000\nproj/B-20260101-000000/Report.PDF\n")
    assert not snap.is_dir()  # archived: directory gone, filelist kept

    result = do_locate(config, ["report.pdf"])
    assert result.counts.archived_filelist == 1
    assert result.results[0].source == "archived_filelist"
    assert result.results[0].path.endswith("Report.PDF")


def test_filelist_skipped_when_snapshot_dir_still_present(tmp_path):
    # Same guard as the shell version: only archived (dir gone) snapshots
    # fall back to the filelist grep - a still-present snapshot is covered
    # by the index instead.
    config = _config(tmp_path, locate_cmd=None)
    snap = config.history_dir / "proj" / "B-20260101-000000"
    snap.mkdir(parents=True)
    filelist = config.history_dir / "proj" / "B-20260101-000000.filelist"
    filelist.write_text("proj/B-20260101-000000/report.pdf\n")

    result = do_locate(config, ["report.pdf"])
    assert result.counts.archived_filelist == 0


def test_literal_substring_not_regex(tmp_path):
    # A deliberate difference from grep -i's basic-regex semantics: "." in
    # a pattern must match literally, not "any character".
    config = _config(tmp_path, locate_cmd=None)
    filelist = config.history_dir / "proj" / "B-20260101-000000.filelist"
    filelist.parent.mkdir(parents=True)
    filelist.write_text("proj/B-20260101-000000/reportXpdf\n")

    result = do_locate(config, ["report.pdf"])
    assert result.counts.archived_filelist == 0
