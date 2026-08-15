---
title: Commands, brought up to what skills already do
version: 1.0
date_created: 2026-08-15
last_updated: 2026-08-15
owner: Miguel Silva (Loadout)
tags: [flow, commands, multi-assistant, app, macos, swift]
---

# Introduction

Loadout's Commands tab lists slash commands — one markdown file each — from `~/.claude/commands`,
from a project's `.claude/commands`, and from installed plugins. It shows what they say, how often
they were used, and lets the user edit, save, reveal and delete them.

Everything else the app learned to do for skills, it has not learned here. A command cannot be
switched off without deleting it. A new one cannot be created. Only Claude's half of the machine is
read, while skills are read across every assistant. And a warning written for skills fires on every
command, saying something untrue.

This document covers those four, in the order a user meets them.

## 1. The warning that is always wrong

Every command shows an amber banner: *"The frontmatter is missing the name field."*

A command does not have a `name` field and does not need one. Claude Code names it after the file:
`adversarial-review.md` is `/adversarial-review`. The frontmatter it does carry is a different
vocabulary — `description`, `allowed-tools`, `argument-hint`, `disable-model-invocation`.

The banner fires because the frontmatter parser applies the skill rules to anything with a
frontmatter block, and the scanner only suppresses it when the block is empty. The result is a
warning on all 29 commands at once, which warns of nothing and teaches the user to ignore the amber
colour everywhere else in the app.

The same mistake shows in the token budget card, where a "Name 0 / 64 chars" bar measures a field
that does not exist here.

- **AC10.1** `[T]` A command with valid frontmatter and no `name` produces no warning.
- **AC10.2** `[T]` A command whose frontmatter is genuinely broken — an unclosed block, a line
  without a colon — still warns, and still lists.
- **AC10.3** `[M]` The budget card for a command does not show a `Name` row.

## 2. Where a command came from

The detail pane says *"Command from codex"* for a command that ships with the `codex` plugin. Read
plainly, that says the Codex assistant — which is wrong twice over: it comes from a Claude Code
plugin, and that particular command's whole job is to send work to Codex from inside Claude.

Commands take the same treatment skills got on 2026-08-15: a tag on the row naming the plugin,
`codex-plugin`, and a detail line that says plugin rather than leaving the name bare.

- **AC10.4** `[M]` A command from a plugin carries the same `<plugin>-plugin` tag as a skill does,
  and its detail names the plugin as a plugin.

## 3. Switching a command off

A command has no switch at all. The only way to stop one loading is to delete it, which is a
different decision — and the Trash is not where you put something you might want back on Thursday.

The mechanics are the ones skills already use, one step smaller because a command is a file rather
than a folder: it moves to `commands-off` beside its `commands` directory. `~/.claude/commands-off`
for a personal one, `<repo>/.claude/commands-off` for a project one, `commands-off` inside the
installed version for a plugin's, with the same record and the same re-apply after a plugin update
as `spec/spec-flow-enable-disable-skills.md` defines for plugin skills.

Two things stay as they are. A command belongs to one assistant's directory rather than to a shared
store, so switching one back on does not open the assistant sheet — there is nothing to choose.
And a project command warns once about the repository, exactly as a project skill does.

- **AC10.5** `[T]` Disabling a command moves the file to `commands-off` beside its own `commands`
  directory, whichever origin it has, and enabling moves it back.
- **AC10.6** `[T]` A disabled command still appears in the list, marked off.
- **AC10.7** `[T]` A plugin's disabled commands are recorded by name and re-applied after an update,
  under the same record as plugin skills.
- **AC10.8** `[M]` Enabling a command asks nothing; disabling a project command warns once.

## 4. Creating one

The only creation button in the app says "New skill". A command has to be made by hand in the
Finder, which is the one part of this the app was written to avoid.

New command creates `~/.claude/commands/<name>.md` — or the project's, in a project scope — from a
template carrying `description` and `argument-hint`, with the name validated the way a skill's is
and nothing ever overwritten. The button reads "New" and offers what the current tab can make.

- **AC10.9** `[T]` Creating a command writes `<name>.md` with a valid template, refuses an invalid
  name, and never overwrites an existing file.
- **AC10.10** `[M]` The button offers "New command" while the Commands tab is showing.

## 5. The other assistants

Skills are read from every assistant on the machine and merged into one row, with dots showing who
loads what — seeing the gap is the point. Commands are read from Claude only, so a tab that says 29
is quietly claiming to be the whole picture.

Codex keeps its own in `~/.codex/prompts`, as markdown files, named after the file in the same way.
Loadout reads them, merges by name, and shows the dots.

Sharing one across assistants is offered, and says what it costs. A command's frontmatter is Claude
Code's vocabulary: `allowed-tools` and `disable-model-invocation` mean nothing to Codex and sit
there as dead text. Some commands are worse than untranslatable — `adversarial-review` exists to
call Codex from inside Claude, and has no meaning on the other side. So the app never shares
silently as if the two were the same thing: filling a gap says, in one line, that the frontmatter
does not travel.

- **AC10.11** `[T]` Commands in `~/.codex/prompts` are inventoried, merged by name with Claude's,
  and each row carries the assistants that have it.
- **AC10.12** `[M]` Filling a gap from the dots explains in one line that Claude-only frontmatter
  does not carry over, before doing it.
- **AC10.13** `[T]` An assistant with no prompts directory is not an error: the tab works with
  whatever exists.

## 6. Out of scope here

- Namespaced commands in subdirectories (`commands/foo/bar.md` → `/foo:bar`). Neither the machine
  nor the plugins installed on it use one today, and inventing support for a shape nobody has is how
  a scanner grows code with no reader.
- Any per-command control in Claude Code's settings file. There is none; moving the file is the
  mechanism, as it is for skills.
