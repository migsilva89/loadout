---
title: Multi-Assistant Usage Index
version: 1.2
date_created: 2026-08-13
last_updated: 2026-08-13
changelog: 1.1 — amended after the Phase 1 audit (docs/AUDIT-USAGE-SOURCES.md, approved 2026-08-13):
  CON-004 narrowed, Paseo generalized beyond Codex, Codex originator role corrected, Cursor and Pi
  deferred out of v1.
owner: Miguel Silva (Loadout)
tags: [architecture, data, app, macos, swift, sqlite]
---

# Introduction

Loadout shows a usage count ("uses") for every skill, command, agent and MCP server it lists. Today that
count is derived from one source only: Claude Code session transcripts under `~/.claude/projects`. Every
other coding assistant installed on the machine — Codex, Paseo-hosted Codex agents, OpenCode, Pi, Cursor
and others — is invisible to the counter. The result is a number that is silently wrong: a skill used
many times across assistants reports `1 use`, and the user cannot tell whether that means "rarely used"
or "used somewhere Loadout does not read".

This specification defines the architecture that makes the usage index multi-assistant: a read-only
audit phase that establishes what each history format can actually prove, one adapter per format, a
normalized event model with stable identity and deduplication, a versioned SQLite schema with a safe
migration path, and a settings model in which a single user-facing control decides both what is shown
and what is counted.

## 1. Purpose & Scope

### 1.1 Purpose

Define the requirements, data contracts, interfaces, acceptance criteria and validation strategy for
replacing the single-source Claude usage index with a multi-source usage index, without regressing
existing counts, without duplicating events, and without fabricating numbers for formats whose activation
signal cannot be proven.

### 1.2 In scope

- Read-only audit of every assistant history format present on the machine.
- A normalized `UsageEvent` model and a `UsageSource` adapter protocol.
- Adapters for: Claude Code, Codex (including archived sessions), OpenCode, Pi, Cursor, and any further
  format the audit proves parseable.
- Paseo as an attribution *surface* over Codex sessions, never as a separate counted source.
- Event identity and deduplication rules.
- A versioned SQLite schema, an atomic build-aside-and-swap migration, and cancellation safety.
- Query-time filtering of counted assistants driven by the existing `hiddenAssistants` preference.
- Settings copy and per-source status reporting in the Usage tab.
- Anonymized test fixtures per format and validation against real local histories.

### 1.3 Out of scope

- Changing what Loadout counts as an *item* (skills, commands, agents, MCP servers, plugins stay as-is).
- Any change to skill installation, sharing, syncing, editing or backups.
- The pending detail-pane performance work in `AppModel.swift`, `DetailView.swift`, `MarkdownView.swift`
  and `TickRail.swift`. That work is committed separately and must not be mixed into this change
  (see CON-001).
- Remote or cloud history sources. Only local on-disk histories are read.
- DMG packaging and distribution.

### 1.4 Intended audience

Engineers implementing the change in this repository (Swift 6, SwiftUI, macOS, SQLite via the C API),
and reviewers validating the result against real local data.

### 1.5 Assumptions

- **ASM-001**: Loadout runs on the user's own machine and reads only that machine's local history files.
- **ASM-002**: The usage index is *derived data*. It can always be discarded and rebuilt from the
  histories, so no user data is lost by a failed migration.
- **ASM-003**: History formats are owned by third parties and will change without notice. The design must
  degrade to "unsupported" rather than to a wrong number.
- **ASM-004**: The reference snapshot for Claude on this machine at handoff time was 541 transcript files,
  ~7 954 total events, 174 explicit skill activations, 38 distinct skill names, with `usageWindowDays = 90`.
  Transcripts remain active, so exact counts will grow; the snapshot is a floor, not an equality target
  (see AC-003). Re-measured on 2026-08-13 during the audit: 541 files, 7 974 events, 174 skill activations,
  38 distinct names, and a raw grep still agreeing at 174.

## 2. Definitions

| Term | Definition |
| --- | --- |
| **Assistant** | A coding assistant installed on the machine, identified by its dot-directory name (`claude`, `codex`, `cursor`, `opencode`, …). In code: `Assistant` in `Sources/LoadoutCore/Assistants.swift`. |
| **Item** | A thing Loadout inventories and counts usage for: a skill, command, agent, MCP server or plugin. In code: `ItemKind` in `Sources/LoadoutCore/Model.swift`. |
| **History** | On-disk record of an assistant's sessions (transcripts, session logs), e.g. `~/.claude/projects/**/*.jsonl`. |
| **Usage source (source)** | One adapter that reads one history format and emits normalized events. |
| **Surface** | The front-end through which a session was run, when it is distinguishable inside a single history format. Example: a Codex session originated by Paseo has assistant `codex`, surface `paseo`. |
| **Activation** | Proven selection/invocation of an item by an assistant during a session. See §3.3. |
| **Event** | One activation occurrence at one timestamp, in one project, in one session. |
| **Event identity** | The stable string uniquely identifying an event across reindexes, used for deduplication. See §4.3. |
| **Window** | The `usageWindowDays` preference: 30, 90, 365 days, or "all". Events older than the window are not stored. |
| **Reference snapshot** | The measured Claude-only counts recorded in ASM-004, used to prove the Claude adapter did not regress. |
| **Unsupported source** | A history format present on disk for which no reliable activation signal has been established. It contributes zero events and is labelled `unsupported` in the UI. |
| **AC** | Acceptance criterion. |
| **JSONL** | JSON Lines: one JSON object per line. |
| **Reindex** | A full or incremental pass over histories that rebuilds or updates the index. |

## 3. Requirements, Constraints & Guidelines

### 3.1 Process requirements (phased delivery)

- **PRO-001**: The work SHALL be delivered in the ordered phases below. A later phase SHALL NOT begin
  before the previous phase's acceptance criteria pass.
  - Phase 0 — Freeze: commit the pending performance work separately, on explicit request only.
  - Phase 1 — Read-only audit (§3.2), producing the capability matrix (§4.1).
  - Phase 2 — Fixtures and contracts (`UsageSource`, `UsageEvent`, identity, dedup).
  - Phase 3 — Versioned schema and build-aside migration, no new sources yet.
  - Phase 4 — Sources one at a time, in the order the audit recommends: Claude (no number changes), then
    the Paseo attribution join (adds a surface, moves no count), then Codex (the 277 inferred events), and
    nothing else in v1 (CON-008).
  - Phase 5 — Settings and product copy.
  - Phase 6 — Validation against real local histories.
- **PRO-002**: Each adapter SHALL land as its own commit, with its own fixtures and tests, and with
  `swift test` green.
- **PRO-003**: No commit SHALL be created without the owner's explicit request.

### 3.2 Audit requirements (Phase 1, read-only)

- **AUD-001**: The audit SHALL enumerate, for every assistant on the machine: skills directory presence,
  installed app or executable presence, and every candidate history directory.
- **AUD-002**: The audit SHALL be strictly read-only. It SHALL NOT write to any history directory, SHALL
  NOT modify the SQLite index, and SHALL NOT change any preference.
- **AUD-003**: The audit SHALL document, per format: file layout, line/record types, timestamp field and
  encoding, project/cwd field, session identifier field, and originator/source field when present.
- **AUD-004**: The audit SHALL determine, per format, whether a *provable* activation signal exists
  (§3.3) and record the exact evidence pattern.
- **AUD-005**: The audit SHALL specifically resolve how a Codex session records a selected skill in the
  current Codex format, and SHALL state explicitly whether reading `SKILL.md` alone is accepted as
  evidence. It SHALL NOT be accepted alone (see CON-004).
- **AUD-006** (resolved in 1.1): The audit resolved the Codex `session_meta` surface fields
  (`originator`, `source`, `thread_source`) and established that none of them identifies Paseo. Paseo
  attribution moves to the session-id join in REQ-016.
- **AUD-007**: The audit SHALL locate and characterize the histories for OpenCode, Pi and Cursor, and
  SHALL audit `~/.claude/sessions` and `~/.paseo/projects`, each of which is currently unclassified.
- **AUD-008**: The audit SHALL NOT assume `AssistantRegistry.known` is complete, and SHALL NOT infer that
  the existence of `~/.<id>/skills` implies a supported history.
- **AUD-009**: The audit output SHALL be the capability matrix defined in §4.1, committed as a document
  under `docs/`.
- **AUD-010**: The audit document and any fixture SHALL be anonymized per SEC-001.

### 3.3 Activation semantics

- **SEM-001**: An event SHALL be recorded only for a **proven activation** of an item by an assistant,
  inside the configured window.
- **SEM-002**: The following SHALL NOT be counted as activations:
  - Skill metadata being present in the assistant's context or system prompt.
  - A mention of the item's name in prose, by the user or the assistant.
  - A file read, `rg`, `grep`, `sed` or `cat` of `SKILL.md` with no further evidence of selection.
  - The same session counted twice because it is reachable through two paths (e.g. Paseo and Codex).
- **SEM-003**: Claude Code activation evidence SHALL remain exactly the current signals, unchanged:
  - Skill: a `tool_use` block named `Skill` with `input.skill`; a `plugin:skill` value is normalized to
    the segment after the last `:`.
  - Agent: a `tool_use` block with `input.subagent_type`.
  - MCP: a `tool_use` block whose name has the `mcp__` prefix; the key is the server segment.
  - Command: a `<command-name>` element inside message text; a leading `/` is stripped and the value is
    normalized to the segment after the last `:`.
- **SEM-004**: Each adapter SHALL define its accepted evidence explicitly in code documentation and in
  the capability matrix. Composite evidence requiring an *announcement* of the skill alongside the read
  SHALL NOT be used: the audit measured only 49 of 333 real Codex reads whose preceding `agent_message`
  contains the skill's name literally, because announcements paraphrase ("o guia de troubleshooting do
  projeto" — the project's troubleshooting guide — preceding a read of `om-troubleshooter/SKILL.md`).
  Requiring it would discard 85% of genuine activations.
- **SEM-007** (added in 1.1): An event SHALL record whether its evidence is **explicit** (a dedicated
  activation signal, as Claude's `Skill` tool use) or **inferred** (a canonical full read under CON-004).
  The UI SHALL be able to distinguish them, so an inferred count is never presented as equally certain.
- **SEM-005**: A format with no provable signal SHALL be registered as an **unsupported source**: it is
  listed in the UI with status `unsupported`, contributes zero events, and SHALL NOT be silently
  reported as a zero count indistinguishable from "never used".
- **SEM-006**: Item name normalization SHALL be identical across adapters: trim whitespace, strip a
  leading `/`, take the segment after the last `:`, and compare case-sensitively against inventory names.

### 3.4 Architecture requirements

- **REQ-001**: A `UsageSource` protocol SHALL define the contract every adapter implements (§4.2).
- **REQ-002**: Each supported format SHALL have exactly one adapter: `ClaudeUsageSource`,
  `CodexUsageSource`, `OpenCodeUsageSource`, `PiUsageSource`, `CursorUsageSource`, plus any further
  adapter the audit justifies.
- **REQ-003**: `UsageIndex` SHALL own a registry of sources and SHALL NOT contain format-specific parsing
  logic. Parsing currently living in `UsageIndex` SHALL move into `ClaudeUsageSource`.
- **REQ-004**: Every event SHALL carry a non-optional `assistant` identifier and an optional `surface`.
- **REQ-005** (amended in 1.1): Paseo SHALL be represented as `surface = "paseo"` on events of **any**
  assistant it hosts, not Codex alone: the audit found 135 of 178 Paseo agent records have
  `provider = "claude"` against 41 `provider = "codex"`. There SHALL be no `PaseoUsageSource` counting
  `~/.paseo/*` as an independent history.
- **REQ-016** (added in 1.1): Paseo attribution SHALL be an exact join, not a heuristic. The set of
  Paseo-hosted session identifiers SHALL be read from `persistence.sessionId` (equivalently
  `runtimeInfo.sessionId`) in `~/.paseo/agents/**/*.json`, which holds the provider's own session id, and an
  event SHALL be attributed `surface = "paseo"` if and only if its `sessionID` is in that set. The working
  directory SHALL NOT be used for this: a session merely running inside `~/.paseo/worktrees` is not
  evidence that Paseo hosted the agent.
- **REQ-017** (added in 1.1): For Codex, `payload.originator` SHALL map to a surface among `codex-cli`,
  `codex-app`, `codex-exec` and `claude-code`. It SHALL NOT be used for Paseo detection: the audit found no
  Paseo value there. Observed values were `codex_cli_rs`, `codex-tui`, `codex_exec`, `Codex Desktop` and
  `Claude Code`.
- **REQ-006**: Every event SHALL have a stable `event_id` (§4.3) that is identical across repeated
  indexing passes over unchanged input.
- **REQ-007**: Insertion SHALL be idempotent: re-indexing the same input SHALL NOT increase counts.
- **REQ-008**: Incremental indexing SHALL be preserved: a history file whose size and mtime are unchanged
  and whose stored `since` is not narrower than the requested window SHALL NOT be reopened.
- **REQ-009**: The `files` table SHALL record the owning source identifier and that source's parser
  version, so that changing a parser invalidates exactly that source's cached files.
- **REQ-010**: Adapters SHALL be resilient: an unreadable, truncated or malformed record SHALL be skipped
  and SHALL NOT abort the file, the source, or the pass.
- **REQ-011**: Adapters SHALL stream files in bounded chunks and SHALL NOT load a whole history file into
  memory. The existing 1 MiB chunked line reader is the reference implementation.
- **REQ-012**: Adapters SHALL apply a cheap byte/substring prefilter before JSON parsing, as the current
  Claude parser does, and the prefilter SHALL be covered by a test that proves it does not drop a valid
  activation.
- **REQ-013**: A reindex SHALL be cancellable, and cancellation SHALL be checked at least once per file.
- **REQ-014**: Each source SHALL report a per-source status: `included`, `excluded`, `noHistory`,
  `unsupported`, or `error(String)`, plus a session count and event count when known.
- **REQ-015**: Adding a new source SHALL require no change to the SQLite schema.

### 3.5 Storage and migration requirements

- **DAT-001**: The index schema SHALL be versioned via SQLite `PRAGMA user_version`.
- **DAT-002**: The schema SHALL extend `events` with `assistant TEXT NOT NULL`, `surface TEXT`,
  `event_id TEXT NOT NULL UNIQUE`, `session_id TEXT`, and SHALL extend `files` with `source TEXT NOT NULL`
  and `parser_version INTEGER NOT NULL`.
- **DAT-003**: Migration SHALL NOT mutate the live database in place while the UI reads it. The migration
  SHALL build a new database at a sibling temporary path, fully populate it, and atomically replace the
  live file only on success.
- **DAT-004**: If migration or the initial rebuild fails or is cancelled, the previous database SHALL
  remain intact and usable, and the UI SHALL continue serving the previous counts.
- **DAT-005**: The UI SHALL never observe a mixture of old-schema and new-schema data.
- **DAT-006**: On opening a database whose `user_version` is newer than the running build supports, the
  app SHALL NOT write to it; it SHALL rebuild a fresh index aside rather than corrupt the newer file.
- **DAT-007**: The temporary build database SHALL be removed on success and on failure; a leftover
  temporary file SHALL be detected and discarded on next launch.
- **DAT-008**: All writes for one file's events SHALL remain inside a single `BEGIN IMMEDIATE` /
  `COMMIT` transaction, as today, so a reader never sees a delete-without-reinsert gap.
- **DAT-009**: Indexes SHALL exist on `(kind, key)`, `(file)`, and `(assistant)` at minimum, and query
  plans for the annotate path SHALL be verified not to regress from the current implementation.

### 3.6 Settings and product requirements

The owner decided (2026-08-13) that a **single control** governs both list visibility and usage counting.
The existing per-assistant checkbox in Settings › Assistants is that control.

- **UIX-001**: The per-assistant checkbox in Settings › Assistants SHALL govern both (a) visibility in
  list rows and the detail panel, and (b) whether that assistant's events are included in usage counts.
- **UIX-002**: The checkbox SHALL continue to persist to the existing `hiddenAssistants` preference key.
  No new preference key SHALL be introduced for source selection.
- **UIX-003**: The checkbox label SHALL be renamed from `Show in list` to wording that states both
  effects, and the section header SHALL be rewritten: the current text claims unchecked assistants "just
  don't show up", which becomes false under UIX-001.
- **UIX-004**: Because hiding now changes numbers, the UI SHALL state that consequence in the Assistants
  tab before the user acts. This is a mandatory mitigation of the coupling, not a recommendation.
- **UIX-005**: Exclusion SHALL be applied at **query time**, not at index time. All discovered histories
  are always indexed; the checkbox filters the read. This makes toggling instant, reversible and lossless.
- **UIX-006**: Toggling a checkbox SHALL NOT trigger a reindex, SHALL update counts within one UI update
  cycle, and SHALL be exactly reversible: re-checking restores the prior counts.
- **UIX-007**: The Usage tab SHALL list one row per discovered source, read-only, showing the assistant,
  its status per REQ-014, its session count, and its event count. Rows SHALL state that inclusion is
  controlled in the Assistants tab.
- **UIX-008**: An assistant with no supported history SHALL show `no history found` or `unsupported` in
  the Usage tab, so an unchanged count after toggling is explainable.
- **UIX-009**: The Usage tab copy SHALL stop saying "Claude Code transcripts" and SHALL name the included
  assistants and the window.
- **UIX-010**: The "uses" count and the "Used in" project list SHALL both reflect the same included-source
  filter, and "Used in" SHALL aggregate distinct projects without double counting deduplicated events.
- **UIX-011**: Every usage row SHALL be explainable on demand by assistant, timestamp, project, and
  session or source file. The data required for that explanation SHALL be queryable.
- **UIX-012**: All index reads SHALL remain off the main thread, as the current `projectUsage` detached
  query does, and the window/reindex controls SHALL stay responsive during a pass.
- **UIX-013**: UI copy SHALL follow the Apple Style Guide conventions already used in the app: sentence
  case, second person, present tense, no jargon.

### 3.7 Security and privacy requirements

- **SEC-001**: No fixture, spec, audit document, log or error message SHALL contain real user content.
  Prompts, file contents, absolute home paths, `cwd` values, session identifiers, repository names,
  hostnames and usernames SHALL be anonymized or removed.
- **SEC-002**: Fixtures SHALL be minimal: only the record types and fields needed to exercise the parser.
- **SEC-003**: Histories SHALL be opened read-only. No adapter SHALL write, move, rename or delete any
  file under a history directory.
- **SEC-004**: The index SHALL store only what the UI needs: item key, kind, assistant, surface,
  timestamp, project leaf name, session identifier and source file path. It SHALL NOT store prompt or
  message text.
- **SEC-005**: The app SHALL tolerate unreadable history directories (permissions, sandbox denial) by
  reporting `error` for that source rather than crashing or prompting repeatedly.

### 3.8 Constraints

- **CON-001**: The four modified files of pending performance work SHALL NOT be included in any commit
  belonging to this feature.
- **CON-002**: The Claude adapter SHALL produce counts consistent with the reference snapshot (ASM-004);
  any difference SHALL be explained by elapsed time or by a documented, deliberate change.
- **CON-003**: No third-party dependency SHALL be added. SQLite via the existing C API and Foundation only.
- **CON-004** (amended in 1.1 after the audit): An **incidental** read of `SKILL.md` SHALL NOT constitute
  activation evidence in any adapter. Incidental means: a search (`rg`, `grep`), a listing (`ls`, `find`), a
  write of any form (`apply_patch`, redirection, `sed -i`, `cp`, `mv`, `rm`), or any command shape that is
  not a canonical full read. A **canonical full read** — `cat`, `sed -n`, `head`, `less` of a path matching
  `**/skills/<name>/SKILL.md`, performed by a tool call — IS accepted evidence, but only for adapters whose
  format offers no explicit activation signal, and the resulting events SHALL be marked inferred (see
  SEM-007). Rationale: the audit found Codex has no skill tool at all, so a canonical read is its actual
  activation mechanism; on this machine that separates 277 genuine activations across 30 skills from 78
  skills merely named by the prompt catalogue.
- **CON-008**: Cursor and Pi SHALL NOT ship adapters in v1. Cursor transcripts carry no per-record
  timestamp, so events cannot be placed inside the window, and neither format exposes a skill signal. Both
  SHALL be registered as sources reporting `unsupported` or `noHistory`.
- **CON-005**: Swift 6 concurrency SHALL be respected: adapters SHALL be `Sendable` or documented
  `@unchecked Sendable` with the lock discipline explained, matching the existing `UsageIndex` pattern.
- **CON-006**: Existing public API of `UsageIndex` used by `AppModel` (`refresh`, `usage(kind:)`,
  `projects(kind:key:)`, `annotate`, `eventCount`, `indexedFileCount`) SHALL keep working; signatures may
  gain defaulted parameters but SHALL NOT break callers.
- **CON-007**: Path construction SHALL go through `Paths`; no adapter SHALL hardcode a home directory, so
  tests keep running against a temporary tree.

### 3.9 Guidelines and patterns

- **GUD-001**: Prefer proving a signal on real data before writing the adapter for it.
- **GUD-002**: Prefer `unsupported` over a plausible guess. A wrong number is worse than an honest gap.
- **GUD-003**: Keep each adapter's accepted evidence documented next to the code that detects it.
- **GUD-004**: Measure before concluding a performance claim; state the measurement.
- **PAT-001**: Registry of adapters behind one protocol; the index orchestrates, adapters parse.
- **PAT-002**: Build-aside-and-swap for any schema change to derived data.
- **PAT-003**: Content-addressed event identity for idempotent inserts.
- **PAT-004**: Filter at read time for user-toggleable inclusion; index everything discoverable.

## 4. Interfaces & Data Contracts

### 4.1 Capability matrix (Phase 1 deliverable)

Completed on 2026-08-13. The full matrix, with every measurement and its method, is
`docs/AUDIT-USAGE-SOURCES.md`; this table is its binding summary. `Activation evidence` is a literal
pattern, not a description.

| Assistant | History root | Files | Timestamp field | Project field | Session field | Surface field | Activation evidence | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | `~/.claude/projects` | 541 `.jsonl` | `timestamp` (ISO-8601 UTC) | `cwd` | per record | — | `tool_use` name `Skill` with `input.skill`; `input.subagent_type`; `mcp__*`; `<command-name>` | **supported, explicit** |
| claude | `~/.claude/sessions` | 13 `.json` | `startedAt` (epoch ms) | `cwd` | `sessionId` | `entrypoint` | none — holds no messages | **not a source** |
| codex | `~/.codex/sessions` | 107 `.jsonl` | top-level `timestamp` | `payload.cwd` in `session_meta` | `payload.session_id` | `payload.originator`, `payload.source`, `payload.thread_source` | canonical full read of `**/skills/<name>/SKILL.md` by a tool call (CON-004) | **supported, inferred** |
| codex | `~/.codex/archived_sessions` | 39 `.jsonl` | same | same | same | same | same | **supported, inferred** |
| paseo | `~/.paseo/agents` | 178 `.json` | `createdAt`, `lastActivityAt` | `cwd` | `persistence.sessionId` = the provider's session id | `provider` (claude 135, codex 41) | none — holds no messages | **not a source; the attribution join of REQ-016** |
| paseo | `~/.paseo/projects` | 4 `.json` | — | — | — | — | none | **not a source** |
| cursor | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` | 10 `.jsonl` | **none** | directory slug | directory uuid | — | none — no skill tool, no `SKILL.md` read | **unsupported** (CON-008) |
| cursor | `~/.cursor/projects/**` (rest) | 13 772 | — | — | — | — | MCP caches only | **not a source** |
| opencode | `~/.local/share/opencode/storage` | 5 555 `.json` | on `message` records | `session` records | `sessionID` | — | none — no skill tool, zero `SKILL.md` references in 4 419 tool parts | **unsupported** |
| pi | `~/.pi/agent/sessions` | 1 `.jsonl` | `timestamp` | `cwd` | `id` | — | none observed | **no history worth counting** (CON-008) |
| commandcode, factory, hermes, kiro, trae, windsurf, gemini, copilot | — | — | — | — | — | — | no history directory found | **no history found** |

Two discovery defects the audit surfaced, to be fixed as separate work: Pi keeps skills at
`~/.pi/agent/skills` and Cursor at `~/.cursor/skills-cursor`, while `AssistantRegistry.discover` only looks
at `~/.<id>/skills`, so neither assistant is listed at all today.

### 4.2 `UsageSource` protocol

```swift
/// One history format. The index orchestrates; a source only parses.
public protocol UsageSource: Sendable {
    /// Stable identifier of the adapter, e.g. "claude", "codex". Persisted in `files.source`.
    var id: String { get }

    /// Assistant identifier attributed to every event this source emits. Matches `Assistant.id`
    /// so the Settings checkbox can filter on it.
    var assistant: String { get }

    /// Bumped whenever the parsing rules change. A mismatch with `files.parser_version`
    /// invalidates this source's cached files and forces a re-parse of them (REQ-009).
    static var parserVersion: Int { get }

    /// Whether this format has a proven activation signal. `false` means the source is listed
    /// as `unsupported` and emits nothing (SEM-005).
    var isSupported: Bool { get }

    /// History files this source owns, or an empty array when there is no history on disk.
    /// Must not throw for a missing directory.
    func historyFiles() -> [URL]

    /// Parses one file. Malformed records are skipped, never fatal (REQ-010).
    /// Streams in bounded chunks (REQ-011).
    func events(in file: URL, since: Date) -> [UsageEvent]

    /// Read-only status for the Usage tab (REQ-014).
    func status() -> UsageSourceStatus
}

public enum UsageSourceState: Sendable, Equatable {
    case included
    case excluded      // history exists and parses, but the assistant is unchecked
    case noHistory     // adapter exists, nothing on disk
    case unsupported   // history exists, no provable activation signal
    case error(String)
}

public struct UsageSourceStatus: Sendable, Equatable {
    public var sourceID: String
    public var assistant: String
    public var state: UsageSourceState
    public var sessionCount: Int
    public var eventCount: Int
}
```

### 4.3 `UsageEvent` and event identity

```swift
public struct UsageEvent: Sendable, Equatable {
    /// Stable identity for deduplication and idempotent insertion (REQ-006, REQ-007).
    public var id: String
    /// `claude`, `codex`, `opencode`, `pi`, `cursor`. Never empty (REQ-004).
    public var assistant: String
    /// `paseo`, `codex-cli`, `codex-app`, when the format distinguishes it. Otherwise nil.
    public var surface: String?
    public var kind: ItemKind
    /// Normalized item name (SEM-006).
    public var key: String
    public var timestamp: Date
    /// Leaf component of the session's working directory, as today.
    public var project: String
    public var sessionID: String?
    /// Absolute path of the file the event was parsed from. Used for incremental invalidation
    /// and for explaining a count (UIX-011).
    public var sourceFile: String
    /// How certain this event is (SEM-007). `.explicit` for a dedicated activation signal,
    /// `.inferred` for a canonical full read under CON-004.
    public var evidence: UsageEvidence
}

public enum UsageEvidence: String, Sendable { case explicit, inferred }
```

**Identity rule.** `id` SHALL be a lowercase hexadecimal SHA-256 digest of the following fields joined by
`\u{1F}` (unit separator), in this exact order:

```
assistant, kind.rawValue, key, session-or-file, timestamp-milliseconds, ordinal
```

where:

- `session-or-file` is `sessionID` when the format provides one, otherwise the source file path.
- `timestamp-milliseconds` is the integer count of milliseconds since the Unix epoch.
- `ordinal` is the zero-based index of this event among events sharing all previous fields within the same
  file, so two genuine same-millisecond activations of the same item are both preserved.

**Consequences.**

- **Idempotence**: re-parsing an unchanged file yields identical ids, so `INSERT OR IGNORE` on the unique
  `event_id` column keeps counts stable (REQ-007).
- **Paseo deduplication**: a Paseo-hosted Codex session is parsed once, from the Codex history, so no
  second id can exist for it (REQ-005). If the audit finds a Paseo history that literally duplicates a
  Codex session file, the identity SHALL be derived from `sessionID`, making the duplicate collide and be
  ignored rather than counted twice.
- The identity deliberately excludes `surface` and `project`, so a corrected surface attribution or a
  moved working directory does not create a phantom second event.

### 4.4 SQLite schema, version 2

```sql
PRAGMA user_version = 2;

CREATE TABLE files (
    path           TEXT PRIMARY KEY,
    source         TEXT NOT NULL,      -- UsageSource.id (REQ-009)
    parser_version INTEGER NOT NULL,   -- UsageSource.parserVersion (REQ-009)
    size           INTEGER NOT NULL,
    mtime          REAL NOT NULL,
    since          REAL NOT NULL
);

CREATE TABLE events (
    event_id   TEXT NOT NULL UNIQUE,   -- §4.3 (REQ-006)
    file       TEXT NOT NULL,
    source     TEXT NOT NULL,
    assistant  TEXT NOT NULL,          -- REQ-004
    surface    TEXT,                   -- REQ-004
    kind       TEXT NOT NULL,
    key        TEXT NOT NULL,
    ts         REAL NOT NULL,
    project    TEXT NOT NULL,
    session_id TEXT,
    evidence   TEXT NOT NULL DEFAULT 'explicit'   -- 'explicit' | 'inferred' (SEM-007)
);

CREATE INDEX events_lookup    ON events (kind, key);
CREATE INDEX events_file      ON events (file);
CREATE INDEX events_assistant ON events (assistant);
```

Version 1 is the current schema (`files(path, size, mtime, since)`,
`events(file, kind, key, ts, project)`).

### 4.5 Migration procedure

```
1. Open the live index read-only enough to read PRAGMA user_version.
2. If user_version == 2: proceed normally.
3. If user_version > 2: do not write. Build aside and swap (DAT-006).
4. If user_version < 2:
   a. Create <index>.migrating.sqlite (delete any leftover first, DAT-007).
   b. Create schema version 2 there.
   c. Run a full reindex over every discovered source into the temporary database.
   d. On cancellation or error: delete the temporary file, keep the live database, report the
      failure in the Usage tab, keep serving old counts (DAT-004).
   e. On success: atomically replace the live database with the temporary one
      (FileManager.replaceItemAt, which is atomic on the same volume), including WAL/SHM cleanup.
   f. Reopen and publish the new counts in a single UI update (DAT-005).
5. Version 1 rows are NOT translated into version 2 rows: they lack `assistant` and `event_id`,
   and the index is derived data (ASM-002). Rebuilding is both cheaper and provably correct.
```

### 4.6 Read API

```swift
extension UsageIndex {
    /// Usage per key, restricted to the included assistants (UIX-005).
    /// `assistants == nil` means "all", preserving the current behaviour for callers that
    /// have no filter (CON-006).
    public func usage(kind: ItemKind, assistants: Set<String>? = nil) -> [String: Usage]

    public func projects(
        kind: ItemKind, key: String, assistants: Set<String>? = nil, limit: Int = 8
    ) -> [ProjectUsage]

    public func annotate(_ items: [Item], assistants: Set<String>? = nil) -> [Item]

    /// Backs "explain this count" (UIX-011): one row per event, newest first.
    public func occurrences(
        kind: ItemKind, key: String, assistants: Set<String>? = nil, limit: Int = 200
    ) -> [UsageOccurrence]

    /// One row per discovered source for the Usage tab (UIX-007).
    public func sourceStatuses(includedAssistants: Set<String>) -> [UsageSourceStatus]
}

public struct UsageOccurrence: Sendable, Equatable {
    public var assistant: String
    public var surface: String?
    public var timestamp: Date
    public var project: String
    public var sessionID: String?
    public var sourceFile: String
}
```

`AppModel` SHALL derive the included set as *all discovered assistant identifiers minus
`hiddenAssistantIDs`*, and SHALL pass it to every read (UIX-001, UIX-005).

## 5. Acceptance Criteria

### 5.1 Audit

- **AC-001**: Given the machine's installed assistants, When the Phase 1 audit runs, Then a capability
  matrix in the §4.1 shape exists under `docs/`, covering every history root listed there, and no entry
  remains "to audit".
- **AC-002**: Given the audit ran, When the SQLite index file's mtime and every history directory's
  contents are compared before and after, Then nothing was written (AUD-002).

### 5.2 Claude parity

- **AC-003** (amended in 1.2, after validation against the real histories): Given the reference snapshot
  (ASM-004), When the Claude adapter replaces the in-index parser, Then it reports **166** skill
  activations across the same **38** distinct names, and the 8-event difference from the snapshot's 174 is
  accounted for exactly by deduplication: 174 is the number of raw `Skill` tool-use blocks on disk, 166 is
  the number of distinct `(sessionId, timestamp, skill)` triples, and each of the 8 extra copies was
  measured living in two transcript files at once, because a resumed session rewrites its earlier history
  into a new file. The old count double-counted those 8; the event identity of §4.3 collapses them, which
  is the intended behaviour and not a regression. Any *further* difference SHALL be explained or fixed.
- **AC-004**: Given the same transcripts, When counts from the new adapter are compared against a raw
  `"name":"Skill"` grep over `~/.claude/projects`, Then the two agree, as they did at snapshot time.
- **AC-005**: Given a Claude transcript containing a `plugin:skill` invocation, When it is indexed, Then
  the stored key is the segment after the last `:`.

### 5.3 Codex and Paseo

- **AC-006**: Given a Codex session fixture containing the audited activation evidence, When indexed,
  Then one event per activation is stored with `assistant = "codex"`.
- **AC-007** (amended in 1.1): Given a Codex session fixture in which a skill's `SKILL.md` path appears
  only in a search (`rg`, `grep`), a listing (`ls`, `find`), a write (`apply_patch`, redirection) or in
  message text, When indexed, Then no event is stored (CON-004, SEM-002).
- **AC-007b**: Given a Codex session fixture with a canonical full read (`sed -n '1,240p' …/SKILL.md`),
  When indexed, Then one event is stored with `evidence = .inferred` (CON-004, SEM-007).
- **AC-007c** (measured in 1.2): Given this machine's real Codex histories and the "all" window, When
  indexed under the CON-004 rule, Then the result is **232 events across 30 skills** — the same 30 names
  the audit reached by canonical read, with fewer events than the audit's 277 raw matches because a single
  command reading the same skill twice is one use — and none of the 78 skills merely named by the prompt
  catalogue appears.
- **AC-008** (amended in 1.1): Given a Paseo agent record whose `persistence.sessionId` matches a session
  in that provider's history, When indexed, Then exactly one event per activation is stored, carrying that
  provider as `assistant` and `surface = "paseo"`, and the total count is unchanged from the same index
  built without the Paseo join (REQ-016).
- **AC-008b**: Given a session whose working directory is under `~/.paseo/worktrees` but whose id is in no
  Paseo agent record, When indexed, Then its `surface` is not `paseo` (REQ-016).
- **AC-009**: Given both `~/.codex/sessions` and `~/.codex/archived_sessions` contain the same session
  identifier, When both are indexed, Then the event appears once, because the identities collide (§4.3).
- **AC-010**: Given `~/.paseo/projects` contains workspace metadata, When a full reindex runs, Then no
  event originates from that path.

### 5.4 Other sources

- **AC-011**: Given a format the audit marked unsupported, When the Usage tab is opened, Then that source
  shows `unsupported`, contributes zero events, and is visually distinguishable from a supported source
  with a genuine zero (SEM-005, UIX-008).
- **AC-011b** (added in 1.1): Given Cursor, OpenCode and Pi ship no adapter in v1, When the Usage tab is
  opened, Then each still appears as a source with `unsupported` or `no history found`, so its absence from
  the counts is visible rather than silent (CON-008, SEM-005).
- **AC-012**: Given an adapter is added for OpenCode, Pi or Cursor after v1, When it lands, Then it ships
  with at least one anonymized fixture per accepted evidence pattern and one negative fixture that must not
  count.
- **AC-013**: Given a history directory that does not exist, When `historyFiles()` is called, Then it
  returns an empty array and the status is `noHistory`, with no thrown error.

### 5.5 Settings behaviour

- **AC-014**: Given Codex is checked in Settings › Assistants, When its checkbox is unchecked, Then Codex
  disappears from list rows and the detail panel *and* Codex events stop contributing to every "uses"
  count and to "Used in", within one UI update and with no reindex (UIX-001, UIX-006).
- **AC-015**: Given the checkbox was just unchecked, When it is checked again, Then every count returns
  exactly to its previous value (UIX-006).
- **AC-016**: Given the Assistants tab is open, When the user reads the section header and the checkbox
  label, Then both state that unchecking also removes that assistant from usage counts (UIX-003, UIX-004).
- **AC-017**: Given the Usage tab is open, When it renders, Then it shows one read-only row per discovered
  source with status, session count and event count, and it does not claim the index is Claude-only
  (UIX-007, UIX-009).
- **AC-018**: Given an assistant that has no history, When its checkbox is toggled, Then no count changes
  and the Usage tab explains why with `no history found` (UIX-008).
- **AC-019**: Given any skill showing a nonzero count, When its occurrences are requested, Then each one
  is reported with assistant, timestamp, project and session or source file (UIX-011).

### 5.6 Storage, migration and resilience

- **AC-020**: Given a version 1 database, When the app launches with the new build, Then a version 2
  database is built aside and swapped in atomically, and at no point does a query observe version 1 and
  version 2 data together (DAT-003, DAT-005).
- **AC-021**: Given a migration in progress, When it is cancelled or fails, Then the previous database
  file is byte-identical to before, the UI keeps serving the old counts, and the temporary file is gone
  (DAT-004, DAT-007).
- **AC-022**: Given a database with `user_version = 99`, When the app opens it, Then it performs no write
  to that file (DAT-006).
- **AC-023**: Given an unchanged history file, When a second reindex runs with the same window, Then that
  file is skipped and total counts are unchanged (REQ-008, REQ-007).
- **AC-024**: Given a source's `parserVersion` is incremented, When a reindex runs, Then only that
  source's files are re-parsed and other sources' cached files are still skipped (REQ-009).
- **AC-025**: Given a history file with a truncated final line, an invalid UTF-8 byte sequence, and a
  record missing its timestamp, When it is indexed, Then valid records from that file are still stored and
  no error propagates out of the pass (REQ-010).
- **AC-026**: Given the window changes from 90 days to "all", When the reindex runs, Then previously
  skipped files are re-parsed because the stored `since` is narrower than the requested one (REQ-008).
- **AC-027**: Given a history directory the process cannot read, When indexing runs, Then that source
  reports `error` and other sources complete normally (SEC-005).

### 5.7 Responsiveness

- **AC-028**: Given a full reindex over every discovered source, When it runs, Then the app stays
  interactive: selecting items, switching tabs and changing the window all respond, and no index read
  happens on the main thread (UIX-012).
- **AC-029**: Given the detail pane is open, When usage queries run, Then they run off the main thread, as
  the existing detached `projectUsage` query does.

### 5.8 Suite

- **AC-030**: Given the change is complete, When `swift test` runs, Then every test passes, including the
  pre-existing suite (106 tests at handoff) plus the new fixture tests.
- **AC-031**: Given the app is built with `./Scripts/build-app.sh`, When it launches, Then the built-in
  self-check reports no new failure.

## 6. Test Automation Strategy

- **Test levels**
  - *Unit*: per-adapter parsing — positive evidence, negative evidence, malformed records, timestamp
    parsing, name normalization, identity stability.
  - *Integration*: `UsageIndex` over a temporary `Paths` tree containing several fixture sources at once;
    incremental skip; window widening; parser-version invalidation; migration and swap; cancellation.
  - *Product-level*: `AppModel` derives the included-assistant set from `hiddenAssistantIDs` and read
    results change accordingly and reversibly.
- **Framework**: the repository's existing `swift test` suite under `Tests/LoadoutCoreTests`, extending the
  existing `Fixture.swift` helpers. No new dependency (CON-003).
- **Test data management**: fixtures live under `Tests/LoadoutCoreTests/Fixtures/<source>/`, are hand-written
  and anonymized (SEC-001, SEC-002), and are small enough to read in a review. Tests build a temporary home
  via `Paths(home:)` and never touch the real `~` (CON-007). Temporary trees are removed on teardown.
- **Fixture inventory required per supported source**: one file with a single activation; one file with
  multiple activations including two in the same millisecond; one file with only non-activation evidence
  (must yield zero); one malformed/truncated file; where applicable, one file carrying a distinguishable
  surface value.
- **CI/CD integration**: `swift test` and `./Scripts/build-app.sh` run per adapter commit (PRO-002).
- **Coverage requirements**: every adapter's `events(in:since:)` and every branch of its evidence
  detection SHALL be covered by at least one positive and one negative test. Migration SHALL be covered
  for success, failure and cancellation.
- **Performance testing**: a full reindex over the real local histories SHALL be timed and reported, and
  the main thread SHALL be sampled during it to confirm no index work runs there (AC-028). Measurements
  SHALL be recorded, per GUD-004.
- **Real-data validation** (not a substitute for fixtures): per-assistant event counts SHALL be compared
  against raw greps over the real histories, and a sample of skills reporting a low count SHALL be
  explained event by event (AC-019).

## 7. Rationale & Context

**Why the counter is wrong today.** `Paths.transcripts` resolves to `~/.claude/projects` and `UsageIndex`
parses only that tree. The parser itself was verified correct at snapshot time — SQLite and a raw grep
both returned 174 Claude skill activations — so the undercount is not a parsing bug. It has two causes:
every non-Claude history is excluded, and "use" is defined narrowly as an explicit activation. Fixing the
first cause is this specification's main work; the second cause is deliberate and stays (SEM-001).

**Why one adapter per format.** The formats differ in layout, record types, timestamp encoding and, most
importantly, in what they can prove. Keeping them behind one protocol lets the index stay format-agnostic,
lets an unsupported format be a first-class state instead of a silent zero, and makes each new assistant a
self-contained commit with its own fixtures.

**Why proof-based activation.** Codex sessions frequently read `SKILL.md`, and Codex's own instructions
push the agent to announce and read a selected skill. A read alone is ambiguous: it happens during
grepping, browsing and unrelated file inspection. Counting it would inflate numbers in a way the user
cannot audit, which is worse than the current undercount because it looks right. Hence CON-004 and
SEM-005: prove it or label it unsupported.

**Why Paseo is a surface, not a source.** Paseo hosts and coordinates Codex agents, and those sessions
land in `~/.codex/sessions`. A `PaseoUsageSource` reading its own tree would double-count the same work.
Attribution belongs in the `surface` field. It is *not* resolved from the Codex `session_meta`
originator: the audit established that no value there identifies Paseo (REQ-016). It comes instead from
joining on the session id — `~/.paseo/agents` holds metadata naming the provider session Paseo ran, and
that is an exact key. The event identity is keyed on the session, so any literal duplicate collides
instead of accumulating (§4.3).

**Why a versioned build-aside migration.** The index is derived data, so translating version 1 rows is
pointless: they have no `assistant` and no `event_id`, the two fields the new model requires. Rebuilding
is both cheaper to implement and provably correct. What must be protected is the user's experience during
the rebuild — hence a temporary database, an atomic replace, and the previous file left intact on failure.

**Why filtering happens at read time.** The owner chose to keep one control instead of separating
visibility from statistics. The genuine risk of that choice is that hiding an icon changes historical
numbers. Read-time filtering removes the destructive half of that risk: everything discoverable is always
indexed, so unchecking hides and excludes, re-checking restores exactly, and no reindex is needed. The
remaining risk is comprehension, which is why UIX-003 and UIX-004 make the coupling explicit in the UI
rather than leaving the old "they just don't show up in the list" copy in place, which would now be false.

**Why the existing preference key is reused.** `hiddenAssistants` is already read by both `AppModel` and
the Settings tab through the same key, so both sides observe changes immediately. Adding a second key
would introduce a second source of truth for a decision the owner explicitly wanted unified.

## 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Claude Code session transcripts — local JSONL under `~/.claude/projects`; read-only.
- **EXT-002**: Codex session logs — local JSONL under `~/.codex/sessions` and
  `~/.codex/archived_sessions`; read-only.
- **EXT-003**: Paseo — `~/.paseo/agents`, read-only, for metadata alone. Never counted as a history of
  its own: those files hold no messages, and the sessions they name are already in the provider's own
  logs. Read only to attribute a session to Paseo, by session id.
- **EXT-004**: OpenCode, Pi, Cursor and any further assistant history discovered by the audit; read-only,
  each supported only once its activation evidence is proven.

### Third-Party Services

- **SVC-001**: None. The feature is entirely local and requires no network access.

### Infrastructure Dependencies

- **INF-001**: SQLite, via the system C API already linked by the project, with WAL journaling.
- **INF-002**: Local filesystem read access to the user's home directory. Under sandboxing or restricted
  permissions, an unreadable source degrades to `error` (SEC-005).

### Data Dependencies

- **DAT-101**: Assistant history files — third-party formats, appended continuously while the assistant
  runs, may be rewritten or rotated. Consumed incrementally by size and mtime.
- **DAT-102**: `hiddenAssistants` in `UserDefaults` — the single control for visibility and inclusion.
- **DAT-103**: `usageWindowDays` in `UserDefaults` — 30, 90, 365 or "all".
- **DAT-104**: The derived index at `~/.claude/.loadout/usage.sqlite` — rebuildable at any time.

### Technology Platform Dependencies

- **PLT-001**: Swift 6 with strict concurrency; adapters must satisfy `Sendable` or document their
  locking (CON-005).
- **PLT-002**: SwiftUI on macOS for the Settings tabs and the detail pane.
- **PLT-003**: Foundation `FileManager` for size and mtime reads — `URL.resourceValues` caches, and a
  cached size makes a rewritten transcript look untouched forever, as the existing code notes.

### Compliance Dependencies

- **COM-001**: User privacy — histories contain the user's prompts, code and repository names. Only
  derived metadata is stored (SEC-004) and nothing real is committed to the repository (SEC-001).

## 9. Examples & Edge Cases

### 9.1 Claude activation (supported today, must not regress)

```json
{"timestamp":"2026-07-02T09:14:22.481Z","cwd":"/Users/anon/Projects/example",
 "message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"plugin-x:design-research"}}]}}
```

Yields one event: `kind = skill`, `key = "design-research"`, `assistant = "claude"`, `surface = nil`,
`project = "example"`.

### 9.2 Codex session shape (evidence pattern to be fixed by the audit)

```json
{"type":"session_meta","payload":{"session_id":"S-0001","cwd":"/Users/anon/Projects/example","source":"<originator>"}}
{"type":"turn_context","payload":{}}
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}
```

The adapter SHALL be written only after the audit fills in the concrete evidence for a selected skill and
the concrete `source` values. Until then `CodexUsageSource.isSupported` is `false` and it emits nothing.

### 9.3 Negative case — a bare `SKILL.md` read never counts

```json
{"type":"response_item","payload":{"type":"function_call","name":"exec_command",
 "arguments":"{\"command\":\"cat ~/.agents/skills/some-skill/SKILL.md\"}"}}
```

Yields zero events (CON-004, AC-007).

### 9.4 Paseo attribution, not duplication

A Paseo agent record supplies the join key, and the session it points at is parsed once, from that
provider's own history:

```json
{"provider":"claude","cwd":"<workspace>","persistence":{"sessionId":"S-0001"}}
```

```
Claude session S-0001 → assistant = "claude", surface = "paseo"   (already inside the 174 counted today)
Codex  session S-0002 → assistant = "codex",  surface = "paseo"
```

There is never an event with `assistant = "paseo"`, `~/.paseo/projects` yields nothing, and attributing a
surface moves no count (AC-008, AC-010, REQ-016).

### 9.5 Same-millisecond activations

Two activations of the same skill in one session at the identical millisecond are distinguished by the
`ordinal` component of the identity, so both are stored. Re-parsing the same file reproduces the same two
identities, so the count stays at two rather than growing (§4.3, AC-023).

### 9.6 Archived duplicate

A session present in both `~/.codex/sessions` and `~/.codex/archived_sessions` has the same `session_id`,
therefore the same event identities, therefore one row after `INSERT OR IGNORE` (AC-009).

### 9.7 Toggling an assistant

```
Codex checked   → seo-audit shows 9 uses across 4 projects
Codex unchecked → seo-audit shows 3 uses across 2 projects, Usage tab row: Codex — excluded, 146 sessions
Codex checked   → seo-audit shows 9 uses across 4 projects again
```

No reindex runs in either direction (UIX-005, UIX-006, AC-014, AC-015).

### 9.8 Unsupported versus genuinely unused

```
Cursor  — unsupported (history found, no reliable activation signal)
Kiro    — no history found
Claude  — included, 541 sessions, 7 954 events
```

A skill at zero under an `unsupported` source is not evidence of disuse; the UI must let the user tell
those apart (SEM-005, AC-011).

### 9.9 Failed migration

```
Launch → user_version 1 → build usage.sqlite.migrating → cancelled at 60%
Result → temporary file deleted, usage.sqlite untouched, old counts still shown,
         Usage tab reports the interrupted rebuild
```

(DAT-004, AC-021.)

### 9.10 Corrupted tail

A history file whose last line is a partial JSON object: every complete preceding record is indexed, the
partial line is skipped, and the next pass re-reads the file because its size and mtime changed (REQ-010,
AC-025).

## 10. Validation Criteria

The change is compliant when all of the following hold:

1. The capability matrix (§4.1) is complete and committed, with no "to audit" entries (AC-001).
2. The audit provably wrote nothing (AC-002).
3. Claude counts meet or exceed the reference snapshot, with any delta explained (AC-003, AC-004).
4. Every supported adapter has positive and negative anonymized fixtures, and no fixture contains real
   user content (AC-012, SEC-001).
5. Paseo-originated Codex sessions are counted exactly once, with `surface = "paseo"` (AC-008, AC-009,
   AC-010).
6. Unsupported sources are labelled as such and contribute nothing silently (AC-011, AC-018).
7. Unchecking an assistant in Settings › Assistants removes it from both the list and the counts, and
   re-checking restores the counts exactly, without a reindex (AC-014, AC-015).
8. The Assistants tab copy states that hiding also affects counts (AC-016).
9. The Usage tab reports one row per source with status, session count and event count, and no longer
   claims a Claude-only index (AC-017).
10. Every nonzero count can be explained event by event with assistant, timestamp, project and session or
    source file (AC-019).
11. Migration builds aside and swaps atomically; interruption leaves the previous index intact and usable
    (AC-020, AC-021, AC-022).
12. Incremental skipping, window widening and parser-version invalidation all behave as specified
    (AC-023, AC-024, AC-026).
13. Malformed, truncated and unreadable inputs degrade gracefully (AC-025, AC-027).
14. The UI stays responsive during a full reindex and no index read runs on the main thread, with
    measurements recorded (AC-028, AC-029).
15. `swift test` passes in full and the release build's self-check reports no new failure (AC-030, AC-031).
16. No commit for this feature contains the pending performance changes to `AppModel.swift`,
    `DetailView.swift`, `MarkdownView.swift` or `TickRail.swift` (CON-001).

## 11. Related Specifications / Further Reading

- `docs/AUDIT-USAGE-SOURCES.md` — the completed Phase 1 audit: every format, every measurement, and the
  four deltas that produced version 1.1 of this specification.
- `docs/HANDOFF-USAGE-INDEX.md` — the diagnosis, measurements and phased plan this specification formalizes.
- `Sources/LoadoutCore/UsageIndex.swift` — current single-source index, parser and SQLite schema version 1.
- `Sources/LoadoutCore/Assistants.swift` — assistant discovery and `AssistantRegistry.known`.
- `Sources/LoadoutCore/Paths.swift` — every path the app touches, including `transcripts` and `index`.
- `Sources/LoadoutApp/SettingsView.swift` — the Usage and Assistants tabs whose copy and rows change here.
- `Sources/LoadoutApp/AppModel.swift` — `hiddenAssistantIDs` persistence and the usage refresh path.
- `Tests/LoadoutCoreTests/UsageTests.swift`, `Fixture.swift` — the existing test and fixture patterns to extend.
- Apple Style Guide (June 2025) — the conventions UI copy in this feature follows (UIX-013).
