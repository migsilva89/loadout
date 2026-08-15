#!/bin/bash
# Records the README's animation by driving the real app, and turns it into a GIF.
#
#   ./Scripts/make-gif.sh                 a longa, com tudo: browse, toggle, share, ask
#   ./Scripts/make-gif.sh browse          só a lista e o que cada coisa é
#   ./Scripts/make-gif.sh toggle          desligar e voltar a ligar uma skill
#   ./Scripts/make-gif.sh share           pôr a mesma skill noutro assistente
#   ./Scripts/make-gif.sh ask             a conversa e a alteração proposta
#
# As curtas servem para um site, onde cada uma explica uma coisa só. A longa é a do README.
#
# No screen recording is involved, and none is possible from a script: capturing the *screen* needs
# a permission a headless run has no way to be granted. Instead the app draws its own window to a
# PNG on a timer — `LOADOUT_RECORD` — which needs no permission at all, because the window already
# belongs to the process drawing it.
#
# Everything in the picture is real. A throwaway home with one skill in it, a real conversation with
# the real `claude`, and the change it actually proposed. Nothing here is staged, and it must stay
# that way: a picture of a program that does not exist is the most expensive lie a README can tell.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SCENE="${1:-all}"
OUT="${2:-.github/assets/loadout-$SCENE.gif}"
WIDTH="${GIF_WIDTH:-1400}"
CLI="${GIF_ASK:-claude}"
HOME_FIXTURE="$(mktemp -d)/home"
FRAMES="$(mktemp -d)/frames"
trap 'rm -rf "$HOME_FIXTURE" "$FRAMES"' EXIT

command -v ffmpeg >/dev/null || { echo "precisa de ffmpeg: brew install ffmpeg"; exit 1; }

# ---------------------------------------------------------------------- the fixture

# A believable machine rather than one skill in an empty window: the app is an inventory, and an
# inventory of one item shows nothing. The first skill is deliberately badly written — it is the one
# the assistant is asked to fix.

skill() {  # skill <name> <description> <body first line>
	mkdir -p "$HOME_FIXTURE/.claude/skills/$1"
	cat > "$HOME_FIXTURE/.claude/skills/$1/SKILL.md" <<SKILL
---
name: $1
description: $2
---

# $1

$3

## Steps

1. Check what you have before changing anything.
2. Do the smallest thing that works.
3. Say what changed, and what it cost.
SKILL
}

skill pdf-shrink "makes pdfs smaller" "Shrink a PDF that is too heavy to send."
skill release-notes "Use when the user asks to write release notes, a changelog entry, or \"what changed in this version\"." "Turn a range of commits into notes a person can read."
skill db-migrate "Use when adding, changing or rolling back a database migration, or when a migration failed halfway." "Write and run migrations without losing data."
skill design-review "Use when reviewing a screen, a component or a mockup against the design system." "Read a screen the way a designer would."
skill api-contract "Use when defining or changing an HTTP endpoint, its payloads, or its error shapes." "Keep an API contract honest and documented."
skill test-triage "Use when a test suite fails and it is not obvious which failure caused the others." "Sort a wall of red into one cause and its echoes."
skill perf-budget "Use when a page got slower, or before shipping a change that adds weight to one." "Measure first, then decide what to cut."
skill incident-notes "Use when something broke in production and the timeline has to be written down while it is fresh." "Write the record while people still remember."
skill copy-review "Use when reviewing user-facing text — buttons, errors, onboarding, release notes." "Read the words a user actually meets."
skill sql-explain "Use when a query is slow and the plan needs reading before anything is indexed." "Read the plan before touching an index."
skill a11y-audit "Use when checking a screen for keyboard traps, contrast, focus order or missing labels." "Go through the screen the way someone who cannot see it does."
skill repo-onboard "Use when landing in an unfamiliar repository and needing the shape of it before touching anything." "Explain a codebase to the person who just arrived."

# The two below live in Codex rather than in Claude, and one of them in both: the dots on the row
# are only worth showing on a machine where the assistants really do hold different things.
codex_skill() {  # codex_skill <name> <description>
	mkdir -p "$HOME_FIXTURE/.codex/skills/$1"
	cat > "$HOME_FIXTURE/.codex/skills/$1/SKILL.md" <<CSKILL
---
name: $1
description: $2
---

# $1

$2
CSKILL
}
codex_skill commit-message "Use when writing a commit message for a change that is already staged."
codex_skill flaky-hunt "Use when a test passes locally and fails in CI, or fails one run in ten."

# One skill both assistants load, the way the app writes it: the real folder in ~/.agents/skills,
# a symlink in each assistant.
mkdir -p "$HOME_FIXTURE/.agents/skills"
mv "$HOME_FIXTURE/.claude/skills/repo-onboard" "$HOME_FIXTURE/.agents/skills/repo-onboard"
ln -s "$HOME_FIXTURE/.agents/skills/repo-onboard" "$HOME_FIXTURE/.claude/skills/repo-onboard"
mkdir -p "$HOME_FIXTURE/.codex/skills"
ln -s "$HOME_FIXTURE/.agents/skills/repo-onboard" "$HOME_FIXTURE/.codex/skills/repo-onboard"

mkdir -p "$HOME_FIXTURE/.claude/commands" "$HOME_FIXTURE/.claude/agents" "$HOME_FIXTURE/.codex/prompts"

command_file() {  # command_file <name> <description> <body>
	cat > "$HOME_FIXTURE/.claude/commands/$1.md" <<CMD
---
description: $2
---

$3
CMD
}
command_file standup "Turn today's commits and open PRs into three lines for standup." "Summarise what I did since yesterday, what I am on now, and what is blocking me."
command_file ship "Run the tests, tag a version, and build the release." "Refuse if the tree is dirty or the branch is not main."
command_file review "Read the working tree for bugs, and say nothing about formatting." "Report each finding with the file and the line."
command_file changelog "Write the changelog entry for what is on this branch." "Group by what a reader would look for, not by commit."
command_file scaffold "Create a component, its test and its story from one name." "Follow whatever the neighbouring files already do."
command_file explain "Explain the selected code to someone who has never seen this repository." "Say what it is for before saying how it works."

cat > "$HOME_FIXTURE/.codex/prompts/handoff.md" <<'CMD'
---
description: Hand the current task to another agent with everything it needs to continue.
---

Say what is done, what is left, and what was decided along the way.
CMD

agent_file() {  # agent_file <name> <description> <body>
	cat > "$HOME_FIXTURE/.claude/agents/$1.md" <<AGENT
---
name: $1
description: $2
---

$3
AGENT
}
agent_file reviewer "Reads a diff for correctness before it is merged, and says nothing about style." "Look for the bug, not for the formatting."
agent_file explorer "Searches a codebase to answer a question, and reports the answer rather than the files." "Read what is needed and no more."
agent_file planner "Turns a task into a plan with the risky part named first." "A plan that hides the hard part is not a plan."
agent_file docs-writer "Writes the documentation for a change that already works." "Write for the person who arrives after you."

# MCP servers live inside ~/.claude.json rather than in files of their own.
cat > "$HOME_FIXTURE/.claude.json" <<'MCP'
{
  "numStartups": 214,
  "mcpServers": {
    "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] },
    "postgres": { "command": "npx", "args": ["@modelcontextprotocol/server-postgres"] },
    "linear": { "url": "https://mcp.linear.app/sse" },
    "notion": { "url": "https://mcp.notion.com/mcp" }
  }
}
MCP

# A plugin, because trimming one is the thing the app learned to do that nothing else does — and an
# inventory with no plugin in it cannot show the tag, the per-skill switch, or the plugin's own page.
PLUGIN="$HOME_FIXTURE/.claude/plugins/cache/official/vercel/0.45.1"
plugin_skill() {  # plugin_skill <name> <description>
	mkdir -p "$PLUGIN/skills/$1"
	cat > "$PLUGIN/skills/$1/SKILL.md" <<PSKILL
---
name: $1
description: $2
---

# $1

$2
PSKILL
}
plugin_skill vercel-functions "Use when configuring, debugging or optimizing server-side code running on Vercel."
plugin_skill vercel-cli "Use when deploying, managing environment variables, or reading logs from the command line."
plugin_skill nextjs "Use when building or debugging a Next.js app — routing, Server Components, caching, rendering."
mkdir -p "$PLUGIN/commands" "$PLUGIN/agents"
cat > "$PLUGIN/commands/deploy.md" <<'PCMD'
---
description: Deploy the current project. Pass "prod" to promote it to production.
---

Deploy, then report the preview URL.
PCMD
cat > "$PLUGIN/agents/deployment-expert.md" <<'PAGENT'
---
name: deployment-expert
description: Reads a failing deployment and says what to change, from the build log up.
---

Start at the first error, not the last.
PAGENT
cat > "$HOME_FIXTURE/.claude/plugins/installed_plugins.json" <<PLUGINS
{"version":2,"plugins":{"vercel@official":[{"scope":"user","installPath":"$PLUGIN","version":"0.45.1"}]}}
PLUGINS

# A used machine, not a fresh one: the counts, the "last used" dates and the ordering are read from
# session logs, so a fixture with none of them shows an inventory nobody has ever touched. These are
# written in the exact shape Claude Code writes, and counted by the same indexer as the real ones —
# the numbers in the picture are not typed in anywhere.
LOGS="$HOME_FIXTURE/.claude/projects"
log_line() {  # log_line <project> <days-ago> <json-body>
	local stamp
	stamp="$(date -u -v-"$2"d +%Y-%m-%dT%H:%M:%SZ)"
	mkdir -p "$LOGS/-Users-me-$1"
	echo "$3" | sed "s/@STAMP@/$stamp/;s|@CWD@|/Users/me/$1|" >> "$LOGS/-Users-me-$1/session.jsonl"
}
use_skill() {  # use_skill <name> <project> <days-ago> <times>
	local i
	for ((i = 0; i < $4; i++)); do
		log_line "$2" "$3" "{\"type\":\"assistant\",\"timestamp\":\"@STAMP@\",\"cwd\":\"@CWD@\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Skill\",\"input\":{\"skill\":\"$1\"}}]}}"
	done
}
use_command() {  # use_command <name> <project> <days-ago> <times>
	local i
	for ((i = 0; i < $4; i++)); do
		log_line "$2" "$3" "{\"type\":\"user\",\"timestamp\":\"@STAMP@\",\"cwd\":\"@CWD@\",\"message\":{\"content\":\"<command-name>/$1</command-name>\"}}"
	done
}
use_agent() {  # use_agent <name> <project> <days-ago> <times>
	local i
	for ((i = 0; i < $4; i++)); do
		log_line "$2" "$3" "{\"type\":\"assistant\",\"timestamp\":\"@STAMP@\",\"cwd\":\"@CWD@\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Agent\",\"input\":{\"subagent_type\":\"$1\"}}]}}"
	done
}
use_mcp() {  # use_mcp <server> <project> <days-ago> <times>
	local i
	for ((i = 0; i < $4; i++)); do
		log_line "$2" "$3" "{\"type\":\"assistant\",\"timestamp\":\"@STAMP@\",\"cwd\":\"@CWD@\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"mcp__$1__do_thing\",\"input\":{}}]}}"
	done
}

# The one the assistant is asked to rewrite is the one that fires most: a description nobody wrote
# properly, on the skill everybody reaches for, is the ordinary case rather than the odd one.
use_skill pdf-shrink checkout 1 9
use_skill pdf-shrink billing 4 5
use_skill release-notes checkout 2 7
use_skill db-migrate billing 3 6
use_skill design-review website 5 4
use_skill api-contract checkout 6 4
use_skill test-triage billing 2 3
use_skill repo-onboard website 8 3
use_skill sql-explain billing 11 2
use_skill perf-budget website 14 2
use_skill copy-review website 21 1

use_command standup checkout 1 12
use_command review checkout 2 8
use_command ship billing 3 5
use_command changelog checkout 9 3
use_command explain website 16 2

use_agent reviewer checkout 1 6
use_agent explorer billing 2 5
use_agent planner website 7 3

use_mcp playwright website 1 11
use_mcp postgres billing 2 7
use_mcp linear checkout 4 4

echo "→ A construir a app"
swift build -c debug --product LoadoutApp >/dev/null

# ------------------------------------------------------------------- the recording
#
# LOADOUT_ASK_NEW starts a fresh conversation: without it the panel resumes whatever was said last
# time and the assistant answers a question nobody watching has seen.
# "Reply in English" is there because the CLI reads the machine's own instructions, which may ask
# for another language — and a README in English with a reply in Portuguese reads as a mistake.

# The conversation panel is only opened for the scenes that are about it. Left open elsewhere it
# takes a third of the window to say nothing, which is exactly how a demo starts looking padded.
ASK_ENV=("LOADOUT_SCENE=$SCENE")
case "$SCENE" in
	ask|all)
		ASK_ENV=(
			"LOADOUT_ASK=$CLI"
			"LOADOUT_ASK_NEW=1"
			"LOADOUT_ASK_MESSAGE=Rewrite the description so it says when to use this skill, with real trigger phrases. Reply in English."
		)
		;;
esac

echo "→ A gravar a cena \"$SCENE\""
env \
	LOADOUT_HOME="$HOME_FIXTURE" \
	LOADOUT_TAB=skills \
	LOADOUT_RECORD="$FRAMES" \
	LOADOUT_WINDOW="${GIF_WINDOW:-1900x1150}" \
	"${ASK_ENV[@]}" \
	.build/debug/LoadoutApp | tail -3

COUNT="$(find "$FRAMES" -name 'frame-*.png' | wc -l | tr -d ' ')"
[ "$COUNT" -gt 20 ] || { echo "só $COUNT fotogramas — alguma coisa correu mal"; exit 1; }
echo "→ $COUNT fotogramas"

# ------------------------------------------------------------------------- the gif
#
# Per-frame durations rather than one frame rate: the answer being written is worth skimming, and
# the undecided change — the one moment the whole feature exists for — is worth stopping on. The
# last frame holds too, so a looping GIF rests on the result instead of snapping back.

python3 Scripts/frame-timing.py "$FRAMES"

# Two passes with a shared palette. One palette per frame turns a dark interface to mud.
echo "→ A montar o GIF"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$FRAMES/list.txt" \
	-vf "scale=$WIDTH:-1:flags=lanczos,palettegen=stats_mode=diff" "$FRAMES/palette.png"

ffmpeg -loglevel error -y -f concat -safe 0 -i "$FRAMES/list.txt" -i "$FRAMES/palette.png" \
	-lavfi "scale=$WIDTH:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
	-loop 0 "$ROOT/$OUT"

SIZE="$(du -h "$ROOT/$OUT" | cut -f1)"
echo "✓ $OUT ($SIZE)"

if [ "$(du -k "$ROOT/$OUT" | cut -f1)" -gt 10240 ]; then
	cat <<'WARN'

  Passou dos 10 MB. O GitHub aceita, mas quem abre o README no telemóvel paga-o.
  GIF_WIDTH=1000 ./Scripts/make-gif.sh
WARN
fi
