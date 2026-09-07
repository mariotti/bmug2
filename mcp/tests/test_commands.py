from __future__ import annotations

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
