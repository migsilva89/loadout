# MCP servers across assistants

**Status:** approved 2026-09-19 and implemented, for the same release as Antigravity support (issue #12).
**Branch:** `antigravity-support`.

## The problem

The MCP tab reads one file — `~/.claude.json` — so it is Claude's list wearing the app's name. Codex
keeps three servers on this machine in `~/.codex/config.toml`; Antigravity keeps its own in
`~/.gemini/config/mcp_config.json`. Neither shows up, and a person with all three installed has no
way to tell, from the tab, whose server a row is. Skills and commands already answer that question
with the assistant marks; MCP does not.

Mixing the lists naively is worse than not showing them: the switch on an MCP row today rewrites
`~/.claude.json`, so a Codex server that landed in the same list would be "switched off" by
deleting a Claude entry that does not exist, or worse, one that does and shares the name.

## What ships

1. **One list, every owner.** The MCP tab shows Claude's, Codex's and Antigravity's servers. Each
   row carries the mark of the assistant that owns it, the same marks skills use, and the detail
   header says the file it lives in.
2. **The assistant filter works on MCP.** The menu that already narrows skills and commands to one
   assistant — or to "in 2+" — appears on the MCP tab too. Two assistants with a server of the
   same name are two rows, not one: unlike a skill, a server is not a file that can be shared, and
   its config differs per assistant (`disabled` here, `enabled` there, an OAuth login elsewhere).
3. **The switch does what each assistant does.** Off and on go through the owner's own mechanism,
   never through another owner's file:

   | Owner | Read from | Off / on | Remove |
   |---|---|---|---|
   | Claude Code | `~/.claude.json` (+ per-project, + repo `.mcp.json`) | unchanged: lift the entry, keep it in Loadout's record | unchanged |
   | Codex | `config/read` over the app-server, `mcp_servers` table | `config/value/write` on `mcp_servers.<name>.enabled` — the same call the plugin switch uses | not offered (a TOML table with nested `env`, and Codex has `codex mcp remove` for it) |
   | Antigravity | `~/.gemini/config/mcp_config.json`, `mcpServers` | write `"disabled": true/false` in place — the flag `agy mcp disable` writes | remove the entry, after a snapshot |

   Every write is preceded by a snapshot in Loadout's backups, as every write already is.
4. **Usage stays honest.** Claude's MCP usage (the `mcp__server__tool` calls) keeps counting. Codex
   and Antigravity MCP usage is not counted yet and the row says nothing rather than zero: the
   "never used" filter excludes rows whose owner has no MCP usage signal, so a Codex server is
   never called unused because we cannot see it being used.

## What does not change

- Claude's MCP rows keep their ids (`mcp:personal:<name>`, `mcp:<project>:<name>`) and their whole
  behaviour, including repo-declared servers and the off-record. This is the part 0.4.x users rely
  on; the new rows are added beside it, not by rewriting it.
- Codex servers a plugin installs are not listed: Codex keeps them with the plugin and never
  returns them as `mcp_servers`, so the plugin's own switch remains the way to them.
- Project scope: only Claude has per-project MCP; Codex and Antigravity rows are personal only.
- No Codex app-server means no Codex MCP rows and the diagnostic already shown for plugins. Never a
  guess parsed out of the TOML by hand.

## How it is built

**Model.** `Item.assistants` is set to `[owner]` for every MCP row (today it is empty for MCP, so
nothing reading it changes for Claude except that the mark lights up). New ids: `mcp:codex:<name>`,
`mcp:antigravity:<name>`. `Item.path` points at the owner's file.

**Reading.**
- `InventoryScanner.mcpServers()` — unchanged, then tagged `assistants: ["claude"]`.
- `CodexPlugins.scan` already holds the `config/read` result; it gains `servers(from:)` that turns
  `config.mcp_servers` into rows (`enabled` defaults to true; `command`+`args` or `url` for the
  description; a `plugin` source marks it read-only). Fixture-testable with the same
  `inventory(installed:skills:settings:)` entry point the plugin tests use.
- New `AntigravityMCP` (Core): reads `mcpServers`, `disabled` flag, `command`/`args`/`serverUrl`.

**Writing.** `Mutations.setServer` dispatches on the owner in `item.assistants`: `claude` → the
existing code, untouched; `codex` → `CodexPlugins.setServer`, mirroring `setPlugin` (snapshot,
`expectedVersion`, `status == ok`); `antigravity` → `AntigravityMCP.setServer`, which reads the
file, flips one key, writes it back with the other keys as they were. `removeServer` accepts
`claude` and `antigravity`; for `codex` the row offers no Remove and the detail says why in one line.

**Filtering.** `AssistantFilter` gating in the sidebar (`selection == .skills || .commands ||
.agents`) gains `.mcp`; `Filtering.filter(by: AssistantFilter)` already works on `assistants`.
`ItemFilter.neverUsed` on MCP excludes rows whose owner has no MCP usage source.

**UI.** Row marks and the detail header come from what skills already render; the MCP detail gets
the owner's file in its path line and, for Codex, the read-only note where Remove would be.

## Tests before merge

- Three fixtures side by side: a Claude server, a Codex server (via fake `config/read`), an
  Antigravity server — three rows, three owners, correct `path`, correct `enabled`.
- Same name in two owners → two rows; `.multiple` filter matches neither.
- Antigravity off/on: the flag flips, every other key byte-for-byte the same, a snapshot exists,
  a malformed file throws and writes nothing.
- Codex off/on: the `config/value/write` params (keyPath, value, expectedVersion) — asserted through
  the fake connection; a non-`ok` status surfaces as the existing override message.
- Claude: the existing `AgentAndServerTests` pass unchanged — the regression fence.
- `neverUsed` on an MCP tab with a Codex row does not list it.
- Manual, on this machine: 3 Codex servers (one disabled, two from the bundled plugin), Claude's
  list as before, Antigravity empty until `agy mcp add` — then one row that switches.

## Resolved while building

Codex servers a plugin brings along never reach `config/read`'s `mcp_servers` — Codex keeps them
with the plugin — so the list holds only what the person wrote in `config.toml`, and the question
of showing plugin servers read-only did not arise.
