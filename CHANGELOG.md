# Changelog

Notable changes, newest first. Dates are the day the work landed on `main`.

The versions are what a release is tagged as; between tags, `main` is what is being used daily.

## 0.3.2 — 2026-08-28

### Fixed

- **Ask reaches the Codex CLI again.** An app opened from the Finder inherits a bare `PATH` with no
  `node` in it, so the `codex` script installed by nvm died before it started. The launched
  executable's own directory now leads the child's `PATH`, `codex exec` is told not to insist on a
  git repository — a skill folder is not one — and its input is closed rather than left waiting.
- **A skill kept in two places is listed once.** One sitting both in a live skills folder and in
  the same assistant's disabled folder was drawn twice under the same identity: one row appeared,
  a hole the size of the other was left beside it, and the count at the top was wrong. The live
  copy wins.
- **The app no longer offers a removal it would refuse.** Taking an item out of the only assistant
  that has it would delete it, so the click raised an error afterwards. That assistant's remove
  action is now dimmed and says why when you point at it; the check stays, because the item is
  still there.
- **An offline app stops claiming to be up to date.** The update check could not tell "you have the
  latest" from "I could not ask", and said the first for both.

### Added

- **Settings › Updates.** The version you are running, a switch for the check, and a button to ask
  now with the answer on the page. The check at launch happens at most once a day, and a failed
  check does not count against that.

## 0.3.1 — 2026-08-25

### Fixed

- **Settings › Assistants shows your assistants again.** The sidebar counted them and the page
  beside it was blank, so the one screen where an assistant is switched on or off, and where the
  CLI behind "Ask" is set, could not be used at all. It was the last section still drawn as a list
  asking for unlimited height inside a scrolling page, which renders nothing; it is now built like
  every other section. Adding a CLI of your own is the last row of that card.

## 0.3.0 — 2026-08-18

### Added

- **The fact cards fold, so the document gets the room.** Token budget, Details and Assistants sat
  above the markdown, and on a 1000pt window the thing you opened the pane to read started in the
  bottom third. They fold into one strip that still carries every number they were showing — where
  it comes from, its uses and projects, the description's tokens, the body's lines — with the marks
  of the assistants that load it at the end. Hiding them outright would have taken away the figures
  the pane gets opened for; the strip keeps them and is also the way back. Fold it from the chip
  beside the name, from the seam between the cards and the document, or with ⌥⌘I. The choice is one
  for the whole app and it is remembered: per skill, the pane would change height as you moved down
  the list.
- **A plugin's page says what the plugin is, and a plugin can be removed.** It used to be a name, a
  version and a list of what it ships — nothing about where those files live, and no way to take one
  out. It now names the marketplace that installed it, counts what it brings, shows the folder it
  occupies with a Reveal beside it, and offers Remove plugin. Removing takes the entry out of Claude
  Code's register, your on/off answer out of your settings, and the folder to the Trash, with a copy
  of each in the backups first. The marketplace stays, because one marketplace serves many plugins
  and it is what `/plugin` needs to install this one again. A session already running keeps the
  plugin loaded until it restarts, and the dialog says so.

### Changed

- **Making something global says what it did.** Copying a skill, command or subagent out of a
  repository happened behind one click: nothing said before, nothing said after, the button still
  offering the copy it had just taken, and a second click failing with "already exists". It now asks
  first — you are about to have two of these, and yours stops following the repository's — and the
  same dialog then reports where the copy landed, path and all. Once your copy exists the offer goes
  from the callout and from the row's menu.

### Fixed

- **The window can photograph itself for one frame.** The recorder that writes the README's
  animation now exposes a single capture, which is what let the folding cards be checked by looking
  at the two states rather than by trusting a number.

## 0.2.0 — 2026-08-17

### Added

- **The servers a repository ships are visible at last.** A team shares MCP servers by committing a
  `.mcp.json`, and Loadout read only your own `~/.claude.json` — so a repository could hand Claude
  three servers and the app showed none of them. They now appear in that project's list, saying they
  were shipped by the repository and pointing at the file that declares them. One that you have not
  answered for yet reads as off, because Claude Code asks before it loads them and loads none until
  you say yes; switching it on here is that yes.
- **Switching one of them off never touches the team's file.** Cutting a line out of a committed
  file would take the server away from everybody at their next pull. The refusal goes where Claude
  Code already keeps it — in your own settings, under that project — so the repository is unchanged
  for everyone else.
- **A plugin a repository decides about says so.** A repository's own settings are read after yours,
  which means they win. The row now reads `off in <project>` with the reason above it, and the switch
  is disabled instead of appearing to work: your settings cannot overrule that file while you are
  working there.
- **Remove, for MCP servers of your own.** They were the one thing that could be switched off but
  never deleted. The wording says what really happens — a few lines out of the assistant's settings,
  with no Trash to take them back from — and the file is copied to the backups first.
- **Where your projects live is now a question the app asks.** Settings › Projects holds the folders
  Loadout looks in, and a first-run sheet states what was already found before asking for anything.
  It replaces a generated file one person kept by hand, which everybody else opened the app without.
- **Tooltips on the things that carry meaning.** Above all the numbers: what the count counts, which
  assistants it includes, which window of time, and — where it applies — that a zero is a history
  format that cannot prove an activation rather than disuse.

### Changed

- **The list opens compact.** At 83 skills the descriptions are what make the column a wall.
- **A row says where it comes from when the scope does not.** Global holds your own things, except
  MCP servers, which the assistant also files under project directories — so two servers called
  `notion` from two repositories were two identical rows.
- **Servers no longer pretend to be documents.** Gone from a server's pane: the token budget card,
  the line-count chip and the Edit tab, all of which measured or offered something that does not
  exist there.

### Fixed

- **Housekeeping could delete the only copy of a switched-off server.** A server switched off has
  its entry lifted out of `~/.claude.json`, so Loadout's record is the whole of what is left of it.
  The launch sweep asked which records "no longer appear anywhere" — a question that could only fire
  when that file was unreadable, and then fired for every one of them at once. It now asks the
  opposite and safe question, and an unreadable file is treated as unknown rather than as permission.
- **Escape over a sheet closed Settings behind it.** The guard asked the key window for its attached
  sheet, but while a sheet is up the sheet *is* the key window, so the key never reached it.
- **A folder chosen twice was listed twice** in the first-run sheet, because the file panel returns a
  trailing slash and raw path equality counts that as a different folder.
- **Counting repositories no longer walks the disk on the main thread**, which it did on every redraw
  and every tick of a checkbox.
- **A run pointed at a fixture home cannot overwrite your real project folders.** It read them from
  the environment and still saved to the account's preferences.
- **The window of time is the one you chose.** Rows and details said "the last 90 days" regardless of
  the setting, and "Never used" claimed more than counts over a window can.
- **One confirmation, not three alerts.** Two destructive questions were two `.alert` modifiers on
  one view, which SwiftUI does not promise: an empty alert panel presented itself at launch.
- **The frosted pause no longer fades at its own edges.** The blur was cropped but never clamped, so
  it sampled transparency past the border — the seam the crop was there to prevent.

## 0.1.2 — 2026-08-16

### Fixed

- **A crowded folder no longer squeezes the document.** The Files row in Details tried to print
  every name on one line and cut whatever did not fit down the middle, so a skill whose folder
  holds a dozen others showed `remotion-int…on-multimedia/` — half a name, which tells you
  nothing — and grew the card downwards until the document below ran out of room. It now states
  the size, `13 items · 12 folders`, and opens on a click into one chip per entry that wraps onto
  the next line instead of being cut. Shut by default, so the card's height no longer depends on
  what happens to be in the folder.
- **The way to the Finder says what it does.** The button beside Location was a bare folder glyph
  at the far edge of the row, which is not something an eye finds. It says **Reveal** now, like
  every other action in that card.

## 0.1.1 — 2026-08-16

### Added

- **It tells you when there's a new version.** Loadout is handed out as a disk image, so until now
  nothing reached you after you downloaded it — a fix could ship and you would never hear about it.
  It now checks once on launch, and speaks only when there is a newer version, mentioning any one
  version once rather than every morning. There is a **Check for Updates…** in the Loadout menu for
  when you want to ask. It never replaces the app behind your back: it names the new version and
  opens its page, and you drag it across yourself.

### Fixed

- **Asking Codex no longer fails with "env: node: No such file or directory".** An app opened from
  the Finder inherits almost no `PATH`, however full yours is in a terminal. Codex is a script that
  asks for `node` on its first line, so Loadout found Codex and then couldn't run it. Claude Code
  never showed this, being a program that needs nothing else to start it — which is why one worked
  and one didn't. Assistants are now run with a `PATH` that includes their own folder, where the
  thing that runs them sits.

## 0.1.0 — 2026-08-15

The first public build: signed, notarised, and openable on a Mac that is not this one.

### Added

- **A switch on everything.** Every kind Loadout lists can be turned off without being deleted:
  skills, slash commands, subagents and MCP servers. A skill or a command moves to a `-off`
  directory beside its own; a subagent likewise; an MCP server's entry is lifted out of
  `~/.claude.json` and kept, so it can be put back exactly as it was.
- **One skill out of a plugin.** A plugin that ships 38 things no longer forces all 38: each skill
  and command has its own switch, and Loadout re-applies your choices when the plugin updates —
  otherwise a new version would silently switch everything back on. Selecting a plugin now fills the
  detail pane with what it ships, each item switchable from there.
- **Commands and subagents made in the app.** The New button follows the tab, and writes the right
  shape: a command is named after its file and gets no `name` field, a subagent gets one.
- **Everything.** A third position on the scope button, beside Global and the projects: your own,
  every project's and the plugins' in one list, each row tagged `global` or with the repository it
  lives in. It says on screen what it is — a place to find something, not a picture of what is
  loaded, because no assistant ever holds more than one project at a time.
- **Make global.** A skill, command or subagent that lives inside a repository can be copied into
  your own, so it works in every project. A copy and never a move: what is in a repository belongs
  to whoever works there, and moving it out would take it from them at their next pull. It refuses
  rather than overwrite one you already have. The other direction is deliberately absent — putting a
  skill into a repository hands it to a team, which is a decision to make on purpose.
- **Settings › Help.** What switching something off actually does to your files, where Loadout
  keeps its own, and a Report a bug button that opens the issue with the version, the system and
  the size of the inventory already filled in — shown on screen first, so nothing is sent unread.
- **Codex's slash commands.** They live in `~/.codex/prompts`, and are merged by name with Claude's,
  with the dots showing who loads what. Handing one to the other assistant says, in a line, that
  Claude-only frontmatter does not travel.

- **A conversation beside the editor.** The Ask button opens a chat with `claude`, `codex` or
  `opencode`: the reply appears as it is written, and picks up where it left off when you come
  back tomorrow. One conversation per skill, remembered by the assistant's own session id — so
  there is no second copy of it here to drift.
- **Changes you accept one at a time, in the document itself.** The assistant works in a
  disposable copy of the skill's folder, never in `~/.claude`. Loadout compares the two and opens
  each change up inside the document — the old lines struck through above the new — with Accept
  and Reject beside it. Your file changes when you save, with the same mandatory backup as any
  other write.
- **Files beside the document.** A skill is a folder, so a change to a script next to `SKILL.md`
  is listed rather than hidden. The ones you accept are written by the same Save.
- **History.** The earlier conversations about a skill are a click away, by the day and the first
  thing asked. Starting a new one files the old one instead of destroying it.
- **`Create and ask` in the New skill sheet.** Makes the skeleton, then hands it to an assistant
  with what you typed as the brief, so the description and body come back as proposals.

### Changed

- The Ask feature no longer promises to write nothing: it now proposes, and you decide. What has
  not changed is that nothing reaches a file without that decision (spec AC7).
- Loadout's own files — backups, the usage index, the assistant icons — moved out of `~/.claude`
  into `~/Library/Application Support/Loadout/`. A directory belonging to Claude is no place for
  another app's database, above all for whoever wipes `.claude` to fix something. The move runs
  once, at launch, and says so in the footer.
- Five colour themes, none of them the system's.

### Fixed

- **Disabling a skill changed its owner.** It always parked in `~/.claude/skills-off` and always
  came back to `~/.claude/skills`, so a Codex-only skill switched off and on again became a Claude
  skill and vanished from Codex. It now parks beside its owner, and switching it on asks which
  assistants it should return to, ticked from what was loading it before.
- **A warning that was always wrong.** Every slash command carried "the frontmatter is missing the
  name field" for a field a command does not have — and the budget card measured that missing name
  at 0/64. Only what makes a block unreadable is reported now.
- **Nested frontmatter was read flat.** A skill with `metadata:` and a list of `validate` rules —
  the Vercel plugin's, for one — showed inner keys as fields of the skill, with each rule's values
  overwriting the one before. It is read and shown as the tree it is.
- **Details that belonged to someone else.** A subagent listed its neighbours in the same folder
  as its own files, and an MCP server pointed at the home directory instead of the
  `~/.claude.json` it lives inside.
- A shared skill's folder is a symlink into `~/.agents/skills`; copying it copied the link, which
  from its new home pointed at nothing and left the assistant with no working directory.
- A decision on a change was remembered by the change's number rather than by the change itself,
  so a second edit to a line already accepted stayed silently accepted over text nobody had read.
- The assistants' error channel was appearing in the conversation as if the assistant had said
  it. It is held back now, and shown when a run fails — which is when it is the one thing you need.
