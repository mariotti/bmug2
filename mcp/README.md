# bmug2-mcp

An MCP (Model Context Protocol) server exposing [bmug2](../README.md) as
tools for an LLM assistant — "back this up", "find that file", "what's
my backup status" as natural language instead of shell commands.

## Status: v1, read-only tools only

This first version exposes only tools that cannot change anything on
disk: `bmug2_status`, `bmug2_locate`, `bmug2_backup_preview`, and
`bmug2_archive_preview` (the last two run bmug2's own `--dry-run` mode).
Real backup/archive/unarchive/migrate tools are a deliberate follow-up —
see `docs/CONTRIBUTING.md` in the main repo for why, and the plan behind
this component in general.

## Requirements

- bmug2 already installed and configured (`backmeup.install.sh` /
  `backmeup.configure.sh` run at least once) — this server reads that
  configuration, it doesn't set bmug2 up for you.
- Python >= 3.10.

## Install

```
cd mcp
pip install -e .
```

## Configure and run

The server needs to know where your bmug2 scripts and generated
`backmeup.setup.sh` live — there's no auto-discovery, since bmug2 has no
single well-known install location. Pass it explicitly:

```
bmug2-mcp --bin-dir /path/to/your/bmu/bin
```

or via environment variable, which is how most MCP clients register a
server:

```json
{
  "mcpServers": {
    "bmug2": {
      "command": "bmug2-mcp",
      "env": { "BMUG2_BIN_DIR": "/Users/you/usr/bmu/bin" }
    }
  }
}
```

Transport is stdio only — this is a local, single-user tool with no
current need for a network-exposed server.

## Tools

| Tool | Mutates disk? | Description |
|---|---|---|
| `bmug2_status` | No | Per-project overview: last run, last change, snapshot count, mirror/history sizes. |
| `bmug2_locate` | No | Search current mirror, history, and archived snapshots for one or more patterns. |
| `bmug2_backup_preview` | No | Preview (`--dry-run`) what backing up a directory would do. |
| `bmug2_archive_preview` | No | Preview (`--dry-run`) which snapshots of a project would be archived. |

All four are marked read-only in their MCP tool annotations, so a
well-behaved client shouldn't gate them behind a confirmation prompt.

## Development

```
cd mcp
pip install -e ".[dev]"
pytest
```

Tests build a real bmug2 sandbox (same approach as `tests/test_backmeup.sh`
in the main repo — real commands against real temp directories, not
mocked) and drive both the tool functions directly and, for a small
subset, the actual MCP stdio protocol.
