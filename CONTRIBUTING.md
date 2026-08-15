# Contributing

Thanks for your interest. This document exists so that the time you spend on a contribution isn't wasted.

## What Loadout is, and what it isn't

It's a Mac app for viewing and managing the configuration of the coding assistants running on your machine — skills, commands, agents, plugins and MCP servers — and for showing how much each one is actually used.

Deliberately out of scope: cloud sync, accounts, telemetry, and anything that writes to disk without taking a backup first. The app reads third-party files it doesn't control, so the rule is always the same: it only reports what it can prove, and it would rather say "I don't know" than invent a number.

## Reporting a bug

Open an issue with:

- what happened, and what you expected instead
- the steps to reproduce it
- the app version and the macOS version

## Suggesting a feature

Open an issue describing the **problem** before you write any code. A feature that falls outside the scope above will be rejected however well it is implemented, and that's an evening thrown away.

## Setting up

```bash
git clone <url>
cd loadout
swift test
./Scripts/build-app.sh && open dist/Loadout.app
```

Requires Xcode and macOS 15 or later. The icon and the logo are drawn in code, and redrawn with
`swift Scripts/make-icon.swift`.

There is also a check on the layer between the buttons and the disk, which runs the window's model against a throwaway `~`:

```bash
.build/debug/LoadoutApp --self-check
```

Neither the tests nor the self-check ever touch the real `~/.claude` — they run against temporary
trees, which is exactly what `Paths` taking its root by injection is for.

## How it is laid out

```
Sources/
├─ LoadoutCore/     the UI-less library — the rules and the tests live here
│  ├─ Paths           every path, injected — this is what makes real testing possible
│  ├─ Frontmatter     a forgiving YAML reader, including > and | blocks
│  ├─ InventoryScanner scans skills, commands, subagents, plugins and MCP
│  ├─ Mutations       create, save, move, delete — always after a snapshot
│  ├─ UsageIndex      an incremental SQLite index over the session logs
│  ├─ ChatRunner      runs the assistant, reporting what it says as it says it
│  ├─ ChatEvent       one translator per assistant, into a single shape
│  ├─ AskWorkspace    the disposable copy it works in, and the comparison with yours
│  ├─ DiffBlocks      each change as a separate decision, and applying them
│  ├─ ReviewLayout    the document with the changes opened up inside it
│  └─ Watcher         FSEvents with coalescing
└─ LoadoutApp/      SwiftUI
```

`Paths` takes its root by injection, and that single indirection is what keeps the tests away from
the real configuration and the code free of hardcoded paths.

There are launch hooks for exercising the app against a throwaway home, without touching the real
`~/.claude`:

```bash
LOADOUT_HOME=/tmp/home-fixture LOADOUT_VIEW=edit ./dist/Loadout.app/Contents/MacOS/Loadout
```

`LOADOUT_SCOPE`, `LOADOUT_TAB`, `LOADOUT_ASSISTANT`, `LOADOUT_FILTER`, `LOADOUT_VIEW` and
`LOADOUT_OPEN` compose with each other. The assistant conversation can be driven end to end, with
the real CLI and no hand on the mouse:

```bash
LOADOUT_HOME=/tmp/home-fixture LOADOUT_ASK=claude \
  LOADOUT_ASK_MESSAGE="improve the description" ./dist/Loadout.app/Contents/MacOS/Loadout
```

It sends the message through the same path the Send button uses, prints the conversation and the
proposed changes, and exits. `LOADOUT_ASK_DUMP=1` shows the conversation the panel reopened with,
and `LOADOUT_NEW_SKILL=<name>` walks the "Create and ask" path.

## Pull requests

- One change per pull request.
- Explain the why in the description; the what is already in the diff.
- The tests have to pass, and a change in behaviour comes with a test.
- The tests must never touch the real `~/.claude` — they all run against temporary trees, and that is precisely why `Paths` takes its root by injection.
- Follow the style of the surrounding code rather than introducing a new one.

## The animations

The pictures are made by the app driving itself, not recorded off the screen:

```bash
./Scripts/make-gif.sh          # all of it, in order — the one in the README
./Scripts/make-gif.sh browse   # the inventory, and what one item says
./Scripts/make-gif.sh toggle   # disabling a skill and putting it back
./Scripts/make-gif.sh share    # the same skill on a second assistant
./Scripts/make-gif.sh ask      # the conversation, and a change accepted
```

Each one builds a throwaway home with five skills, two commands and a subagent in it, then walks
the app through the same calls its buttons make — `select`, `toggle`, `setAssistant` — writing each
frame from the app's own window. That needs no screen-recording permission, because the window
belongs to the process drawing it. The `ask` scenes hold a real conversation with the real CLI.

The steps live in `Sources/LoadoutApp/Scenes.swift`, and each carries how long to sit on its own
result. The recorder writes down when every frame was taken and `Scripts/frame-timing.py` assembles
them at the speed it really happened — capture thins out when the app is busy, and a fixed frame
rate would make the busiest, most interesting stretch play fastest.

Everything in the pictures is real, and it has to stay that way. `GIF_WIDTH`, `GIF_WINDOW` and
`GIF_ASK` change the size, the window size, and which assistant is shown.

## The social preview card

The picture chat apps and search results show when somebody pastes a link to the repository:

```bash
swift Scripts/make-og-image.swift .github/assets/og-artwork.jpg
```

The artwork behind it is generated; everything on top of it — the name, the sentence, the line
of nouns — is drawn by the script in SF Pro, because an image model writes letters that are almost
words and a social card is mostly letters. GitHub refuses anything over 1 MB, so the script steps
the JPEG quality down until it fits.

It has to be uploaded by hand in Settings › General › Social preview. GitHub has no API for it.
