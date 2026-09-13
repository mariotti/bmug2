"""A small subset of tests drives the actual MCP stdio protocol (spawns
the real server as a subprocess) rather than calling Python functions
directly, to catch schema/serialization issues the unit tests can't see.
Kept deliberately small - this is slower than the direct-call tests.
"""

from __future__ import annotations

import asyncio
import sys

from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client


async def _call_tools(bin_dir, project_dir):
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bmug2_mcp.server", "--bin-dir", str(bin_dir)],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            status_r = await session.call_tool("bmug2_status", {})
            locate_r = await session.call_tool("bmug2_locate", {"patterns": ["file2.txt"]})
            backup_preview_r = await session.call_tool(
                "bmug2_backup_preview", {"path": str(project_dir)}
            )
            archive_preview_r = await session.call_tool(
                "bmug2_archive_preview", {"project": "myproject", "days": 0}
            )
            backup_r = await session.call_tool("bmug2_backup", {"path": str(project_dir)})
            archive_r = await session.call_tool(
                "bmug2_archive", {"project": "myproject", "days": 0}
            )
            return tools, status_r, locate_r, backup_preview_r, archive_preview_r, backup_r, archive_r


def test_all_read_only_tools_over_real_stdio_transport(real_sandbox):
    config = real_sandbox.config
    (
        tools,
        status_r,
        locate_r,
        backup_preview_r,
        archive_preview_r,
        backup_r,
        archive_r,
    ) = asyncio.run(_call_tools(config.bin_dir, real_sandbox.project_dir))

    names = {t.name for t in tools.tools}
    assert names == {
        "bmug2_status",
        "bmug2_locate",
        "bmug2_backup_preview",
        "bmug2_archive_preview",
        "bmug2_backup",
        "bmug2_archive",
        "bmug2_unarchive",
        "bmug2_migrate",
        "bmug2_retrieve_preview",
        "bmug2_retrieve",
    }

    by_name = {t.name: t.annotations for t in tools.tools}
    for name in (
        "bmug2_status",
        "bmug2_locate",
        "bmug2_backup_preview",
        "bmug2_archive_preview",
        "bmug2_retrieve_preview",
    ):
        assert by_name[name].read_only_hint is True
        assert by_name[name].destructive_hint is False
    for name in ("bmug2_backup", "bmug2_archive", "bmug2_unarchive", "bmug2_migrate"):
        assert by_name[name].read_only_hint is False
        assert by_name[name].destructive_hint is True
    # bmug2_retrieve: writes to disk (not read-only) but can't destroy or
    # overwrite anything - its own category, see server.py's docstring.
    assert by_name["bmug2_retrieve"].read_only_hint is False
    assert by_name["bmug2_retrieve"].destructive_hint is False

    assert status_r.is_error is not True
    assert any(p["name"] == "myproject" for p in status_r.structured_content["projects"])

    assert locate_r.is_error is not True
    assert locate_r.structured_content["counts"]["index"] >= 0
    assert any(
        r["path"].endswith("file2.txt") for r in locate_r.structured_content["results"]
    )

    assert backup_preview_r.is_error is not True
    assert backup_preview_r.structured_content["success"] is True
    assert backup_preview_r.structured_content["project"] == "myproject"

    assert archive_preview_r.is_error is not True
    assert archive_preview_r.structured_content["success"] is True
    assert archive_preview_r.structured_content["days"] == 0

    # mutating tools - real backup, then a real archive of the snapshot
    # it produced last time (from the fixture), all through the real
    # protocol, not the Python functions directly.
    assert backup_r.is_error is not True
    assert backup_r.structured_content["success"] is True
    assert backup_r.structured_content["project"] == "myproject"

    assert archive_r.is_error is not True
    assert archive_r.structured_content["success"] is True
    assert archive_r.structured_content["project"] == "myproject"


async def _call_unarchive_and_migrate(bin_dir):
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bmug2_mcp.server", "--bin-dir", str(bin_dir)],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            archive_r = await session.call_tool(
                "bmug2_archive", {"project": "myproject", "days": 0}
            )
            # backmeup.archive.sh's stdout looks like:
            #   "archived B-20260907-005457 -> B-20260907-005457.tar.gz (4 entries verified)"
            # - split on " -> " to drop the ".tar.gz (...)" half, then take
            # the last whitespace-separated token to drop the "archived " prefix.
            snapshot = archive_r.structured_content["stdout"].split(" -> ")[0].split()[-1]
            unarchive_r = await session.call_tool(
                "bmug2_unarchive", {"project": "myproject", "snapshot": snapshot}
            )
            migrate_r = await session.call_tool("bmug2_migrate", {"project": "myproject"})
            return unarchive_r, migrate_r


def test_unarchive_and_migrate_over_real_stdio_transport(real_sandbox):
    config = real_sandbox.config
    unarchive_r, migrate_r = asyncio.run(_call_unarchive_and_migrate(config.bin_dir))

    assert unarchive_r.is_error is not True
    assert unarchive_r.structured_content["success"] is True

    # myproject is flat-layout, not the old nested one - migrate must
    # refuse, and that refusal must round-trip through the protocol too
    # (a non-zero exit_code with success: false, not an is_error transport
    # fault).
    assert migrate_r.is_error is not True
    assert migrate_r.structured_content["success"] is False
    assert migrate_r.structured_content["exit_code"] == 1


async def _call_retrieve(bin_dir, destination):
    params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "bmug2_mcp.server", "--bin-dir", str(bin_dir)],
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            archive_r = await session.call_tool(
                "bmug2_archive", {"project": "myproject", "days": 0}
            )
            snapshot = archive_r.structured_content["stdout"].split(" -> ")[0].split()[-1]
            preview_r = await session.call_tool(
                "bmug2_retrieve_preview",
                {
                    "project": "myproject",
                    "snapshot": snapshot,
                    "destination": str(destination),
                    "relative_path": "sub/file2.txt",
                },
            )
            # Checked here, between the two calls - checking it after
            # retrieve_r has also run would trivially pass regardless of
            # whether preview itself created anything, since retrieve
            # creates the destination for real right after.
            preview_created_nothing = not destination.exists()
            retrieve_r = await session.call_tool(
                "bmug2_retrieve",
                {
                    "project": "myproject",
                    "snapshot": snapshot,
                    "destination": str(destination),
                    "relative_path": "sub/file2.txt",
                },
            )
            return snapshot, preview_r, preview_created_nothing, retrieve_r


def test_retrieve_over_real_stdio_transport(real_sandbox, tmp_path):
    config = real_sandbox.config
    destination = tmp_path / "recovered"
    snapshot, preview_r, preview_created_nothing, retrieve_r = asyncio.run(
        _call_retrieve(config.bin_dir, destination)
    )

    assert preview_r.is_error is not True
    assert preview_r.structured_content["success"] is True
    assert preview_r.structured_content["snapshot"] == snapshot
    assert preview_created_nothing, "preview must not have created anything"

    assert retrieve_r.is_error is not True
    assert retrieve_r.structured_content["success"] is True
    assert (destination / "file2.txt").is_file()
    # the archived snapshot itself must be untouched by retrieval
    assert (config.history_dir / "myproject" / f"{snapshot}.tar.gz").exists()
    assert not (config.history_dir / "myproject" / snapshot).exists()
