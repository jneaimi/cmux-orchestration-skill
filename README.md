# cmux Orchestration Skill for Claude Code

A Claude Code skill (`/cmux`) that turns [cmux](https://github.com/manaflow-ai/cmux) into a
multi-agent orchestration surface: spawn **Claude Code**, **OpenAI Codex CLI**, and **xAI Grok
Build** agents in split panes, dispatch self-contained blueprint prompts, detect completion via
cmux events, and collect results — all driven from your main Claude Code session.

Everything in this skill was validated live (versions pinned in the skill body) and includes the
hard-won gotchas you'd otherwise rediscover the slow way: send-length truncation, alternate-screen
scrollback loss, sandbox-vs-verdict-file conflicts, worktree `.git` write failures, MCP startup
stalls, and per-runtime completion markers.

## What's in the box

- **Three agent runtimes** — launch flags, sandbox/safety defaults, trust-prompt handling, model
  overrides, and screen "working"/"done" markers for `claude`, `codex`, and `grok` panes.
- **Provider strategy selection** — a capability-routing table (which model family gets which
  kind of work) plus five orchestration strategies, from the default capability-routed pipeline
  to tournaments and cost-tiering. Core invariant: *the author's model family never validates
  its own branch* — cross-family review caught a real defect in every round of a five-wave
  production build.
- **Dispatch workflows** — `/cmux run`, `/cmux multi`, `/cmux collect`, `/cmux close`, with
  mandatory blueprint-prompt engineering rules (agents start with zero context; every prompt
  file is a self-contained spec).
- **Event-driven completion detection** — `cmux events` subscription, per-pane `surface_id`
  matching, and the runtime-specific fallbacks for when events lie or don't fire.
- **Workflow templates** — parallel review, cross-model review (Claude × Codex × Grok panel),
  debug, dev-server + browser pane, feature scaffolding, parallel test writing.
- **Browser automation basics** — snapshot/click/fill/eval with the verify-retry loop.
- **Notification hook** — `hooks/cmux-notify.sh` pings you via cmux when a session finishes,
  needs attention, or completes an agent task.

## Requirements

- macOS with [cmux](https://github.com/manaflow-ai/cmux) installed:
  `brew tap manaflow-ai/cmux && brew install --cask cmux`
- The official cmux skill pack (this skill layers on top of it):
  `npx skills add manaflow-ai/cmux-skills -g`
- `jq` (`brew install jq`)
- Optional runtimes: [Codex CLI](https://github.com/openai/codex) (`brew install codex`) and
  Grok Build (bundled with cmux at `/Applications/cmux.app/Contents/Resources/bin/grok`)

Validated against: cmux 0.64.17 · codex-cli 0.144.1 · grok (Grok Build) 0.2.99 · Claude Code 2.x.

## Install

```bash
git clone https://github.com/jneaimi/cmux-orchestration-skill.git
mkdir -p ~/.claude/skills/cmux
cp cmux-orchestration-skill/skills/cmux/SKILL.md ~/.claude/skills/cmux/

# Optional: the notification hook
cp cmux-orchestration-skill/hooks/cmux-notify.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/cmux-notify.sh
# then merge hooks/settings-hooks.example.json into ~/.claude/settings.json
```

Then in Claude Code, run `/cmux setup` to verify and wire up the runtimes
(`cmux hooks setup codex -y`, `cmux hooks setup grok -y`).

## Usage

```
/cmux setup                      # verify install + wire runtime hooks
/cmux run codex:"task A" claude:"task B" grok:"task C"
/cmux review --cross             # cross-model review panel
/cmux dev http://localhost:5173  # dev server + live browser pane
/cmux collect                    # read results from agent panes
/cmux close                      # tear down
```

The skill instructs Claude to write each agent a self-contained blueprint prompt file and show
it to you before dispatch — review those; they're where orchestration succeeds or fails.

## Credits

- [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — the terminal this orchestrates.
- The official `cmux-skills` pack — canonical CLI/browser/config reference this skill defers to.

## License

MIT
