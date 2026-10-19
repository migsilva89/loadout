# Plugin management, subagent sharing and installed-only assistants

**Status:** implemented on a branch; Codex install/update/uninstall not yet run against a real Codex (none on the
development machine).

## Installed-only assistants

`AssistantRegistry.discover(paths:locate:)` returns every assistant with a folder, each with `isInstalled`:
its Mac app exists (`/Applications`, `~/Applications`), or one of its tools is found (`claude`, `cursor-agent`,
`agy`, `opencode`, …), or Loadout was given Codex's executable. The scanner reads all of them; `AppModel.assistants`
(what the person sees) keeps the installed ones, and `everyAssistant` (what file operations walk) keeps all.

## Subagent sharing

`Assistant.agentsRoot` exists only for assistants whose folder of markdown agents is known:
Claude (`agents`), Cursor (`agents`), Gemini (`agents`), Factory (`droids`), opencode (`agents` or `agent`).
`Mutations.shareAgent` / `unshareAgent` link one file, never overwrite, never remove the real copy.
`setCommand` on a personal command or subagent moves every assistant's copy — links first and the real file
last going off, the reverse coming back. `tools` and `model` are each assistant's own vocabulary; the status line says so.

## Plugins

| | install | update | remove |
|---|---|---|---|
| Claude Code | `claude plugin install <name@marketplace>` | `claude plugin update <id>` | `Mutations.removePlugin` (register + Trash) |
| opencode | `opencode plugin add <pkg>` | `opencode plugin update <spec>` | `opencode plugin remove <spec>`; a local script goes to the Trash |
| Codex | app-server `plugin/install` | `plugin/install` again | app-server `plugin/uninstall` |

Every run snapshots the files the tool may change first; if the snapshot fails nothing runs. Arguments are an
argv list, validated so typed text cannot be read as an option. Claude's catalogue is `claude plugin list
--available --json`; Codex's is `plugin/installed`. opencode has none. opencode has no enable switch.

**Unverified:** the Codex method names and the `marketplacePath` parameter follow Codex's app-server protocol as
remembered, not as exercised. Extend `--self-check-codex` before relying on them.
