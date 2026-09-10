"""Shared fixtures: real bmug2 sandboxes, same philosophy as
tests/test_backmeup.sh - real commands against real temp directories,
nothing mocked here (a couple of tests stub `tar` on PATH for failure
injection, matching the shell suite's own technique, but that's local to
those tests, not this fixture).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import pytest

from bmug2_mcp import commands
from bmug2_mcp.config import Config, load_config

REPO_BIN = Path(__file__).resolve().parents[2] / "bin"


def _config(tmp_path: Path, **overrides: object) -> Config:
    """A fake-but-plausible Config for tests that exercise status.py/
    locate.py directly against a hand-built directory tree, without going
    through a real install (see conftest's own real_sandbox fixture for
    the alternative, install.sh-driven approach). Shared by test_status.py
    and test_locate.py - previously two identical copies.
    """
    defaults: dict[str, object] = dict(
        bin_dir=tmp_path,
        sync_dir=tmp_path / "sync",
        history_dir=tmp_path / "sync-BP",
        index_dir=tmp_path / "sync" / ".locate.dir",
        locate_cmd="locate",
    )
    defaults.update(overrides)
    return Config(**defaults)


@dataclass(frozen=True)
class Sandbox:
    config: Config
    project_dir: Path  # HOME/myproject - the real backup source directory


def _run_backup(bin_dir: Path, project_dir: Path) -> None:
    result = commands.run_backup(bin_dir, str(project_dir))
    assert result.success, result.stdout + result.stderr


@pytest.fixture
def real_sandbox(tmp_path: Path) -> Sandbox:
    """A sandbox built through the REAL backmeup.install.sh/configure.sh,
    with scripted stdin - not the sed-on-template shortcut the shell test
    suite uses for its own (bash-consumed) fixtures. That shortcut leaves
    unresolved shell references like BMU_DIRBACKUPS="${BMU_DIRRSYNC}-BP"
    in the file, which bash scripts resolve fine by sourcing it but which
    the Python config parser correctly refuses (see config.py) - this
    fixture exercises the parser against what configure.sh actually
    writes: fully resolved literal values.
    """
    home = tmp_path / "home"
    checkout = tmp_path / "checkout"
    (home / "usr").mkdir(parents=True)
    shutil.copytree(REPO_BIN, checkout)

    # Answers, in prompt order: SYNC (default) -> y to create; BACKUP -> y;
    # INDEX -> y; INSTALL dir (default) -> y to create.
    install_input = "\ny\n\ny\n\ny\n\ny\n"
    env = dict(os.environ, HOME=str(home))
    result = subprocess.run(
        [str(checkout / "backmeup.install.sh")],
        input=install_input,
        capture_output=True,
        text=True,
        env=env,
    )
    assert result.returncode == 0, result.stdout + result.stderr

    bin_dir = home / "usr" / "bmu" / "bin"
    config = load_config(bin_dir)

    project = home / "myproject"
    (project / "sub").mkdir(parents=True)
    (project / "file1.txt").write_text("hello v1\n")
    (project / "sub" / "file2.txt").write_text("doomed\n")
    _run_backup(bin_dir, project)

    time.sleep(1)  # force a distinct mtime, same reason as the shell suite
    (project / "file1.txt").write_text("hello v2\n")
    (project / "sub" / "file2.txt").unlink()
    _run_backup(bin_dir, project)

    subprocess.run(
        [str(bin_dir / "backmeup.updatedb.sh")], capture_output=True, text=True, check=False
    )

    # A days=0 archive cutoff is "now" at second granularity - without this,
    # a test archiving immediately after this fixture builds can race the
    # clock and find nothing "old enough" (the exact bug fixed in the shell
    # suite's own archive test - see its git history).
    time.sleep(1)

    return Sandbox(config=config, project_dir=project)
