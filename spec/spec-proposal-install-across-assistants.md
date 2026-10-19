# Installing across assistants — the install matrix

**Status:** proposed 2026-10-19, not yet approved. A feature outside the scope in
CONTRIBUTING.md is declined however well it is written, so this needs an issue before a
branch.

The format follows the house spec-flow documents (`spec-flow-mcp-across-assistants.md`
and the rest): the problem, what ships, what does not change, how it is built, tests
before merge. The last section is a backlog of smaller improvements that fell out of the
same review.

## The problem

Loadout already knows how to put a skill on a second assistant — click the assistant's
mark in the Assistants card, and the folder is promoted to `~/.agents/skills` with a
symlink. But it works one item at a time, in the detail pane, and only for skills and
commands. Three gaps remain:

1. **MCP servers cannot move at all.** Loadout reads Claude's, Codex's and Antigravity's
   servers and switches each through its owner's mechanism, but there is no way to take a
   server one assistant has and give it to another. You set `codegraph` up in Claude Code
   by hand-typing the command; you then hand-type it again into Codex, and again into
   Antigravity, in three different config dialects. This is the question people actually
   ask: *why do I have to type this three times?*
2. **Subagents are Claude's alone.** The scanner reads `~/.claude/agents` and nothing
   else, so an opencode or Factory agent folder on the same machine is invisible, and
   there is no share path for the kind even where a second assistant reads the same
   convention.
3. **Reach, not mechanism.** Skills and commands have the core operations
   (`share`/`unshare`, `shareCommand`/`unshareCommand`) but the only surface is the
   per-item Assistants card. Answering "what does Codex not have yet?" means clicking
   through items one by one. CCSwitch answers it with one screen — rows are servers,
   columns are clients, a checkbox per cell — and that is the shape missing here.

## What ships

1. **A matrix sheet: one row per item, one column per installed assistant.** Opened from
   the Loadout menu and the toolbar as **Install across assistants…**, showing the
   current tab's kind (skills, commands, subagents or MCP). Rows follow the tab's list;
   columns are the assistants Loadout discovered on this machine (`AssistantRegistry.discover`),
   narrowed by Settings › Assistants — never the full hardcoded registry. A search field
   across the top filters rows by name and description. Each column header carries a
   count of that assistant's items of this kind, the same "3 loaded of 8" caption the
   Assistants card uses today.
2. **A cell is a checkbox, and it means presence.** Lit = that assistant loads this item.
   Clicking an unlit cell installs; clicking a lit cell removes that assistant's link or
   entry — with every guard the per-item flow has today: the only real copy is not a
   removal (it is a dimmed cell that says why), a real copy with the same name in the
   target is refused with the existing message rather than overwritten, and a Codex
   server's Remove stays refused with the one-line reason, exactly as the detail pane
   says it today.
3. **Subagents join the shareable kinds.** `Assistant` gains an `agentsRoot`, resolved
   by the same "whichever folder exists" convention as `commandsRoot` (`agents` next to
   the skills root; an assistant with no such folder gets none). The scanner picks up
   `~/.<id>/agents` personal folders so a second assistant's agents appear as rows with
   their marks. New `Mutations.shareAgent`/`unshareAgent`, symlink-shaped like
   `shareCommand`. On the matrix, an assistant without an `agentsRoot` has no column
   cell for this kind — the column is absent, not a dead checkbox.
4. **MCP servers become installable.** A new `MCPDefinition` value (Codable: `command`,
   `args`, `env`, `url`, `type` — whichever the entry carries) is captured at scan time
   by all three owners' readers and carried on the item, so Loadout holds the whole
   server rather than the display string `mcpItem` keeps today. `Mutations.installServer(_:into:)`
   translates it into the target owner's dialect:

   | Target | Written to | Shape |
   |---|---|---|
   | Claude Code | `~/.claude.json`, root `mcpServers` | the entry as Claude writes it; snapshot first, refuse if the name exists |
   | Antigravity | `~/.gemini/config/mcp_config.json`, `mcpServers` | same shape, no `disabled` flag — the server arrives on |
   | Codex | app-server `config/value/write` on `mcp_servers.<name>` | the TOML table Codex would hold, written through the protocol, never parsed or emitted by hand |

   Env values are copied verbatim — same machine, same user — but the sheet never
   renders them; a cell's tooltip shows the command and args only.
5. **MCP rows group by name in the matrix.** The tab keeps today's two-rows-per-name
   decision (two owners, two configs); the matrix does not, because its question is
   "where is this server?" — one row per name, one cell per assistant. When two owners
   hold the same name with different definitions, the row refuses installs into a third
   assistant and says why, the same refusal `promoteToShared` gives two real skill
   copies: *merge them by hand first*. This grouping is the sheet's own; nothing about
   the tab's rows changes.
6. **Honest columns.** A cell exists only where Loadout can actually write. An assistant
   discovered on the machine but owning no config Loadout writes for this kind gets a
   dimmed cell with a help line saying what is missing — not a checkbox that fails on
   click. The count in a column header counts what Loadout can prove is loaded.

## What does not change

- The per-item Assistants card stays as it is. The matrix is a second surface over the
  same operations, not a replacement; someone who has never opened the sheet loses
  nothing.
- MCP switching semantics: presence in the matrix is not the switch. A server switched
  off (its entry lifted into Loadout's record) is unlit in its owner's cell — it is not
  loaded — and the row keeps the off-state caption so "off, not forgotten" survives the
  move to this surface.
- The tab's own lists, ids and filters. Same-name MCP rows stay two rows in the MCP tab.
- Repo-shown servers (`.mcp.json`) appear as rows but their cells are read-only, with
  the existing "belongs to the team" explanation. Installing one into your personal
  scope is the backlog item below, not this sheet.
- Every write keeps the house rules: snapshot to Loadout's backups first, refuse rather
  than overwrite, records written before destructive steps, Codex through its app-server,
  every path through `Paths`.

## How it is built

**Model.** `Item` gains `mcpDefinition: MCPDefinition?`. `MCPDefinition` (Core, Codable,
Equatable) is the neutral shape all three dialects translate through; it holds only keys
present in the source entry and nothing it does not understand. Translation lives in one
place per target: `MCPDefinition.claudeEntry()`, `.antigravityEntry()`, `.codexTable()`
— pure functions, fixture-testable without touching a real config.

**Core.** `InventoryScanner.mcpItem` populates `mcpDefinition` from the config dict it
already parses; `CodexPlugins.servers(from:)` and `AntigravityMCP.items()` do the same
from their own reads. New mutations beside the existing sharing block in `Mutations.swift`:

- `installServer(_:name:into assistant:) throws` — dispatch on the target id: Claude and
  Antigravity snapshot the config, merge one key into `mcpServers`, write back with the
  other keys byte-for-byte as they were (the `setPlugin` pattern on
  `settings.local.json`); Codex goes through the app-server with the same
  `expectedVersion` discipline `CodexPlugins.setServer` uses.
- `removeServerEntry(_:from assistant:)` — Claude and Antigravity only; Codex throws the
  existing "Codex has `codex mcp remove`" refusal, which the cell surfaces as its help
  line.
- `shareAgent`/`unshareAgent` — copy the `shareCommand` shape against `agentsRoot`.
- `installGaps(kind:items:assistant:)` — the matrix's read side: for each item, whether
  the assistant loads it, and if not, whether a cell is offerable at all (capability,
  not just absence). `AppModel` renders this; it is Core so the rules are testable.

**App.** New `InstallMatrixSheet` (SwiftUI, in `Sources/LoadoutApp`), bound to
`model.items` filtered by the current tab's kind, so the FSEvents reload updates cells
live — the FSEvents reload already re-runs the scanner; nothing extra is needed for
freshness. Cell taps route through new `AppModel.install(item:assistant:present:)` /
`remove(item:assistant:)` methods that call the mutations and `reload()`, the same
`perform` wrapper the other actions use. The menu item lives in `CommandMenu("Loadout")`
next to **Sync all with …**; the toolbar button is offered on all four tabs.

**What the builder must probe rather than assume.**

1. **Codex write of a new table.** `config/value/write` is proven for setting
   `mcp_servers.<name>.enabled`; whether the app-server accepts a table value for a key
   that does not exist yet is not proven here. Extend `--self-check-codex` to try it on
   a temporary marketplace before anything else. If the protocol refuses, the cell
   degrades to the honest refusal Loadout already prefers: it offers to copy the exact
   `codex mcp add …` command to the clipboard, built from the definition, and says why
   it is a copy and not a write.
2. **Remote servers.** Claude's `{type, url}` entries and Codex's `url` tables are not
   proven equivalent here; if the translation is uncertain for an entry shape, install
   for that shape is refused with the reason, not guessed.
3. **Column set per kind.** Confirm on a real machine which discovered assistants hold
   an `agentsRoot` before shipping the subagent columns; the convention must not invent
   folders for assistants that do not read them.

## Tests before merge

All against `Fixture`, never a real home (AC9.2):

- Claude server → Antigravity: entry lands in `mcp_config.json`, every other key
  byte-for-byte the same, a snapshot exists, a second install of the same name is
  refused and writes nothing.
- Antigravity server → Claude: the same, symmetric, and `~/.gemini/config` is never
  created by a Claude-only install.
- Codex write through the fake connection: exact `config/value/write` params
  (keyPath, value, expectedVersion), mirroring `CodexPluginTests`.
- A refused Codex probe (fake returns non-`ok`) surfaces the clipboard fallback, and
  the fallback command string is asserted exactly.
- `MCPDefinition` round-trips through all three dialect fixtures without losing keys it
  does not model, and never carries an unknown key into a target it would corrupt.
- Same name, two different definitions, third assistant: install refused with the merge
  message; identical definitions install normally.
- `shareAgent`/`unshareAgent`: link created, real copy never removed, second assistant
  unlinked without touching the first, refusal when the target already holds a real
  file.
- An assistant with no `agentsRoot` produces no cell and no mutation call.
- The regression fence: existing `AgentAndServerTests`, `MCPAcrossAssistantsTests`,
  `DisableAcrossAssistantsTests`, `CommandTests` pass unchanged.
- Manual, on this machine: the matrix with Claude, Codex and Antigravity discovered,
  one server installed into each in turn, counts in the headers matching the tabs.

## Backlog — other improvements from the same review

Ordered by how much of the everyday friction each removes. Every one of these needs an
issue first, per CONTRIBUTING.md; anything touching sync between machines or writing
without a backup is out of scope by the same document and is marked below.

1. **Adopt a repo's server into your own scope.** A `.mcp.json` row currently offers
   only the team's on/off record. "Add to my Claude config" would copy the definition
   into `~/.claude.json` — the MCP analogue of *Make global*, same copy-not-move
   reasoning, same refusal when the name is taken. Small once `MCPDefinition` exists.
2. **Recent changes with one-click undo.** Backups are taken before every write but are
   only reachable as files. A Settings › Backups list of the last N snapshots — what was
   written, when, restore button — turns the safety net into something used. Restore
   itself re-uses the existing backup machinery; no new write paths.
3. **A drift badge for diverging copies.** The app already refuses to merge two real
   skill copies silently; the matrix (and the sidebar) could mark the row — "differs in
   2 assistants" — so the conflict is visible before someone tries to share, not only
   when the share fails.
4. **Batch operations on the matrix.** Row context menu: install in all columns, remove
   from all but one. The per-cell path makes each of these reachable already; batch is
   convenience, which is why it is here and not in what ships.
5. **Read support for more assistants' MCP configs.** opencode (`opencode.json`),
   Cursor (`~/.cursor/mcp.json`) and Windsurf keep servers in files Loadout does not
   read yet. Each is a new owner in the scanner plus a dialect in `MCPDefinition` —
   mechanical once the translation layer exists, but each needs its own probe of the
   real format first.
6. **Tidy-up report.** "Installed in 3 assistants, never fired in 2" as a filter or a
   Settings report, built on the usage index and the matrix's gap data. Honest counts
   rules apply verbatim: an assistant whose usage Loadout cannot read is not accused of
   disuse.
7. **Generalise Sync all with ….** The menu item is skills-only (`gaps(for:)` filters to
   `.skill`); once the matrix's gap computation exists in Core, the menu item can cover
   commands and subagents too.
8. **Export/import a loadout as a file.** A JSON of your personal definitions to move
   to another machine by hand. *Likely out of scope*: CONTRIBUTING.md rules out syncing
   between machines, and an export file is half of that. Raise the issue knowing it may
   be declined; if it is wanted, the line to argue is that the app never talks to a
   network and the file travels by the user's own means.
