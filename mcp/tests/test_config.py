from __future__ import annotations

import pytest

from bmug2_mcp.config import ConfigError, load_config, resolve_bin_dir


def test_resolve_bin_dir_from_cli_arg(tmp_path):
    assert resolve_bin_dir(str(tmp_path)) == tmp_path


def test_resolve_bin_dir_from_env(tmp_path, monkeypatch):
    monkeypatch.setenv("BMUG2_BIN_DIR", str(tmp_path))
    assert resolve_bin_dir(None) == tmp_path


def test_resolve_bin_dir_cli_arg_wins_over_env(tmp_path, monkeypatch):
    other = tmp_path / "other"
    other.mkdir()
    monkeypatch.setenv("BMUG2_BIN_DIR", str(other))
    assert resolve_bin_dir(str(tmp_path)) == tmp_path


def test_resolve_bin_dir_missing_raises(monkeypatch):
    monkeypatch.delenv("BMUG2_BIN_DIR", raising=False)
    with pytest.raises(ConfigError, match="No bmug2 bin directory given"):
        resolve_bin_dir(None)


def test_resolve_bin_dir_nonexistent_raises(tmp_path):
    with pytest.raises(ConfigError, match="does not exist"):
        resolve_bin_dir(str(tmp_path / "nope"))


def test_load_config_missing_setup_file_raises(tmp_path):
    with pytest.raises(ConfigError, match="Run backmeup.configure.sh"):
        load_config(tmp_path)


def test_load_config_rejects_unresolved_template_syntax(tmp_path):
    # This is exactly what the sed-on-template shortcut (used by the shell
    # test suite for bash-consumed fixtures) leaves behind: a real shell
    # variable reference, safe for bash to source but not a value the
    # Python parser should ever guess at.
    (tmp_path / "backmeup.setup.sh").write_text(
        'BMU_DIRRSYNC="/tmp/x"\nBMU_DIRBACKUPS="${BMU_DIRRSYNC}-BP"\n'
    )
    with pytest.raises(ConfigError, match="real shell syntax"):
        load_config(tmp_path)


def test_load_config_rejects_backtick(tmp_path):
    (tmp_path / "backmeup.setup.sh").write_text(
        'BMU_DIRRSYNC="/tmp/x"\nBMU_DIRBACKUPS="`echo hi`"\n'
    )
    with pytest.raises(ConfigError, match="real shell syntax"):
        load_config(tmp_path)


def test_load_config_missing_required_vars_raises(tmp_path):
    (tmp_path / "backmeup.setup.sh").write_text('BMU_CMDLOCATE="locate"\n')
    with pytest.raises(ConfigError, match="doesn't look like a file"):
        load_config(tmp_path)


def test_load_config_happy_path(tmp_path):
    (tmp_path / "backmeup.setup.sh").write_text(
        'BMU_DIRRSYNC="/tmp/sync"\n'
        'BMU_DIRBACKUPS="/tmp/sync-BP"\n'
        'BMU_DIRDBLOCATE="/tmp/sync/.locate.dir"\n'
        'BMU_CMDLOCATE="glocate"\n'
    )
    config = load_config(tmp_path)
    assert str(config.sync_dir) == "/tmp/sync"
    assert str(config.history_dir) == "/tmp/sync-BP"
    assert config.locate_cmd == "glocate"


def test_load_config_no_locate_cmd_is_none(tmp_path):
    (tmp_path / "backmeup.setup.sh").write_text(
        'BMU_DIRRSYNC="/tmp/sync"\nBMU_DIRBACKUPS="/tmp/sync-BP"\nBMU_CMDLOCATE=""\n'
    )
    config = load_config(tmp_path)
    assert config.locate_cmd is None


def test_load_config_against_real_sandbox(real_sandbox):
    # real_sandbox fixture already calls load_config once to build itself;
    # this just documents/re-asserts that the round trip through a real
    # backmeup.configure.sh-generated file works end to end.
    config = real_sandbox.config
    assert config.sync_dir.is_dir()
    assert config.history_dir.is_dir()
