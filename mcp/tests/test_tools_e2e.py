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
            backup_r = await session.call_tool(
                "bmug2_backup_preview", {"path": str(project_dir)}
            )
            archive_r = await session.call_tool(
                "bmug2_archive_preview", {"project": "myproject", "days": 0}
            )
            return tools, status_r, locate_r, backup_r, archive_r


def test_all_read_only_tools_over_real_stdio_transport(real_sandbox):
    config = real_sandbox.config
    tools, status_r, locate_r, backup_r, archive_r = asyncio.run(
        _call_tools(config.bin_dir, real_sandbox.project_dir)
    )

    names = {t.name for t in tools.tools}
    assert names == {
        "bmug2_status",
        "bmug2_locate",
        "bmug2_backup_preview",
        "bmug2_archive_preview",
    }
    for t in tools.tools:
        assert t.annotations is not None
        assert t.annotations.read_only_hint is True
        assert t.annotations.destructive_hint is False

    assert status_r.is_error is not True
    assert any(p["name"] == "myproject" for p in status_r.structured_content["projects"])

    assert locate_r.is_error is not True
    assert locate_r.structured_content["counts"]["index"] >= 0
    assert any(
        r["path"].endswith("file2.txt") for r in locate_r.structured_content["results"]
    )

    assert backup_r.is_error is not True
    assert backup_r.structured_content["success"] is True
    assert backup_r.structured_content["project"] == "myproject"

    assert archive_r.is_error is not True
    assert archive_r.structured_content["success"] is True
    assert archive_r.structured_content["days"] == 0
