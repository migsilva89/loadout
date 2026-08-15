---
title: The last three — agents, MCP servers, and frontmatter Loadout could not read
version: 1.0
date_created: 2026-08-15
last_updated: 2026-08-15
owner: Miguel Silva (Loadout)
tags: [flow, agents, mcp, frontmatter, app, macos, swift]
---

# Introduction

Two days of work gave skills and commands a switch that means the same thing everywhere, and took
the lies out of what the app says about them. Three things were deliberately left for last, and
this document closes them:

- Subagents and MCP servers still have no switch. They are the two kinds you cannot turn off
  without deleting.
- The frontmatter reader is flat, so a skill with nested YAML — the Vercel plugin's, for one — is
  rendered wrong, with inner keys presented as top-level ones and later values silently replacing
  earlier ones.

Reviewed in Imark: **no** — written while Miguel was away, with the decisions taken here and
flagged for review when he is back. Everything in it is reversible and covered by tests.

## 1. Frontmatter that is more than `key: value`

### What is wrong

`Frontmatter.parse` keeps a `[String: String]`. It walks the block line by line, folds indented
continuations into the previous value, and stores the last value it saw for a key.

`vercel-functions` carries this shape:

```yaml
metadata:
  priority: 8
  pathPatterns: ['api/**/*.*', 'app/**/route.*']
  promptSignals:
    phrases: ["websocket", "long polling"]
    minScore: 6
validate:
  - pattern: export\s+default\s+function
    message: 'Use named exports…'
    severity: error
  - pattern: maxRetries…
    message: 'Manual retry logic…'
    severity: recommended
```

On screen that becomes a flat list where `severity`, `pattern` and `message` look like fields of
the skill, and hold the values of the **last** validate rule — the earlier ones are gone. Nothing
warns. It is wrong while looking right, which is the worst kind of wrong an inspector can be.

### The decision

Read the block into a tree — maps, lists and scalars — and render it as a tree. Still no YAML
dependency: the shape used by these files is indentation, `key:`, `- item`, inline `[a, b]` and
block scalars, and that is a readable amount of parsing. What the parser cannot make sense of is
reported as a warning and shown verbatim, exactly as today: the file on disk is the truth.

`name` and `description` keep working the way everything already reads them — top-level scalars —
so nothing that depends on them changes.

- **AC11.1** `[T]` A nested map is read as a nested map: `metadata.promptSignals.minScore` is 6,
  not a top-level `minScore`.
- **AC11.2** `[T]` A list of maps keeps every entry: two `validate` rules are two, with their own
  `pattern`, `message` and `severity`.
- **AC11.3** `[T]` Inline lists (`[a, b]`) and dashed lists read the same.
- **AC11.4** `[T]` `name` and `description` still read as before, including folded and quoted
  values, and a flat frontmatter produces exactly what it produced before.
- **AC11.5** `[M]` The preview shows the nesting — a child is visibly inside its parent, and a list
  entry is visibly one of several.

## 2. A switch for subagents

A subagent is a markdown file in `~/.claude/agents`, a project's `.claude/agents`, or a plugin's
`agents/`. It is the same shape as a command, so it gets the same switch and the same rules:
`agents-off` beside its own directory, a project one warning once about the repository, a plugin's
recorded by name and re-applied after an update.

Codex has no subagents of its own, so there are no dots here — the row shows the switch, and that
is all it can honestly show.

- **AC11.6** `[T]` Disabling an agent moves the file to `agents-off` beside its own directory, and
  enabling moves it back. It stays listed, marked off.
- **AC11.7** `[T]` A plugin's agent is recorded and re-applied after a plugin update, under the
  same record as its skills and commands.
- **AC11.8** `[M]` The New button offers "New agent" on the Agents tab, and creates one from a
  template with `name` and `description`.

## 3. A switch for MCP servers

### The mechanism, and why this one

An MCP server is not a file: it is an entry under `mcpServers` inside `~/.claude.json`, or inside a
project's entry in the same file. Claude Code has no "disabled" flag for a user-scope server — the
`enabledMcpjsonServers` and `disabledMcpjsonServers` settings only govern servers a repository
ships in its own `.mcp.json`.

So switching one off means taking the entry out of `mcpServers`, and switching it on means putting
it back exactly as it was. Loadout keeps the entry it removed in its own support directory, beside
the other off-records, and the snapshot rule applies as it does to every write: `~/.claude.json` is
copied before it is touched.

Two things this must never do, both of which would be worse than no switch at all:

- Change anything in `~/.claude.json` but the one entry. It is a large file holding conversation
  history pointers, onboarding flags and per-project state, and every value of it has to survive
  the round trip — numbers as numbers, unicode as unicode, slashes unescaped. What is not preserved
  is the byte layout: the file is re-serialized pretty-printed with sorted keys, so the diff is
  noisy even though the content is not. Claude Code rewrites this file constantly on its own, so a
  deterministic order is worth more here than an untouched one.
- Lose the entry. If the record cannot be written, the entry is not removed.

- **AC11.9** `[T]` Disabling an MCP server removes its entry from `mcpServers` and keeps it in
  Loadout's record; every other key in `~/.claude.json` is untouched.
- **AC11.10** `[T]` Enabling puts the entry back exactly as it was, and clears the record.
- **AC11.11** `[T]` A disabled server still appears in the list, marked off, with its command or
  URL still readable — it is off, not forgotten.
- **AC11.12** `[T]` If the record cannot be written, nothing is removed.
- **AC11.13** `[M]` A project-scope server says which project it belongs to, and switching it off
  touches only that project's entry.

## 4. What this deliberately does not do

- No switch for a plugin's MCP servers as a group: a plugin's servers are declared by the plugin
  and the plugin's own switch already governs them.
- No editing of an MCP server's command or arguments in the app. Reading it is useful; editing JSON
  by hand in a text box is how a config file gets broken at midnight.
