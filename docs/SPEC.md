# Loadout — specification

A native Mac app for viewing and managing what coding assistants load: skills, commands, subagents, plugins and MCP servers. Replaces the working name *SkillDeck*.

**Why it exists.** The problem is "I don't know what I have". There are 21 personal skills, more than 40 coming from plugins, plus commands, agents and MCP servers scattered across four places on disk. Loadout is the inventory — and, because looking without being able to change anything is annoying, it is also the editor.

**The name.** A *loadout* is the kit you take on a mission. That is exactly what the app shows: what Claude takes into a session, and what stayed at home.

---

## Settled decisions

| Topic | Decision |
|---|---|
| Scope | Personal and project skills, slash commands, subagents, plugins, MCP servers |
| Form factor | Native SwiftUI Mac app, ordinary window in the Dock |
| Writing | Full: create, edit, delete, move, enable/disable |
| Disabling a skill | Move the folder to `~/.claude/skills-off/` |
| Disabling a plugin | `enabledPlugins` in `~/.claude/settings.local.json` |
| Safety net | Snapshot in `~/Library/Application Support/Loadout/backups/<ISO>/` before every write |
| Usage | SQLite index of the transcripts, 90 days by default, with a button to sweep everything |
| Talking to an assistant | A conversation beside the editor, run through the assistant CLI already on the machine. It proposes changes; I accept them one at a time and save. |
| UX | Source sidebar with counts · list with origin and usage badges · detail with the raw file |
| Target | Personal, but written so it can be released: no hardcoded paths, with a README |

## Data sources on disk

| What | Where |
|---|---|
| Personal skills | `~/.claude/skills/<name>/SKILL.md` |
| Disabled skills | `~/.claude/skills-off/<name>/SKILL.md` |
| Project skills | `<repo>/.claude/skills/<name>/SKILL.md` |
| Plugin skills | `~/.claude/plugins/cache/<mkt>/<plugin>/<version>/skills/<name>/SKILL.md` |
| Commands | `~/.claude/commands/*.md`, `<repo>/.claude/commands/*.md`, `<plugin>/commands/*.md` |
| Agents | `~/.claude/agents/*.md`, `<repo>/.claude/agents/*.md`, `<plugin>/agents/*.md` |
| Installed plugins | `~/.claude/plugins/installed_plugins.json` |
| Enabled plugins | `enabledPlugins` in `~/.claude/settings.json` and `settings.local.json` |
| MCP servers | `mcpServers` in `~/.claude.json` (global and per project) |
| Projects | `~/Projects/INDEX.md` — markdown tables, first column holding the relative path |
| Usage | `~/.claude/projects/**/*.jsonl` |

Usage signals, by item type:

- **Skill** — a `tool_use` with `name: "Skill"` and `input.skill` equal to the name.
- **Command** — `<command-name>/name` in the content of user messages.
- **Agent** — `"subagent_type":"name"` in the input of a `tool_use`.
- **MCP** — a `tool_use` whose name starts with `mcp__<server>__`.

Every record has a `timestamp` and a `cwd`, which gives recency and which projects it fired in.

---

## Acceptance criteria

Every AC is verifiable. `[T]` means covered by an automated test; `[M]` means verified by me in the running app.

### AC1 — Inventory

- **AC1.1** `[T]` The app finds the personal skills in `~/.claude/skills`, one per folder containing a `SKILL.md`, and reads `name` and `description` from the YAML frontmatter.
- **AC1.2** `[T]` Invalid or missing frontmatter does not make the app fail: the item appears with the folder name and a visible warning in the detail.
- **AC1.3** `[T]` Skills in `~/.claude/skills-off` appear marked as disabled.
- **AC1.4** `[T]` Plugin skills are found in the installed version of each plugin, and attributed to the right plugin.
- **AC1.5** `[T]` Commands, agents and MCP servers are inventoried from all three origins (personal, project, plugin) where applicable.
- **AC1.6** `[T]` The project list comes from `~/Projects/INDEX.md`; if the file does not exist, the app works with Global only.
- **AC1.7** `[M]` The sidebar shows counts per source, and they add up with what the list shows.

### AC2 — View and navigation

- **AC2.1** `[M]` A two-column window — list and detail — with the kinds in a title bar of their own (v2 redesign, 2026-08-13). The sidebar collapses and the state persists across launches.
- **AC2.2** `[T]` The scope switches between Global and a project. In a project, the list shows **only what belongs to that project** — a project with nothing in it shows up empty, never as an echo of the global inventory (decided 2026-08-13; the old merge was confusing).
- **AC2.3** `[M]` Each row shows the name, the assistants that load it, the number of uses, the switch, and the description over two lines. The origin lives in the tooltip and in the detail. Disabled items appear dimmed.
- **AC2.4** `[T]` Search filters by name and by description, ignoring case and accents, and updates the list on every keystroke.
- **AC2.5** `[M]` The detail shows name, type, origin, path, modification date, the raw content of the file, and the usage line.
- **AC2.6** `[M]` A deliberate dark theme, fixed — the v2 redesign palette. The app does not follow the system preference (decided 2026-08-13).
- **AC2.7** `[M]` Keyboard navigation: arrow keys to move through the list, `⌘F` for search, `⌘N` for a new skill, `⌘⌫` to delete.

### AC3 — Enabling and disabling

Rewritten 2026-08-15 — see `spec/spec-flow-enable-disable-skills.md` for the flow behind these. Every skill has a switch now, whoever owns it, and a disabled skill never changes hands.

- **AC3.1** `[T]` Disabling a skill moves its real folder into the `skills-off` beside its owner's `skills` root — `~/.codex/skills-off` for a Codex skill, `~/.agents/skills-off` for a shared one — with all its content intact.
- **AC3.2** `[T]` Disabling a skill several assistants load removes every non-owner symlink and asks nothing. Taking it out of one assistant only is the assistant dots, not this switch.
- **AC3.3** `[T]` Disabling records the owner and the assistants that were loading it, in `~/Library/Application Support/Loadout/skills-off.json`.
- **AC3.4** `[T]` If the destination already exists, the operation fails with a clear error and destroys nothing.
- **AC3.5** `[M]` Enabling asks where: a sheet of assistants, pre-ticked from that record, or from where the folder is parked when there is no record — and it says which of the two it is.
- **AC3.6** `[T]` One assistant chosen means the real folder goes there, with no symlink left anywhere; several means the shared store holds it and each gets a link.
- **AC3.7** `[T]` A round trip — disable, then enable confirming what the sheet proposes — leaves the disk exactly as it was, symlinks included.
- **AC3.8** `[T]` Disabling a plugin writes `enabledPlugins["<plugin>@<mkt>"] = false` in `settings.local.json`, preserving the rest of the file exactly as it was.
- **AC3.9** `[T]` A single plugin skill can be disabled on its own: it moves to `skills-off` inside the plugin's installed version, and the choice is recorded by name under `<plugin>@<marketplace>`.
- **AC3.10** `[T]` After a plugin update the recorded choices are re-applied on the next scan, so a new version does not silently switch skills back on. A name the plugin no longer ships is skipped, and kept.
- **AC3.11** `[M]` A plugin skill's row carries a tag with the plugin's name, and selecting a plugin fills the detail pane with what it ships, each item switchable there.
- **AC3.12** `[T]` A project skill parks in `<repo>/.claude/skills-off`, and `[M]` the first disable says once that the change will show up in the repository.
- **AC3.13** `[M]` The state on screen reflects the disk immediately after the operation.

### AC11 — The last three (2026-08-15)

See `spec/spec-flow-agents-mcp-frontmatter.md`. Every kind Loadout lists can now be switched off without deleting it, and the frontmatter is read as the nested thing it is.

- **AC11.1** `[T]` Nested frontmatter is read as a tree: `metadata.promptSignals.minScore` stays inside its parents instead of arriving as a field of the skill.
- **AC11.2** `[T]` A list of maps keeps every entry — two `validate` rules are two rules, each with its own `pattern`, `message` and `severity`.
- **AC11.3** `[T]` Inline lists (`[a, b]`) and dashed lists read the same.
- **AC11.4** `[T]` `name` and `description` read as before, folded and quoted values included; a flat frontmatter produces exactly what it produced before.
- **AC11.5** `[M]` The preview shows the nesting: a child is visibly inside its parent, and a list entry is visibly one of several.
- **AC11.6** `[T]` Disabling a subagent moves the file to `agents-off` beside its own directory; enabling moves it back, and it stays listed either way.
- **AC11.7** `[T]` A plugin's subagent is recorded and re-applied after a plugin update, under the same record as its skills and commands.
- **AC11.8** `[M]` The New button offers "New subagent" on the Agents tab, and creates one with `name` and `description`.
- **AC11.9** `[T]` Disabling an MCP server lifts its entry out of `~/.claude.json` into Loadout's record; every other key in that file is untouched.
- **AC11.10** `[T]` Enabling puts the entry back exactly as it was, and clears the record.
- **AC11.11** `[T]` A disabled server is still listed, marked off, with its command or URL readable — off, not forgotten.
- **AC11.12** `[T]` The entry is remembered before it is removed, and `~/.claude.json` is snapshotted first; a server that is not there is refused rather than invented.

### AC4 — Editing, creating, deleting

- **AC4.1** `[M]` The detail has a `SKILL.md` editor in a monospaced typeface, and saves with `⌘S`.
- **AC4.2** `[T]` Saving validates the frontmatter: `name` and `description` are required, `name` in kebab-case. An invalid file is not written, and the app explains why.
- **AC4.3** `[T]` Creating a new skill generates `~/.claude/skills/<name>/SKILL.md` from a template, with the name validated and without overwriting anything.
- **AC4.4** `[T]` Deleting moves the folder to the Trash, it does not `rm` it.
- **AC4.5** `[M]` "Reveal" opens the folder in the Finder (the external editor button was removed on request, 2026-08-13); the built-in editor covers editing.
- **AC4.6** `[T]` Plugin files are read-only: trying to save returns an error and does not touch the disk.
- **AC4.7** `[M]` The New skill sheet has a second exit, "Create and ask": it creates the skeleton and hands it to an assistant with what I wrote as the brief, so it can propose the `description` and the body. The file stays as the skeleton until I accept the changes and save — the hard part of a new skill is not the folder.

### AC5 — Safety net

- **AC5.1** `[T]` Before any write, move or delete, a copy is created in `~/Library/Application Support/Loadout/backups/<ISO-8601>/<relative-path>`.
- **AC5.2** `[T]` The snapshot preserves the folder's complete tree, not just the `SKILL.md`.
- **AC5.3** `[M]` The menu has "Reveal backups in Finder".
- **AC5.4** `[T]` If the snapshot fails, the write is aborted — nothing is ever written without a copy having been made.

### AC6 — Usage index

- **AC6.1** `[T]` The index reads `~/.claude/projects/**/*.jsonl` and counts uses of skills, commands, agents and MCP servers.
- **AC6.2** `[T]` Indexing is incremental: a file whose size and date have not changed is not read again.
- **AC6.3** `[T]` By default only records from the last 90 days are included; there is an action to index the full history.
- **AC6.4** `[M]` The first indexing run happens in the background with visible progress, and the app stays usable.
- **AC6.5** `[T]` Each item knows: total uses, date of last use, and how many distinct projects it fired in.
- **AC6.6** `[T]` A transcript file that is corrupt part way through does not interrupt the indexing of the rest.
- **AC6.7** `[M]` The list can be sorted by name or by number of uses.

### AC7 — Talking to an assistant

- **AC7.1** `[M]` An "Ask" button in the detail opens a conversation in a column beside the document — beside it, not on top of it, because deciding on a change means reading the proposal and the file at the same time.
- **AC7.2** `[T]` Ask only offers the assistants Loadout knows how to talk to — today `claude`, `codex` and `opencode`. `cursor-agent` is left out because it requires an interactive login. If none of them is on the PATH, the app says so instead of failing silently. The others still appear in the rest of the app and still count towards usage.
- **AC7.3** `[M]` The reply appears as it is written, not all at once at the end.
- **AC7.4** `[T]` The process has a timeout and can be stopped; stopping kills the child process.
- **AC7.5** `[M]` There is one conversation per skill, resumed by the assistant's own session id. I quit the app, come back, and it carries on. A button starts a new conversation.
- **AC7.6** `[T]` The assistant always runs in a disposable copy of the skill's folder, never in `~/.claude`. It has write permission there, and runs commands on its own initiative — verified.
- **AC7.7** `[T]` The changes proposed to me are computed by Loadout, by comparing the copy against the real folder. No output format from any assistant decides what goes into my file — and that is what makes this work with `codex`, which says it touched a file but never what it changed.
- **AC7.8** `[M]` Each change is accepted or rejected on its own. Accepting changes the draft being edited and lights up Save; Save is still mine, with the mandatory backup before writing.
- **AC7.9** `[T]` A rejected change is never written, not even after the one next to it is accepted.
- **AC7.10** `[M]` A skill is a folder: the files beside the document that it touched are listed, and the ones I accepted are written by the same Save, each with its own backup.
- **AC7.11** `[T]` The working copy is never deleted while there is still a change waiting to be decided. Copies whose conversation no longer exists are swept away at launch.
- **AC7.12** `[M]` An assistant I added in Settings does not appear in Ask: Loadout does not know its options and does not invent them.

### AC8 — Reacting to the disk

- **AC8.1** `[M]` Changing a `SKILL.md` outside the app updates the view without me having to reload.
- **AC8.2** `[M]` Creating or deleting a skill folder outside the app updates the counts.
- **AC8.3** `[T]` Re-reading is coalesced: many changes in quick succession do not trigger many scans.

### AC9 — Quality and delivery

- **AC9.1** `[T]` `swift test` passes, with no skipped tests.
- **AC9.2** `[T]` The tests run against a temporary tree, never against the real `~/.claude`.
- **AC9.3** `[M]` `Scripts/build-app.sh` produces `dist/Loadout.app`, which opens on a double click.
- **AC9.4** `[M]` The app has an icon of its own in the Dock and in the Finder.
- **AC9.5** `[M]` No user path is hardcoded in the code; everything derives from `FileManager.homeDirectoryForCurrentUser` or from configuration.
- **AC9.6** `[M]` A README covering what it is, how to build it, and how to run the tests.
- **AC9.7** `[T]` `Scripts/test-update.sh` passes against the assembled bundle: Sparkle is embedded, it and its installer are signed, the app can find it, and the feed address and signing key are in the Info.plist.
- **AC9.8** `[M]` An installed copy offered a signed update downloads and installs it itself, and reopens on the new version.

---

## Architecture

```
Loadout/
├─ Package.swift
├─ Sources/
│  ├─ LoadoutCore/          UI-free library, testable
│  │  ├─ Model.swift        Item, Kind, Origin, Scope
│  │  ├─ Paths.swift        configurable root, zero fixed paths
│  │  ├─ Frontmatter.swift  minimal, tolerant YAML parser
│  │  ├─ InventoryScanner.swift  scans skills, commands, agents, plugins, MCP
│  │  ├─ Projects.swift     reads INDEX.md
│  │  ├─ Mutations.swift    enable, disable, save, create, delete
│  │  ├─ Backups.swift      snapshots
│  │  ├─ UsageIndex.swift   incremental SQLite over the transcripts
│  │  ├─ ChatRunner.swift   runs the assistant, reporting what it says as it says it
│  │  └─ Watcher.swift      FSEvents with coalescing
│  └─ LoadoutApp/           SwiftUI
└─ Tests/LoadoutCoreTests/
```

`Paths` takes its root by injection. That is what allows everything to be tested against a temporary folder (AC9.2) and is the reason there are no hardcoded paths (AC9.5).

## Out of scope

Hooks, permissions and the rest of `settings.json`. Session history. Syncing between machines. Distribution through the Mac App Store.
