<p align="center">
  <img src="Resources/logo-light.png#gh-light-mode-only" width="280" alt="Loadout"><img src="Resources/logo-dark.png#gh-dark-mode-only" width="280" alt="Loadout">
</p>

<h1 align="center">Loadout</h1>

<p align="center">
  <strong>See and manage what your coding assistants load.</strong><br><br>
  Skills, slash commands, subagents, plugins and MCP servers, from every assistant<br>
  on the machine — with how often each one actually fires, and an editor for the ones you own.
</p>

<p align="center">
  <a href="https://loadout.migsilva.dev"><strong>loadout.migsilva.dev</strong></a> — what it does, guides and download
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-blue?style=flat-square" alt="macOS 15 or later">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" alt="MIT license">
  <a href="../../releases/latest">
    <img src="https://img.shields.io/github/v/release/migsilva89/loadout?style=flat-square" alt="Latest release">
  </a>
  <a href="https://buymeacoffee.com/migsilva?utm_source=github-loadout">
    <img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-%E2%98%95-FFDD00?style=flat-square" alt="Buy me a coffee">
  </a>
</p>

## Features

- **A full inventory** — personal and project skills, everything from plugins, slash commands, subagents and MCP servers, across every assistant on the machine — Claude Code, Codex and Antigravity MCP servers side by side, each marked with its owner
- **Real usage** — how many times each thing fired, when it last did, and in how many projects, read from the assistants' own session logs
- **Honest counts** — a history format that cannot prove an activation is marked unsupported, rather than reporting a zero that looks like disuse
- **Project scope** — answers "what does an assistant see if I open this folder?" — and an Everything list that puts yours and every project's side by side, each row saying where it lives, for when the question is "where did I put that one?"
- **A switch on everything** — turn one skill, command, subagent or MCP server off without deleting it, including a single skill out of a 38-item plugin, and Loadout re-applies that choice when the plugin updates
- **Codex plugins** — installed plugins and their skills appear alongside Claude's, with separate controls. Turning off a plugin shows all its skills as off; turning it back on restores your individual choices. Codex's local plugin controls require an installed Codex version that supports its plugin inventory protocol. Workspace-managed plugin switches stay in Codex.
- **An editor** — create skills, commands and subagents, edit and delete them, with syntax highlighting and live validation against the documented limits
- **A conversation, beside the editor** — ask `claude`, `codex`, `opencode` or `agy` to change a skill; it proposes, you accept change by change
- **Out of a repository, into your own** — a skill, command or subagent that lives in a project becomes yours everywhere with one click. It is a copy: the project keeps its own, so nobody else loses anything at their next pull
- **Help where the question is** — Settings › Help says in plain words what switching something off does to your files, where Loadout keeps its own, and reports a bug with the version and system already filled in
- **A backup before every write** — if the copy fails, nothing is written. Deleting goes to the Trash, never `rm`
- **One skill, every assistant** — share a skill across assistants as symlinks to a single copy, so one edit reaches all of them. Switching it off asks which assistants it should return to, and a skill never changes hands behind your back

<p align="center">
  <img src=".github/assets/loadout-all.gif" width="1000" alt="Browsing the inventory, disabling and re-enabling a skill, switching off one skill out of a plugin, putting a skill on a second assistant, then asking an assistant to rewrite its description and accepting the change inside the document">
</p>

## Install

```bash
brew install --cask migsilva89/loadout/loadout
```

Or download the [latest release](../../releases/latest) — the [website](https://loadout.migsilva.dev)
points at the same file — and drag `Loadout.app` into `/Applications`. The disk image is signed and
notarised, so it opens without a Gatekeeper warning and without a trip through System Settings.

macOS 15 or later, on Apple silicon or Intel.

Or build it yourself, which needs Xcode:

```bash
git clone https://github.com/migsilva89/loadout.git
cd loadout
./Scripts/build-app.sh
open dist/Loadout.app
```

## Chat about your setup

Open **Chat** beside **New skill** from any tab. It uses an assistant CLI already installed and
its existing subscription — there is no API key. Choose the assistant and model in the chat panel.

Press **Ask** on a skill to attach it to the current conversation. You can attach several skills
and remove them above the message box. Selecting another row does not change the attachments or
switch conversations. Removing an attachment excludes its files from future messages; earlier
messages stay in the conversation. **New** starts a chat with no attachments, and **History**
includes earlier conversations, including those started before global chat.

The assistant runs in disposable copies of the attached folders. Review each proposed change
in the chat panel with **Accept** or **Reject**, then choose **Save accepted changes**. Only accepted
changes reach their original files, with a backup first. If a file changed elsewhere, review the
updated proposal before saving. Plugin files remain read-only references.

In the **New skill** sheet, **Create and ask** makes the skeleton and hands it to an assistant with
what you typed as the brief, so the description and body come back as proposals.

## Sharing a skill across assistants

Each assistant reads its skills from `~/.<name>/skills` — `~/.claude/skills`, `~/.codex/skills`,
and so on. Loadout finds them by itself: any such folder that exists is included, and an assistant
installed tomorrow shows up without a code change. Antigravity CLI (`agy`) is the exception it
knows about: it has no folder of its own and reads `~/.gemini/config/skills`, so that is where
Loadout puts its skills.

Clicking an assistant that does not have the skill puts it there. On disk, the folder is promoted
to `~/.agents/skills/<name>` and each assistant gets a symlink to it — one copy, one edit, both
sides always the same. Clicking a lit mark removes only that link, never the one real copy. The
Loadout menu has **Sync all with …** to close the gaps at once.

If two assistants have their own, possibly different, copies of the same skill, the app refuses to
merge them on its own and says why.

## What it touches

| Data | Location | Written by Loadout? |
|---|---|:---:|
| Your skills, commands, subagents and MCP servers | `~/.claude/`, `~/.codex/`, `~/.gemini/config/`, `~/.<assistant>/` | Only when you save, create, delete or share |
| Backups, taken before every write | `~/Library/Application Support/Loadout/backups/` | Yes |
| Usage index, rebuildable | `~/Library/Application Support/Loadout/usage.sqlite` | Yes |
| Working copies for the assistant conversation | `~/Library/Application Support/Loadout/ask-workspaces/` | Yes |
| The assistants' session logs | `~/.claude/projects/`, `~/.codex/sessions/`, `~/.gemini/antigravity-cli/conversations/` | Never — read only |

Loadout keeps its own files out of `~/.claude`: that directory belongs to Claude, and an app that
keeps its database in someone else's folder is a surprise waiting for whoever wipes `.claude` to
fix something.

The app itself makes no network calls. The assistant CLI it runs on your behalf talks to its own
provider, with the credentials already on your machine; Loadout never sees them.

The test suite never touches any of this: every test runs against a temporary tree, which is why
`Paths` takes its root by injection.

Codex plugin discovery and configuration edits use its local app-server protocol. Loadout does not
start an AI conversation for these operations. To check this integration with an installed Codex,
run `.build/debug/LoadoutApp --self-check-codex` after building. It creates a temporary marketplace
and tests individual switches, parent restoration, updates, backups and configuration preservation.

## Security

See [SECURITY.md](SECURITY.md). The areas that matter here: writes outside the expected
directories, command execution driven by file contents, and any path where a backup fails without
stopping the write.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the scope, how to run the tests, and what a pull
request needs. A feature outside that scope will be declined however well it is written, so open
an issue first. The specification, with the acceptance criteria one by one, is in
[docs/SPEC.md](docs/SPEC.md).

## Status

A personal project, maintained when it suits. It works and is used every day, but it does not come
with a product's promise of support.

Releases are built by `./Scripts/release.sh`, which refuses to run from a dirty tree, an untagged
commit or a branch other than `main`, and runs the tests before signing anything.

Loadout updates itself. A release publishes three files together — the disk image, an identical
copy named `Loadout-<version>-update.dmg`, and a signed `appcast.xml` that points installed copies
at it. The app only accepts an update signed with the key it was built with. `release.sh` will not
print the publish command unless that signed feed exists.

## Support the project

Loadout is free and stays free. If it saves you time, you can [buy me a coffee](https://buymeacoffee.com/migsilva?utm_source=github-loadout) — it keeps the next release coming.

## License

[MIT](LICENSE).
