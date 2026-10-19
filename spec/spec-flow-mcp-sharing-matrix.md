# MCP sharing matrix — one server, every assistant

**Status:** built 2026-10-19 as the "sensible version" of a CC Switch-style sharing UI.

## The problem

The MCP tab lists every server with its owner, but a server belongs to exactly one assistant.
Having `codegraph` on Claude and wanting it on Codex, opencode and Cursor today means opening each
app's config by hand. CC Switch solves this with a matrix — servers as rows, assistants as columns,
a checkbox per cell — and that is the shape to copy. Three JSON-config assistants are also missing
from the inventory entirely: opencode, Cursor, Gemini CLI and Windsurf each keep an MCP config
Loadout never reads.

## What ships

1. **More MCP stores.** Loadout reads and writes MCP servers for seven assistants:

   | Assistant | File | Section | Off mechanism |
   |---|---|---|---|
   | Claude Code | `~/.claude.json` | `mcpServers` | lift the entry, keep it in the record (unchanged) |
   | Codex | `config.toml` via app-server | `mcp_servers` | `enabled` flag (unchanged); **adding is refused** — `codex mcp add` owns that |
   | Antigravity | `~/.gemini/config/mcp_config.json` | `mcpServers` | `disabled` flag (unchanged) |
   | Gemini CLI | `~/.gemini/settings.json` | `mcpServers` | lift the entry into a record |
   | Cursor | `~/.cursor/mcp.json` | `mcpServers` | lift the entry into a record |
   | Windsurf | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` | lift the entry into a record |
   | opencode | `~/.config/opencode/opencode.json` | `mcp` | `enabled` flag inside opencode's own entry format |

   Every write is snapshotted first, like every other write. The lift-and-record mechanism reuses
   `OffRecords`, whose server keys gain an assistant namespace for non-Claude owners — Claude's
   existing keys are untouched, so nothing already switched off has to migrate.

2. **The matrix.** On the MCP tab a **List | Sharing** switch swaps the list for the matrix:
   one row per server name, one column per MCP-capable assistant, a checkbox per cell.
   - Checked = enabled in that assistant's config. Present-but-disabled shows as a dash: pressing
     it enables. Absent shows unchecked: pressing it **shares** — the entry is copied from an
     assistant that has it (definition translated into the target's format) into the target's
     config. Pressing a checked cell switches it off the same way the row switch does today.
   - Codex cells: on/off works through the app-server as today; an absent Codex cell is refused
     with a line saying to use `codex mcp add`.
   - The header carries each assistant's mark and how many servers are on for it.

3. **Add MCP.** A sheet: name, command + arguments (or a URL), and which assistants get it.
   One definition, written into each chosen assistant's own format. A name that assistant already
   has is skipped and reported, never overwritten.

4. **Entry translation.** A canonical reading of any entry — command, args, env, url — rendered
   into the target's format: classic `mcpServers` style, Antigravity's `serverUrl` for remotes,
   and opencode's `type/command-array/environment/enabled` style.

## What does not change

- Claude, Codex and Antigravity rows keep their ids, files and behaviour. New rows are
  `mcp:<assistant>:<name>`; a same-name server in two assistants stays two rows on disk —
  the matrix and the Assistants card both read those, and the **list** folds them into one
  row per name (added 2026-10-19 — the same server four times, each with the same usage
  number, was four answers to one question; `MCPList.mergeDuplicates` does the folding,
  display only).
- Project-scope MCP stays Claude-only and never folds, in the matrix or the list.
- No TOML is parsed or written by hand — Codex goes through its app-server, and adding to Codex
  is refused with a pointer at `codex mcp add`.

## How it is built

**Core.**
- `MCPStores.swift` — `MCPStore` descriptor (assistant id, file, section, entry style, switch
  style) and `JSONMCP`, the generic reader/writer over it: `items()`, `setServer(named:enabled:)`,
  `addServer(named:entry:)`, `removeServer(named:)`.
- `MCPEntry.swift` — canonical entry model and per-target rendering (`classic`, `antigravity`,
  `opencode` styles).
- `MCPMatrix.swift` — `rows(items:assistants:)` grouping personal MCP items by name into
  `MCPMatrixRow`s with a cell per assistant.
- `OffRecords.serverKey` gains the assistant parameter; Claude keeps the legacy key form.
- `InventoryScanner` adds the new stores' items; `Mutations.setServer`/`removeServer` dispatch to
  them; `Mutations.shareServer(name:to:)` copies an entry into another assistant's store.

**UI.** `MCPMatrixView.swift` — the matrix and the Add MCP sheet, in the sidebar column when the
Sharing side of the switch is on (the same column-swap the Plugins tab already does). `AppModel`
grows `showsMCPSharing` (persisted), `mcpMatrixRows`, `toggleMCPMatrixCell` and `addMCPServer`.

## Tests

- Each new store: read (rows, ids, enabled, description), flag flip or lift-out, add, remove,
  snapshot-before-write, malformed file never overwritten.
- Off-record namespacing: a lifted Cursor server and a lifted Claude server of the same name are
  two records; Claude's legacy key still reads.
- Translation: Claude command entry → opencode local entry; URL → antigravity `serverUrl` and
  opencode remote; round trip description matches.
- Matrix: grouping by name, cell states (present on/off, absent, codex unwritable), counts.
- Scanner: a fixture with all stores populated shows one row per server per owner.
- Add MCP: writes chosen assistants, skips and reports collisions, refuses an invalid name.
