# Audit — assistant history sources (Phase 1, read-only)

Run on 2026-08-13 against this machine. Satisfies AUD-001 … AUD-010 of
`spec/spec-architecture-multi-assistant-usage-index.md`.

Nothing was written. No history file was opened for writing, no preference changed, and
`~/.claude/.loadout/usage.sqlite` still carries its pre-audit modification time of 17:20 while the audit
ran from 20:05 onwards (AC-002).

All counts below were measured, not estimated. Paths are given relative to the home directory. No prompt
text, repository name or session identifier from this machine appears in this document (SEC-001).

## 1. Reference snapshot, re-measured

| Measure | Handoff snapshot | Re-measured 2026-08-13 |
| --- | --- | --- |
| Indexed transcript files | 541 | 541 |
| Total events | 7 954 | 7 974 |
| Claude skill activations | 174 | 174 |
| Distinct skill names | 38 | 38 |
| Raw `"name":"Skill"` grep over `~/.claude/projects` | 174 | 174 |

The index and the raw grep still agree exactly. The Claude parser is not losing explicit activations; the
undercount is entirely a matter of excluded sources and of activation semantics (AC-003, AC-004 baseline).

## 2. Assistants found on this machine

Directories holding skills:

| Directory | Skills | Discovered by Loadout today |
| --- | --- | --- |
| `.agents/skills` | 15 | no — shared store, correctly excluded |
| `.claude/skills` | 14 | yes |
| `.codex/skills` | 7 | yes |
| `.commandcode/skills` | 0 | yes (empty) |
| `.factory/skills` | 0 | yes (empty) |
| `.hermes/skills` | 0 | yes (empty) |
| `.kiro/skills` | 0 | yes (empty) |
| `.opencode/skills` | 0 | yes (empty) |
| `.trae/skills` | 0 | yes (empty) |

Two assistants keep skills where Loadout does not look, so they are invisible today:

- **Pi** — skills live at `.pi/agent/skills`, not `.pi/skills`.
- **Cursor** — skills live at `.cursor/skills-cursor`, not `.cursor/skills`.

`AssistantRegistry.discover` builds its root as `~/.<id>/skills`, so neither is found (AUD-008 confirmed:
absence of `~/.<id>/skills` does not mean absence of the assistant).

## 3. Capability matrix

| Assistant | History root | Files | Format | Timestamp | Project | Session id | Surface | Activation evidence | Parser feasible | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | `.claude/projects` | 1 408 (541 `.jsonl`) | JSONL, one record per line | `timestamp`, ISO-8601 UTC | `cwd` | per-record, present | — | `tool_use` named `Skill` with `input.skill`; `input.subagent_type`; `mcp__*` names; `<command-name>` | yes, in production | **supported** |
| claude | `.claude/sessions` | 13 `.json` | one object per live process: `pid`, `sessionId`, `cwd`, `startedAt`, `entrypoint` | `startedAt` epoch ms | `cwd` | `sessionId` | `entrypoint` | none — holds no messages | n/a | **not a source** (useful only as a `sessionId → cwd` map) |
| codex | `.codex/sessions` | 107 `.jsonl` | JSONL; `session_meta`, `turn_context`, `response_item`, `event_msg`, `world_state` | top-level `timestamp`, ISO-8601 UTC | `payload.cwd` in `session_meta` | `payload.session_id` | `payload.originator`, `payload.source`, `payload.thread_source` | canonical full read of `…/skills/<name>/SKILL.md` by a tool call — see §4 | yes | **supported, with the caveat in §4** |
| codex | `.codex/archived_sessions` | 39 `.jsonl` | identical to above | same | same | same | same | same | yes | **supported** |
| paseo | `.paseo/agents` | 178 `.json` | one object per agent: `provider`, `cwd`, `createdAt`, `runtimeInfo.sessionId`, `persistence.sessionId` | `createdAt` / `lastActivityAt` ISO-8601 | `cwd` | **`persistence.sessionId` = the provider's own session id** | `provider` | none — holds no messages | n/a (join table) | **not a source; exact attribution key — see §5** |
| paseo | `.paseo/projects` | 4 `.json` | workspace and project metadata | — | — | — | — | none | no | **not a source** (handoff's suspicion confirmed) |
| cursor | `.cursor/projects/*/agent-transcripts/*/*.jsonl` | 10 `.jsonl` | JSONL, Claude-like: `{role, message:{content:[…]}}` | **none — no timestamp field at all** | directory slug of `cwd` | directory uuid | — | none found: tools are `Read`, `Grep`, `StrReplace`, `Glob`, `Shell`, `Write`, `ApplyPatch`, `SemanticSearch`, `ReadLints`; no skill tool, no `SKILL.md` read | partially | **unsupported — see §6** |
| cursor | `.cursor/projects/**` (rest) | 13 772 | MCP caches: `SERVER_METADATA.json`, `mcp-cache.json`, `STATUS.md`, `INSTRUCTIONS.md`, per-tool JSON | — | — | — | — | none | no | **not a source** |
| cursor | `Library/Application Support/Cursor/User/{global,workspace}Storage` | 118 workspaces + `state.vscdb`, `conversation-search.db` | SQLite (VS Code state store, opaque blobs) | inside blobs | — | — | — | not investigated further | high risk | **out of scope for v1** |
| opencode | `.local/share/opencode/storage` | 5 555 `.json` across `session/`, `message/`, `part/` | one JSON file per session, message and part | on `message` records | `session` records | `sessionID` on every part | — | none: tools are `read`, `edit`, `bash`, `grep`, `glob`, `todowrite`, `write`, `list`, `task`, `webfetch`; zero `SKILL.md` references in 4 419 tool parts | yes, mechanically | **unsupported for skills** (no skill mechanism, and `.opencode/skills` is empty) |
| opencode | `.opencode` | 3 428 | `bin`, `node_modules`, empty `skills` | — | — | — | — | none | no | **not a source** |
| pi | `.pi/agent/sessions` | 1 `.jsonl` | JSONL: `session`, `message`, `model_change`, `thinking_level_change` | top-level `timestamp` ISO-8601 | `cwd` on the `session` record | `id` on the `session` record | — | none observed; the single session holds 2 messages and no tool use | yes, mechanically | **no history worth counting** |
| commandcode, factory, hermes, kiro, trae, windsurf, gemini, copilot | — | — | no session/transcript directory found | — | — | — | — | none | no | **no history found** |

`.pi/agent` and `.opencode` contain thousands of files, but they are `node_modules` and package trees, not
history. Counting files at the directory root is misleading; the table gives the real history counts.

## 4. Codex: what can and cannot be proven

Codex has **no skill tool**. Every tool call across 146 session files is one of `exec_command` (1 766),
`exec` (385), `write_stdin` (222), `apply_patch` (99), `js` (48) and a tail of MCP and plugin functions.
A skill is therefore activated by the agent reading its `SKILL.md`, which is exactly the ambiguous signal
the spec warned about (CON-004).

The measurements that matter:

| Signal | Count | Distinct skills |
| --- | --- | --- |
| Sessions whose text mentions `SKILL.md` anywhere | 145 of 146 | — |
| Skills merely named in message text (the catalogue in the prompt) | — | 78 |
| Skill `SKILL.md` reads performed by an actual tool call | 333 | 32 |
| …of those, a **canonical full read** (`sed -n`, `cat`, `head`, `less`) | 277 | 30 |
| …of those, a search or write touching the path (`rg`, `grep`, `ls`, `find`, `apply_patch`, redirection) | 31 | 0 exclusive |
| …unclassified command shapes | 25 | — |
| Reads whose skill name appears literally in the preceding `agent_message` | 49 of 333 | — |

Two conclusions follow, and one of them contradicts the spec as written.

**The mention/read separation is strong.** 78 skills are named in message text purely because the skills
catalogue sits in the prompt — 113 sessions name `find-skills`, `create-specification` and `skill-creator`
identically, which is the signature of a catalogue, not of use. Only 30 skills are ever read by a tool
call. Counting mentions would inflate the numbers roughly two and a half times over, exactly as SEM-002
predicted.

**Requiring an announcement is not viable.** Only 49 of 333 reads (15%) have the skill's name literally in
the preceding `agent_message`. The announcements are real but paraphrase: one observed message says it will
follow "o guia de troubleshooting do projeto" and then reads `om-troubleshooter/SKILL.md`. A literal-name
requirement would discard 85% of genuine activations, so the composite evidence SEM-004 anticipated cannot
be built from a literal match. The observed shape is reliable in sequence, though: `reasoning` →
`agent_message` stating an intent → tool call reading that skill's `SKILL.md`, all in one turn.

**Recommendation, and it needs your decision.** Accept as Codex activation evidence: *a tool call whose
command performs a canonical full read (`sed -n`, `cat`, `head`, `less`) of a path matching
`**/skills/<name>/SKILL.md`*, and reject any command that only searches, lists or writes that path. On this
machine that yields 277 events across 30 skills, and the search/write exclusion removes 31 reads without
losing a single skill name — every name reached by a search was also reached by a canonical read.

This is weaker than Claude's `tool_use Skill`, and it conflicts with CON-004 as literally written. The
honest options are in §8.

## 5. Paseo: an exact attribution key, and it is not Codex-only

`.paseo/agents/**/*.json` holds one metadata object per agent, with no messages. It carries:

```json
{
  "provider": "codex",
  "cwd": "<workspace path>",
  "createdAt": "<ISO-8601>",
  "runtimeInfo":  { "provider": "codex", "sessionId": "<provider session id>" },
  "persistence":  { "provider": "codex", "sessionId": "<provider session id>",
                    "nativeHandle": "<provider session id>" }
}
```

`persistence.sessionId` is the **provider's own session identifier** — the same id that appears as
`payload.session_id` in a Codex session file. Attribution is therefore an exact join, not a heuristic:

```
surface = "paseo"  ⟺  event.sessionID ∈ { persistence.sessionId of every .paseo/agents record }
```

Two corrections to the handoff's assumptions:

1. **Paseo hosts Claude as well as Codex.** Of 178 agent records, **135 are `provider: "claude"`** and 41
   are `provider: "codex"`. So Paseo is a surface over both, and a Paseo-hosted Claude session already sits
   inside the 174 events counted today. Attributing it costs nothing and changes no count.
2. **The Codex `originator` field never says "paseo".** Observed values are `codex_cli_rs` (74),
   `codex-tui` (31), `codex_exec` (18), `Codex Desktop` (11) and `Claude Code` (11), with `source` values
   `vscode`, `cli`, `exec` and `{"subagent": …}`, and `thread_source` of `user` or `subagent`. Paseo
   attribution must come from the join in this section, not from `originator` (AUD-006 answered, with a
   different answer than expected).

`originator: "Claude Code"` on 11 Codex sessions is worth noting separately: Claude Code delegating to
Codex produces a Codex session. Under the join rule that session is attributed to Codex, with its surface
resolved from `originator`, and it is parsed exactly once — so no duplication arises (REQ-005, AC-009).

## 6. Cursor: parseable shape, unusable content

Cursor's real transcripts were found, and they are not where the handoff looked. `.cursor/projects` is
mostly MCP cache; the transcripts sit at
`.cursor/projects/<cwd-slug>/agent-transcripts/<uuid>/<uuid>.jsonl` — 10 files, in a Claude-like
`{role, message:{content:[…]}}` shape.

They cannot support a usage count in v1, for two independent reasons:

1. **No timestamps.** A record has exactly two keys, `role` and `message`. There is no per-record time, so
   events cannot be placed inside the 30/90/365-day window. File modification time would date a whole
   session, not an event, and would be wrong the moment a session is resumed.
2. **No skill signal.** Across all 10 transcripts the tools are `Read`, `Grep`, `StrReplace`, `Glob`,
   `Shell`, `ReadFile`, `Write`, `rg`, `AwaitShell`, `ApplyPatch`, `SemanticSearch` and `ReadLints`. There
   is no skill tool and not one `SKILL.md` read — consistent with Cursor keeping its skills in
   `skills-cursor`, which Loadout does not even list.

Decision: **unsupported**, shown as such (SEM-005, AC-011). Should Cursor ever be needed, `state.vscdb`
under `Library/Application Support/Cursor` is the deeper store, and it is an opaque VS Code state database —
a separate, higher-risk piece of work.

## 7. Deltas against the specification

The audit contradicts the spec in four places. Each needs a decision before Phase 2.

| # | Spec text | What the audit found | Proposed resolution |
| --- | --- | --- | --- |
| D-1 | **CON-004**: a read of `SKILL.md` shall not by itself constitute activation evidence | Codex has no other signal. A canonical full read is the activation mechanism; requiring a literal announcement loses 85% of real activations | Narrow CON-004: *an incidental* read (search, list, write, or a read that is not a canonical full read) is not evidence; a canonical full read by a tool call is, for Codex only, and it is labelled in the UI as inferred rather than explicit |
| D-2 | **REQ-005 / §9.4**: Paseo is a surface over Codex sessions | Paseo hosts Claude (135) more than Codex (41) | Generalize: Paseo is a surface over *any* provider session, resolved by joining `persistence.sessionId` |
| D-3 | **AUD-006 / §4.1**: resolve the Codex `session_meta` originator that identifies Paseo | No such value exists; `originator` names the Codex front end, never Paseo | Attribution comes from the Paseo join; `originator` maps instead to `codex-cli`, `codex-app`, `codex-exec`, `claude-code` surfaces |
| D-4 | **§4.1 / §9.8**: Cursor and Pi listed as candidate adapters | Cursor has no timestamps and no skill signal; Pi has one session with two messages, and neither assistant's skills directory is where Loadout looks | Ship neither adapter in v1. Fix the discovery roots for Pi (`.pi/agent/skills`) and Cursor (`.cursor/skills-cursor`) as separate, smaller work |

## 8. Recommendation for Phase 2

Ordered by value per unit of risk:

1. **Claude adapter, no behaviour change.** Move the existing parser behind `UsageSource`, prove 174/38
   unchanged. Zero product risk, and it establishes the contract.
2. **Paseo attribution.** A join table built from `.paseo/agents`, applied to Claude events immediately.
   It adds a `surface` to events already counted, so no number moves — the safest possible way to prove the
   surface concept.
3. **Codex adapter**, once D-1 is decided. 277 events across 30 skills on this machine, which is a 159%
   increase over the current 174 and the whole point of the feature.
4. **Nothing else in v1.** OpenCode, Pi and Cursor are registered as sources with honest states
   (`unsupported`, `noHistory`) so they are visible in the Usage tab and contribute nothing silently.

## 9. How every number here can be reproduced

Each measurement in this document came from a read-only pass over the histories: JSONL records parsed line
by line, record types counted, tool calls filtered by `payload.type` in
`{function_call, custom_tool_call, local_shell_call}`, and skill paths matched with
`/skills/<name>/SKILL.md`. The Claude baseline came from `sqlite3` `SELECT COUNT(*)` queries against the
existing index plus a `grep -ro '"name":"Skill"'` over `~/.claude/projects`. No command in the audit wrote
to any path.
