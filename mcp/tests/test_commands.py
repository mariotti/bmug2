from __future__ import annotations

import os
import shutil

from bmug2_mcp import commands


def test_backup_preview_success(real_sandbox):
    config = real_sandbox.config
    result = commands.run_backup_preview(config.bin_dir, str(real_sandbox.project_dir))
    assert result.success is True
    assert result.exit_code == 0
    assert result.project == "myproject"
    assert "DRY RUN" in result.stdout


def test_backup_preview_failure_surfaces_real_exit_code(real_sandbox, tmp_path):
    # backmeup.sh's dry-run branch unconditionally exits 0 after printing
    # its banner, regardless of whether rsync itself failed underneath -
    # a nonexistent source path is not a reliable way to get a nonzero
    # exit out of --dry-run. What IS reliable: one of backmeup.sh's own
    # guard checks (before rsync ever runs) - here, no usable rsync
    # configured, same scenario the shell suite's own guard test uses.
    config = real_sandbox.config
    no_rsync_bin = tmp_path / "no-rsync-bin"
    shutil.copytree(config.bin_dir, no_rsync_bin)
    with (no_rsync_bin / "backmeup.setup.sh").open("a") as f:
        f.write('BMU_CMDRSYNC=""\n')

    result = commands.run_backup_preview(no_rsync_bin, str(real_sandbox.project_dir))
    assert result.success is False
    assert result.exit_code == 1
    assert "no usable rsync" in result.stdout.lower()


def test_archive_preview_reports_archivable_snapshot(real_sandbox):
    config = real_sandbox.config
    result = commands.run_archive_preview(config.bin_dir, "myproject", days=0)
    assert result.success is True
    assert result.days == 0
    assert "would archive" in result.stdout


def test_archive_preview_missing_project_fails(real_sandbox):
    config = real_sandbox.config
    result = commands.run_archive_preview(config.bin_dir, "no-such-project")
    assert result.success is False
    assert result.exit_code == 1
    assert "no history for" in result.stdout.lower() or "no history for" in result.stderr.lower()


def test_archive_preview_default_days_is_180(real_sandbox):
    config = real_sandbox.config
    result = commands.run_archive_preview(config.bin_dir, "myproject")
    assert result.days == 180
    assert "No snapshots older than 180 days" in result.stdout


# --- mutating tools ---------------------------------------------------


def test_backup_success_updates_mirror(real_sandbox):
    config = real_sandbox.config
    (real_sandbox.project_dir / "file1.txt").write_text("hello v3\n")
    result = commands.run_backup(config.bin_dir, str(real_sandbox.project_dir))
    assert result.success is True
    assert result.exit_code == 0
    assert result.project == "myproject"
    mirrored = config.sync_dir / "myproject" / "file1.txt"
    assert mirrored.read_text() == "hello v3\n"


def test_backup_failure_surfaces_real_exit_code(real_sandbox, tmp_path):
    config = real_sandbox.config
    no_rsync_bin = tmp_path / "no-rsync-bin"
    shutil.copytree(config.bin_dir, no_rsync_bin)
    with (no_rsync_bin / "backmeup.setup.sh").open("a") as f:
        f.write('BMU_CMDRSYNC=""\n')
    result = commands.run_backup(no_rsync_bin, str(real_sandbox.project_dir))
    assert result.success is False
    assert result.exit_code == 1


def test_archive_success_creates_tarball_and_removes_directory(real_sandbox):
    config = real_sandbox.config
    result = commands.run_archive(config.bin_dir, "myproject", days=0)
    assert result.success is True
    tarballs = list((config.history_dir / "myproject").glob("B-*.tar.gz"))
    snapshot_dirs = [
        p for p in (config.history_dir / "myproject").glob("B-*") if p.is_dir()
    ]
    assert len(tarballs) == 1
    assert snapshot_dirs == []


def test_archive_missing_project_fails(real_sandbox):
    config = real_sandbox.config
    result = commands.run_archive(config.bin_dir, "no-such-project")
    assert result.success is False
    assert result.exit_code == 1


def test_archive_leaves_snapshot_on_tar_failure(real_sandbox, tmp_path, monkeypatch):
    # Same safety-net guarantee the shell suite verifies for
    # backmeup.archive.sh itself: if tar fails, the original snapshot
    # directory must be left completely untouched.
    config = real_sandbox.config
    snapshot_dirs_before = sorted(
        p.name for p in (config.history_dir / "myproject").glob("B-*") if p.is_dir()
    )
    assert snapshot_dirs_before  # sanity: the fixture actually made one

    fake_tar_dir = tmp_path / "faketar"
    fake_tar_dir.mkdir()
    fake_tar = fake_tar_dir / "tar"
    fake_tar.write_text("#!/bin/sh\nexit 1\n")
    fake_tar.chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake_tar_dir}:{os.environ['PATH']}")

    result = commands.run_archive(config.bin_dir, "myproject", days=0)
    assert result.success is False
    assert result.exit_code == 1
    assert "ERROR: tar failed" in result.stdout

    snapshot_dirs_after = sorted(
        p.name for p in (config.history_dir / "myproject").glob("B-*") if p.is_dir()
    )
    assert snapshot_dirs_after == snapshot_dirs_before
    assert not list((config.history_dir / "myproject").glob("B-*.tar.gz"))


def test_unarchive_success_restores_snapshot(real_sandbox):
    config = real_sandbox.config
    archived = commands.run_archive(config.bin_dir, "myproject", days=0)
    assert archived.success is True
    snapshot_name = next(
        p.name.removesuffix(".tar.gz") for p in (config.history_dir / "myproject").glob("B-*.tar.gz")
    )

    result = commands.run_unarchive(config.bin_dir, "myproject", snapshot_name)
    assert result.success is True
    assert result.snapshot == snapshot_name
    restored = config.history_dir / "myproject" / snapshot_name
    assert restored.is_dir()
    assert not (config.history_dir / "myproject" / f"{snapshot_name}.tar.gz").exists()


def test_unarchive_missing_archive_fails(real_sandbox):
    config = real_sandbox.config
    result = commands.run_unarchive(config.bin_dir, "myproject", "B-19700101-000000")
    assert result.success is False
    assert result.exit_code == 1


def test_unarchive_refuses_existing_directory(real_sandbox):
    config = real_sandbox.config
    archived = commands.run_archive(config.bin_dir, "myproject", days=0)
    snapshot_name = next(
        p.name.removesuffix(".tar.gz") for p in (config.history_dir / "myproject").glob("B-*.tar.gz")
    )
    assert archived.success is True
    # pre-create a directory with that snapshot's name - the tarball is
    # untouched, restoring into it must be refused rather than overwrite
    (config.history_dir / "myproject" / snapshot_name).mkdir()

    result = commands.run_unarchive(config.bin_dir, "myproject", snapshot_name)
    assert result.success is False
    assert result.exit_code == 1
    assert (config.history_dir / "myproject" / f"{snapshot_name}.tar.gz").exists()


def test_unarchive_leaves_archive_on_extract_failure(real_sandbox, tmp_path, monkeypatch):
    config = real_sandbox.config
    archived = commands.run_archive(config.bin_dir, "myproject", days=0)
    snapshot_name = next(
        p.name.removesuffix(".tar.gz") for p in (config.history_dir / "myproject").glob("B-*.tar.gz")
    )
    assert archived.success is True

    fake_tar_dir = tmp_path / "faketar"
    fake_tar_dir.mkdir()
    fake_tar = fake_tar_dir / "tar"
    fake_tar.write_text("#!/bin/sh\nexit 1\n")
    fake_tar.chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake_tar_dir}:{os.environ['PATH']}")

    result = commands.run_unarchive(config.bin_dir, "myproject", snapshot_name)
    assert result.success is False
    assert result.exit_code == 1
    assert (config.history_dir / "myproject" / f"{snapshot_name}.tar.gz").exists()
    assert not (config.history_dir / "myproject" / snapshot_name).exists()


def test_migrate_success(real_sandbox):
    config = real_sandbox.config
    old_project = config.sync_dir / "OldStuff" / "OldStuff"
    old_project.mkdir(parents=True)
    (old_project / "legacy.txt").write_text("legacy\n")

    result = commands.run_migrate(config.bin_dir, "OldStuff")
    assert result.success is True
    assert result.project == "OldStuff"
    assert (config.sync_dir / "OldStuff" / "legacy.txt").is_file()
    assert not (config.sync_dir / "OldStuff" / "OldStuff").exists()


def test_migrate_nothing_to_migrate_fails(real_sandbox):
    # myproject is already flat-layout - nothing for migrate to do.
    config = real_sandbox.config
    result = commands.run_migrate(config.bin_dir, "myproject")
    assert result.success is False
    assert result.exit_code == 1
