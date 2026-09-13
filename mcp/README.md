# bmug2-mcp

An MCP (Model Context Protocol) server exposing [bmug2](../README.md) as
tools for an LLM assistant — "back this up", "find that file", "what's
my backup status" as natural language instead of shell commands.

## Status

All 10 tools are implemented: 5 read-only, 4 destructive-mutating, and
`bmug2_retrieve` (writes to disk but can't destroy or overwrite
anything - see its own row below). Not yet exposed at all:
`backmeup.install.sh`/`configure.sh` (interactive-only by design) and
`backmeup.updatedb.sh` (a multi-minute reindex doesn't fit a blocking
tool call) — see Non-goals below.

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
| `bmug2_retrieve_preview` | No | Preview extracting a file (or a whole snapshot) from a project's history. |
| `bmug2_backup` | **Yes** | Back up a directory: copy new/changed files, move changed/deleted files into a dated snapshot. |
| `bmug2_archive` | **Yes** | Compress a project's old snapshots into `.tar.gz`, verified before the original directory is removed. |
| `bmug2_unarchive` | **Yes** | Restore an archived snapshot back to a live directory. |
| `bmug2_migrate` | **Yes** | One-time fix for a project still in the pre-bmug2 nested layout. |
| `bmug2_retrieve` | Writes to disk, but can't destroy/overwrite anything | Extract a file (or a whole snapshot) from a project's history - live or archived - to a destination you choose. Not a restore: it never touches the live mirror or history itself. |

The read-only tools carry `readOnlyHint: true` in their MCP annotations
so a well-behaved client can call them without a confirmation prompt.
The mutating tools carry `destructiveHint: true` — and, since not every
client surfaces annotations in its own consent UI yet, their
descriptions also open with `"MUTATING:"` in plain text. `bmug2_retrieve`
is deliberately a third category: `readOnlyHint: false` (it's a real
action worth tracking, not a query) but `destructiveHint: false` (it
refuses rather than overwriting anything, and never touches `SYNC`/
`HISTORY` at all) — see `mcp/src/bmug2_mcp/server.py`'s module
docstring for why that's the honest signal, not an oversight.

## Safety

- These tools genuinely change files on your backup destination.
  `bmug2_backup`/`bmug2_archive` have preview counterparts
  (`bmug2_backup_preview`/`bmug2_archive_preview`) that run bmug2's own
  `--dry-run` — an assistant (or you) can and should use those first.
- The server never enforces preview-before-mutate sequencing itself;
  that's your MCP client's permission system's job. If your client
  doesn't gate destructive tools by default, treat every mutating call
  here the same way you'd treat typing the equivalent shell command.
- `bmug2_unarchive` refuses to overwrite an existing snapshot
  directory, and `bmug2_migrate` refuses ambiguous or already-flat
  layouts — both mirror the underlying scripts' own safety checks
  exactly (see `docs/MANUAL.md`), the MCP layer adds no new leniency.
- `bmug2_retrieve` is extraction, not restoration: it only ever reads
  from a project's history and writes to the destination you name,
  never touching the live mirror or modifying history itself, and
  refuses rather than overwriting anything already at the destination.
  Making a retrieved file live again is a separate, deliberate step
  it doesn't do for you.
- Every tool call returns the real `success`/`exit_code` from the
  underlying script, never a result silently coerced to look
  successful — a failed operation is reported as failed.

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
