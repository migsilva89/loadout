---
title: Enabling and disabling a skill, across assistants
version: 1.0
date_created: 2026-08-15
last_updated: 2026-08-15
owner: Miguel Silva (Loadout)
tags: [flow, skills, multi-assistant, app, macos, swift]
---

# Introduction

Loadout lists skills from every assistant on the machine — `~/.claude/skills`, `~/.codex/skills`, and
the shared store `~/.agents/skills` — and merges a skill that several assistants load into a single
row. The switch on that row, however, was written when Claude was the only assistant: disabling always
moves the folder into `~/.claude/skills-off`, and enabling always moves it back into `~/.claude/skills`.

The consequence is a silent change of ownership. A skill that lived only in Codex, switched off and on
again, comes back as a Claude skill and disappears from Codex. Nothing warns, nothing is lost on disk,
and the user has no way to undo it from the app.

This document defines what the switch should mean when more than one assistant is in play, what
happens on the way back, and where the folder lives while it is off.

## 1. Settled decisions

Decided 2026-08-15, in session:

- **D1 — Off means off everywhere.** The switch has two positions and one meaning: this skill is out of
  service. Disabling never asks which assistants to drop; it drops all of them. Taking a skill out of
  one assistant while leaving it in another is a different gesture, and it already exists: the assistant
  dots on the row (share / unshare).
- **D2 — Enabling asks where.** Coming back is a choice, not an undo. The app presents the assistants
  it can write to, pre-ticked with the set the skill was loaded by when it was switched off, and the
  user confirms or changes it.
- **D3 — The folder stays with its owner.** A Codex skill parks in `~/.codex/skills-off`, a Claude skill
  in `~/.claude/skills-off`, a shared skill in `~/.agents/skills-off`. A disabled skill never changes
  hands.
- **D4 — Plugin skills get their own switch too.** A plugin that ships 30 skills should not force all 30
  on the user. Loadout disables one skill inside the plugin's active version and keeps its own list of
  what it turned off, so a plugin update does not silently undo the choice. Reviewed with a colleague
  the same day: a skill reappearing after an update is an acceptable worst case, an all-or-nothing
  plugin switch is not.

## 2. Definitions

- **Owner root** — the assistant root (or `~/.agents/skills`) that holds the real folder, as opposed to
  a symlink pointing at it. A skill has exactly one; `promoteToShared` already refuses the ambiguous
  case of two real copies.
- **Loaded-by set** — the assistants whose skills root contains the skill, real folder or symlink. This
  is what the dots on the row show.
- **Off-record** — Loadout's own note of what a skill looked like the moment it was switched off.

## 3. The flow

### 3.1 Disabling

1. The user flips the switch off on a personal skill (own folder, not a plugin's).
2. The app resolves the owner root and the loaded-by set.
3. It takes a backup snapshot, as every mutation already does.
4. It removes the symlink from every assistant that is not the owner.
5. It moves the real folder from the owner root into `<owner>/skills-off/<name>`, whole.
6. It writes an off-record: skill name, owner root, loaded-by set, timestamp.
7. The row stays in place, dimmed, switch off. No dialog was shown at any point.

### 3.2 Enabling

1. The user flips the switch on.
2. A sheet opens: one line per assistant that can hold skills, each with a checkbox, pre-ticked from
   the off-record. The owner is ticked and cannot be unticked — something has to hold the real folder.
3. On confirm, the folder moves from `<owner>/skills-off/<name>` back into the owner root.
4. If more than one assistant is ticked, the skill is promoted to `~/.agents/skills` and each ticked
   assistant gets a symlink, which is the existing sharing path — the enable flow does not invent a
   second mechanism.
5. The off-record is deleted.
6. If no off-record exists (moved by hand, lost support folder), the sheet opens with only the folder's
   current owner ticked, and says in one line that it could not tell where the skill used to load.

### 3.3 What is refused

- A destination that already exists: the operation fails, explains, and destroys nothing. This is the
  existing rule and it stands.
- A skill whose real folder cannot be identified, or that has real copies in two assistants: refused
  with the message `promoteToShared` already gives, rather than guessing which copy is current.

## 4. The off-record

Stored in Loadout's own support directory — `~/Library/Application Support/Loadout/skills-off.json` —
and never inside the skill folder: a stray file there would show up in the user's own git repository
and travel with a skill that is shared or published.

```json
{
  "version": 1,
  "entries": [
    {
      "name": "brain-box",
      "owner": "claude",
      "assistants": ["claude", "codex"],
      "disabledAt": "2026-08-15T10:04:00Z"
    }
  ]
}
```

`owner` is an assistant id, or `shared` for `~/.agents/skills`. A missing or unreadable file is not an
error: it degrades to the behaviour in 3.2 step 6.

## 4b. Plugin skills

### 4b.1 The flow

1. Every plugin skill gets a switch of its own, in the Skills list, next to the name — the same control
   the user's own skills have.
2. Disabling moves the skill folder out of the plugin's active version, from
   `<cache>/<marketplace>/<plugin>/<version>/skills/<name>` into `<version>/skills-off/<name>`. Claude
   Code reads `skills/` only, so the skill stops loading and nothing is deleted.
3. Loadout records the choice by name, not by version: `tgc-core@tgc → [tgc-interview-report, …]`.
4. On every scan, for each plugin in that record, any listed skill found back in the active version's
   `skills/` is moved off again. This is what survives a plugin update: version 0.8.3 arrives as a clean
   copy from the plugin's repository, and Loadout re-applies the list to it.
5. Enabling moves the folder back and drops the name from the list.
6. Where the record and the disk disagree and the folder cannot be found — the plugin dropped that skill
   upstream, or it was renamed — the entry is left in place and nothing is invented.

The residual risk is accepted, not hidden: if the re-apply fails, the worst case is a skill coming back
enabled after an update. Reviewed with a colleague on 2026-08-15, who put it plainly — an update is a
moment where you would want to look again anyway. An all-or-nothing plugin switch is the worse trade.

### 4b.2 The record

`~/Library/Application Support/Loadout/plugin-skills-off.json`, alongside the off-record of section 4:

```json
{
  "version": 1,
  "plugins": {
    "tgc-core@tgc": ["tgc-interview-report", "tgc-presentation"]
  }
}
```

### 4b.3 Where it is seen and done

- **In the Skills list**, a plugin skill carries a small coloured tag naming the plugin it came from —
  `tgc-core-plugin` — next to the skill name. The `-plugin` suffix is part of the tag: the bare name
  reads like a namespace rather than a source (decided at the screen, 2026-08-15). It says where the skill came from without opening the detail, and without
  loading the row with a colour code that has to be learnt: dimming already means disabled, and the
  selected row already has its own colour.
- **In the Plugins tab**, selecting a plugin now fills the detail pane, which today says "Select an
  item". It shows the plugin, its version, and the items it ships — the 7 of `tgc-core` — each with its
  own switch, so a plugin can be trimmed from the plugin's own side.
- Both are the same switch over the same record. The two views can never show different states, and the
  plugin's own switch keeps its current meaning: the whole plugin in or out of the house.

## 5. Acceptance criteria

These replace **AC3.1** and **AC3.2** in `docs/SPEC.md` and add to that section. `[T]` means covered by
an automated test; `[M]` means verified in the running app.

- **AC3.1** `[T]` Disabling a personal skill moves its real folder into `<owner root>/skills-off/<name>`,
  with all its content intact, where the owner root is the assistant that held the real folder — never
  `~/.claude` for a skill that was not Claude's.
- **AC3.2** `[T]` Disabling a skill that several assistants load removes the symlink from every
  non-owner assistant, and asks nothing.
- **AC3.3** `[T]` Disabling writes an off-record naming the owner and the loaded-by set as they were.
- **AC3.4** `[T]` If the destination in `skills-off` already exists, nothing moves, nothing is deleted,
  and the error names the path.
- **AC3.5** `[M]` Enabling opens a sheet listing every assistant with a skills root, pre-ticked from the
  off-record, with the owner ticked and locked.
- **AC3.6** `[T]` Confirming with one assistant ticked moves the folder back to that assistant's skills
  root and leaves no symlinks behind.
- **AC3.7** `[T]` Confirming with several ticked leaves the real folder in `~/.agents/skills` and a
  symlink in each ticked assistant — the same shape `share` produces.
- **AC3.8** `[T]` A successful enable deletes the off-record; a failed one leaves it untouched.
- **AC3.9** `[T]` With no off-record, enabling still works: the sheet opens with the current owner
  ticked alone, and the app says it could not tell where the skill used to load.
- **AC3.10** `[T]` A round trip — disable then enable, confirming what the sheet proposes — leaves the
  disk exactly as it was before the disable, symlinks included.
- **AC3.11** `[M]` The row reflects the disk immediately after either operation: dots, dimming, switch.

- **AC3.12** `[T]` Disabling a plugin skill moves its folder into `skills-off` inside the plugin's active
  version, and records it under `<plugin>@<marketplace>` by name.
- **AC3.13** `[T]` After a plugin update, a recorded skill present again in the new version's `skills/`
  is moved off on the next scan, without asking.
- **AC3.14** `[T]` Enabling a plugin skill moves it back and removes the name from the record.
- **AC3.15** `[T]` A recorded skill the plugin no longer ships leaves the record untouched and causes no
  error.
- **AC3.16** `[M]` A plugin skill's row carries a coloured tag with the plugin's name.
- **AC3.17** `[M]` Selecting a plugin in the Plugins tab shows its detail: version, origin, and the items
  it ships, each with a working switch. The state there matches the Skills list at all times.
- **AC3.18** `[T]` The plugin's own switch keeps writing `enabledPlugins["<plugin>@<mkt>"]` in
  `settings.local.json`, preserving the rest of the file — unchanged from AC3.4 of the current spec.

`docs/SPEC.md` **AC3.5**, which states that plugin skills cannot be disabled individually, is deleted:
this document reverses it.

## 4c. Project skills

Skills in `<repo>/.claude/skills` get the same switch as personal ones, and park next door in
`<repo>/.claude/skills-off`.

The reason to hesitate was that the folder lives inside a working repository: moving it shows up in
`git status`, mixed in with whatever the user was actually working on, and could be pushed without
noticing — disabling the skill for the whole team. That cost does not go away by parking the folder
outside the repository, because git reports the disappearance either way. Given that, next door is the
better place: it travels with the project, and reads as a deliberate state rather than a deletion.

Loadout itself runs no git commands and knows nothing about version control. It moves a folder; git is
what notices.

- **AC3.19** `[T]` Disabling a project skill moves it to `<repo>/.claude/skills-off/<name>`, and
  enabling moves it back. The assistant sheet of section 3.2 does not appear — a project skill belongs
  to its repository, not to an assistant.
- **AC3.20** `[M]` The first time a project skill is disabled, the app says in one line that the change
  will show up in the repository, with a "don't tell me again" box. It warns once, not every time.

## 6. Still open

- **Q3 — Nested frontmatter.** Loadout's frontmatter reader is flat: `[String: String]`, one level. The
  Vercel plugin's skills carry nested YAML — `metadata.promptSignals`, a `validate` list of several
  rules — and the preview renders inner keys as if they were top-level, with later rules overwriting
  earlier ones. What is on screen is wrong while looking right. Decided in principle on 2026-08-15 that
  the app must read it properly rather than hide it; the shape of the fix is not specified here.
