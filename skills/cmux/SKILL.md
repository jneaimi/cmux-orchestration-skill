# cmux Terminal Setup (/cmux)

Manage and configure cmux terminal workspaces for Claude Code projects. Orchestrate multi-agent
sessions (Claude Code, OpenAI Codex CLI, xAI Grok Build CLI, and Moonshot Kimi Code CLI), browser
panes, and workflow templates from the main Claude Code instance.

> **Layering with the official cmux skills** (installed via `npx skills add manaflow-ai/cmux-skills -g`):
> - `cmux-cli` — canonical CLI reference (command discovery, handles, sockets). Defer to it for raw CLI questions.
> - `cmux-workspace` — current-workspace targeting, helper-pane reuse, non-interfering automation.
> - `cmux-browser` — browser surface automation (snapshot refs, DOM actions, waits).
> - `cmux-config` — cmux.json settings.
>
> **This skill is the orchestration layer on top**: agent runtimes, dispatch workflows, completion
> detection, and workflow templates. Validated against: cmux 0.64.17, codex-cli 0.144.1,
> grok (Grok Build) 0.2.99, kimi-code 0.26.0, Claude Code 2.x.

## Commands

### /cmux setup — Initial setup
1. Verify cmux is installed: `which cmux`
2. If not installed, run: `brew tap manaflow-ai/cmux && brew install --cask cmux`
3. Verify cmux is reachable: `cmux ping`
4. Ensure hook script exists at `~/.claude/hooks/cmux-notify.sh` and is executable
5. Ensure `settings.json` has the cmux notification hooks configured
6. **Codex runtime**: verify `codex` is installed (`which codex`, `brew install codex` or `npm i -g @openai/codex`),
   logged in (`codex login status`), and hooked into cmux: `cmux hooks setup codex -y`
   (installs `~/.codex/hooks.json` so Codex panes emit cmux notification events on turn completion;
   Claude Code needs no hook — the cmux claude wrapper injects them automatically)
7. **Grok runtime**: verify `grok` is available (`which grok` — cmux BUNDLES it at
   `/Applications/cmux.app/Contents/Resources/bin/grok`, so it's usually already on PATH; otherwise
   install per https://x.ai/cli), logged in (`grok models` prints "You are logged in" + the model
   list; if not, `grok login`), and hooked into cmux: `cmux hooks setup grok -y` (installs
   `~/.grok/hooks/cmux-session.json` — a Notification hook for completion events + a PreToolUse
   Feed bridge)
8. **Kimi runtime**: verify `kimi` is installed (`which kimi`, `brew install kimi-code` — the
   current-gen single-binary CLI; the legacy Python `kimi-cli` brew formula is superseded, don't
   install it), logged in (`kimi login` — RFC 8628 device-code flow; URL + code print to STDERR,
   exit 0 on success / 1 on cancel or failure; needs the user's browser once), and wired for
   completion events MANUALLY — cmux's `hooks setup` does NOT support kimi (as of cmux 0.64.17),
   so add a `Stop` hook to `~/.kimi-code/config.toml` (see Completion detection below for the
   exact TOML). Then PROBE the wiring end-to-end (hooks are fail-open, so a broken hook drops
   events silently): start the events listener, run a one-turn kimi in a pane, and assert a
   `notification.requested` line lands in the events file
9. Confirm setup is complete

### /cmux status — Check cmux integration status
1. Run `cmux ping` to check if cmux is running
2. Run `cmux identify` to get current workspace/surface context
3. Verify hook script exists and is executable
4. Verify settings.json has hooks configured
5. Codex: `codex login status` + check `~/.codex/hooks.json` exists (cmux hooks wired)
6. Grok: `grok models` (login + model list in one call) + check `~/.grok/hooks/cmux-session.json`
   exists (cmux hooks wired)
7. Kimi: `kimi --version` + `kimi doctor` (config validity) + check `~/.kimi-code/config.toml`
   contains the cmux `Stop` hook (manual wiring — no `cmux hooks setup kimi`)
8. Report status of each component

### /cmux notify [message] — Send a manual notification
1. Run: `cmux notify --title "Claude Code" --body "[message]"`

### /cmux flash [surface] — Flash a pane for attention
Sends a blue border pulse to draw the user's eye to a specific pane.
```bash
cmux trigger-flash --surface surface:N
```

### /cmux progress [value] [label] — Update sidebar progress
Set or clear the sidebar progress bar for the current workspace.
```bash
# Set progress (0.0 to 1.0)
cmux set-progress 0.5 --label "Running tests..."
# Clear progress
cmux clear-progress
```

### /cmux sidebar [key] [value] — Set sidebar status
```bash
cmux set-status "branch" "main" --icon arrow.triangle.branch
cmux set-status "task" "Code review"
cmux clear-status "task"
```

---

## Agent Runtimes

Orchestrated panes can run any of the four runtimes. Default is `claude`; select per agent with
a `runtime:` prefix in `/cmux run` (e.g. `/cmux run codex:"task A" claude:"task B" grok:"task C"
kimi:"task D"`).

| | `claude` (default) | `codex` | `grok` | `kimi` |
|---|---|---|---|---|
| **Launch (autonomous)** | `claude --dangerously-skip-permissions` | `codex -s workspace-write -a never "<short prompt>"` | `grok --sandbox workspace --always-approve "<short prompt>"` | `kimi --auto` (auto-approves tools AND auto-handles questions — the unattended mode; `--yolo` approves tools but can still stall on AskUserQuestion) |
| **Full-bypass variant** | (same flag) | `--dangerously-bypass-approvals-and-sandbox` — ONLY on explicit user request; skips the OS sandbox | omit `--sandbox` (sandbox is OFF by default) + `--always-approve` — ONLY on explicit user request | n/a — kimi has NO OS sandbox at all; `--auto`/`--yolo` are already unsandboxed. Only run in trusted dirs/worktrees |
| **Initial prompt** | send after startup (`sleep 5` first) | pass as CLI argument at launch — no startup race, no send-truncation risk | pass as CLI argument at launch; it queues behind the startup directory dialog and runs right after dismissal | no CLI-arg prompt for interactive mode — launch, `sleep 5`, then send the pointer (claude-style). `-p "<prompt>"` exists but is headless-only and can't combine with `--auto`/`--yolo`/`--plan` |
| **Network in sandbox** | n/a | blocked by default in `workspace-write`; add `-c sandbox_workspace_write.network_access=true` for `npm install`-type tasks | ALLOWED in `workspace` profile. `read-only`/`strict` block child network on Linux only — it's a NO-OP on macOS | unrestricted (no sandbox) |
| **Read-only reviewer** | `claude --dangerously-skip-permissions` + review prompt | `codex review --base <branch>` or `codex review --uncommitted` — ALWAYS pass a scope flag (bare `codex review` hangs) | `grok --sandbox read-only --always-approve "<review prompt>"` (kernel-enforced read-only FS; no dedicated review subcommand) | `kimi --plan --auto -m kimi-code/k3` (pin the model — without `-m` the seat silently runs mid-tier K2.7). Plan mode prefers read-only tools but is SOFT (no kernel enforcement; Bash still allowed under regular rules). Weakest reviewer isolation of the four. NEVER `--plan --yolo` (stalls at plan-exit approval) |
| **Model override** | n/a (session model) | `-m <model>` (optional; defaults to `~/.codex/config.toml`) | `-m <model>` (`grok models` lists: `grok-4.5` default, `grok-composer-2.5-fast`); `--reasoning-effort <low\|medium\|high>` | `-m <alias>` — aliases are NAMESPACED as registered by login in `~/.kimi-code/config.toml` (verified live 2026-07-17): `kimi-code/kimi-for-coding` (K2.7 Code — DEFAULT, mid-tier), `kimi-code/k3` (the frontend champion; effort low/high/max, default max), `kimi-code/kimi-for-coding-highspeed`. Bare `-m k3` ERRORS ("not configured"). For frontend work you MUST `-m kimi-code/k3` — the default is not the model the hype is about |
| **Trust prompt** | non-git dirs only → send `1` + enter after 3s | pre-trusted via `[projects."<path>"] trust_level = "trusted"` in `~/.codex/config.toml` (`~/dev` already trusted); if it still appears, approve interactively once | "Run Grok Build in a project directory?" picker on launch → send `1` + enter after ~3s (option `3` = don't ask again, sticky) | none documented; first run needs one-time `kimi login` (device-code OAuth). Startup screens NOT yet live-validated — read-screen after launch before sending |
| **Completion signal** | cmux `notification.requested` event (automatic) | cmux `notification.requested` event (needs one-time `cmux hooks setup codex`) | cmux `notification.requested` event (needs one-time `cmux hooks setup grok`) — fires reliably but with `surface_id: null`, so per-pane matching is impossible; pair with read-screen | NOT supported by `cmux hooks setup` — wire manually: a `[[hooks]]` `Stop` entry in `~/.kimi-code/config.toml` calling `cmux notify` (TOML below). Attribution unvalidated — treat like grok: event = "some kimi turn ended", read-screen to attribute |
| **Screen "working" marker** | `✶ Misting…` (present-tense verb + elapsed time) | `Esc to interrupt` visible in footer | `◆ Thought for …` / `◆ Run …` activity lines streaming above the composer | not yet live-validated — identify empirically on first run (read-screen while it works) and update this row |
| **Screen "done" marker** | `✻ Crunched/Worked/Sautéed for …` + `❯` prompt | working marker gone, composer input box returned | `Worked for Xs.` line + empty `❯` composer box + status bar `Grok 4.5 (high) · always-approve` | not yet live-validated — expect idle composer; verify empirically and update this row |

**Codex safety default**: use `-s workspace-write -a never` (autonomy inside the OS sandbox), NOT
the dangerous-bypass flag. It is the Codex analogue of Claude's `--dangerously-skip-permissions`
but keeps filesystem/network sandboxing. Note: older docs/repos mention `--full-auto` — that flag
was removed; `-s workspace-write -a never` is the current form.

**Grok safety default**: use `--sandbox workspace --always-approve` (auto-approve inside a
kernel-enforced Seatbelt/Landlock sandbox: read everywhere, write CWD + `~/.grok/` + temp dirs,
network allowed — so `tsoul`/`gh`/`npm install` work without extra flags). Grok's sandbox is OFF
by default, so a bare `--always-approve` is the full-bypass form — don't use it unless the user
asks. `--permission-mode` (`default·acceptEdits·auto·dontAsk·bypassPermissions·plan`) is the
finer-grained alternative to `--always-approve`. Other orchestration-relevant flags: `--worktree
[name]` (launches in a NEW git worktree — grok can self-isolate parallel writers),
`--max-turns <N>`, `-p/--single` (headless one-shot; avoid for orchestration — use interactive
panes), `--json-schema` (structured output, headless only).

**Kimi safety default**: use `--auto` for orchestrated panes — it auto-approves tool calls AND
auto-handles `AskUserQuestion`, so an unattended pane never stalls. `--yolo` (short `-y`; hidden
aliases `--yes`, `--auto-approve`) skips approvals but the agent can still ask questions → stalls unattended;
the two flags are mutually exclusive. CRITICAL: kimi has **no OS sandbox** (unlike codex's
Seatbelt profile and grok's kernel sandbox). Hooks fail open on errors/timeouts, BUT a
`PreToolUse` hook that exits 2 (or returns `permissionDecision: "deny"`) DOES hard-block the
tool call — so a deny-list guard hook (block `git push`, `rm -rf`, writes outside the worktree)
is the available mitigation for the missing sandbox; treat it as belt-and-suspenders, not a
security boundary. Note kimi worktrees share the main repo's real `.git` and kimi CAN write it
(codex/grok are accidentally protected by their sandboxes here) — put explicit git prohibitions
in every kimi blueprint's Rules section. NEVER pair `--plan` with `--yolo`: plan-exit approval
is NOT bypassed by yolo, so the pane stalls; plan mode pairs with `--auto` only. Dispatch kimi
only into trusted directories, prefer a dedicated git worktree, and never hand it
secrets-bearing cwds. Other orchestration-relevant surface
(kimi-code 0.26.0): `--add-dir <dir>` (extra workspace roots), `--plan` (soft read-only planning
mode), session resume via explicit id `-r session_<id>` / `-S <id>` — NOT `-c/--continue`
("most recent session in cwd" is ambiguous when parallel panes + headless runs share a cwd, and
all kimi instances share `~/.kimi-code` sessions/credentials), and bare `-S` opens an
interactive picker (stalls unattended panes), `/goal` (TUI
autonomous goal loop across turns), `/swarm` + native `AgentSwarm` tool (template-driven fan-out
of up to 128 subagents, ramped concurrency, capped via `KIMI_CODE_AGENT_SWARM_MAX_CONCURRENCY` —
NOTE: swarm subagents share ONE working tree, no worktree isolation, so partition file ownership
in the template or keep swarms read-only/analysis-shaped), built-in subagents
(`coder`/`explore`/`plan`), `AGENTS.md` instruction files (global `~/.kimi-code/AGENTS.md`,
project `AGENTS.md`), `kimi doctor` (config validation). Auth: `kimi login` (device-code OAuth,
managed Kimi Code service) — API keys are NOT read from shell env; they must live in
`~/.kimi-code/config.toml` under `[providers.<name>]` (only the `KIMI_MODEL_*` env family is an
explicit exception).

**Kimi dispatch modes — pane vs headless vs YOLO (pick deliberately):**

| Mode | Invocation | When to use it |
|---|---|---|
| **cmux pane, unattended** (orchestration default) | `kimi --auto [-m kimi-code/k3]` in a split pane, then send the prompt-file pointer | Orchestrated builders: user can intervene in the pane, screen is readable, Stop-hook completion events fire, session resumable. `--auto` never stalls (auto-approves tools AND auto-answers questions) |
| **cmux pane, attended (YOLO)** | `kimi --yolo` (short `-y`) in a pane the user is watching | Semi-supervised sessions: skips tool approvals for speed, but the agent CAN still `AskUserQuestion` — the human answers, keeping design judgment in the loop. Never use for unattended panes (question = stall), and NEVER with `--plan` (plan-exit approval is not bypassed → stall). `--yolo` and `--auto` are mutually exclusive; both are toggleable mid-session via `/yolo` / `/auto`. A silent-decision caveat cuts the other way for `--auto`: it auto-answers every question, leaving no record of what was decided — front-load design decisions into the blueprint |
| **Headless one-shot** (from the orchestrator's own shell) | `kimi -p "<prompt>"` (± `-m kimi-code/k3`, `--output-format stream-json`) | Quick side-tasks WITHOUT burning a pane: scouting summaries, single-file generations, verdicts to parse. stream-json = one JSON per line on stdout; thinking is DROPPED in this mode (not redirected), tool progress goes to stderr. In default text mode, assistant text → stdout, thinking/progress → stderr. Validated live 2026-07-17 — kimi is the ONLY runtime safe to call headless (codex parks forever without a TTY; claude/grok headless modes are avoided by policy). `-p` implies auto-permission (static deny rules still apply); it REJECTS `--yolo`/`--auto`/`--plan`. Each run prints a `kimi -r session_<id>` resume hint — reuse it to continue the same context across one-shots |
| **Headless goal mode** | `kimi -p "/goal <objective with finish line + evidence>"` | Scriptable autonomous loop: exits `0` = goal complete, `3` = blocked, `6` = paused — branch on the exit code in orchestration scripts. Goal must name the finish line and its evidence, or it blocks immediately |

---

## Strategy selection — which provider gets which work (validated 2026-07-15; kimi added 2026-07-17)

Before dispatching multi-provider work, pick a strategy. Full evidence + benchmark table:
TeamSoul KB `knowledge/2026-07-15-multi-provider-agent-routing.md` (`tsoul vault get`).

**Capability profile (July 2026 — gpt-5.6-sol, grok-4.5, Fable 5/Opus 4.8, Kimi K3/K2.7):**

| Provider | Route TO it | Route AWAY from it |
|---|---|---|
| `claude` (Fable/Opus) | Shared-subsystem, convention-dense, long-horizon multi-file work; anything needing repo/skill/ADR context | High-volume mechanical bulk (expensive per token) |
| `codex` (gpt-5.6-sol) | First-class builder for well-specified, self-contained tasks (blueprint prompt); THE purpose-built reviewer (`codex review --base`) | Tasks needing deep repo-convention context it wasn't given |
| `grok` (grok-4.5) | Mechanical/high-volume work, test writing, terminal/CLI-flavored tasks (4.2× token efficiency, 80 TPS, TB 83.3%); read-only adversarial validation | Convention-dense server code (lowest SWE-bench Pro of the three) |
| `kimi` (`-m kimi-code/k3`; default K2.7) | Frontend/UI implementation — K3 is #1 on Arena.ai Frontend Code (Elo 1,679 > Fable 5's 1,631; #1 in 6/7 frontend domains, independent crowd-voted, Jul 2026). Cheap implementation lane (~$0.94/task ≈ ½ Opus; K2.7 $0.95/$4 per M) | Unattended long-horizon backend work (community: drifts, refactors what it shouldn't, has commented out failing tests instead of fixing); anything needing sandbox guarantees (NO OS sandbox); reviewer seats (weakest isolation). Default K2.7 is mid-tier (independent: rank 17/70 SWE-bench) — don't route hard cores to it |

**Kimi caveats (evidence freshness):** K3 launched 2026-07-16 — the Arena Elo is days old and
can drift; SWE/Terminal numbers for K3 are vendor-claimed only so far (TB 2.1 88.3 self-reported).
Community pattern that works: frontier model plans → kimi implements to a tight blueprint (its
weakness is judgment under vague prompts, not code generation). K3 needs a paid plan (Moderato+).

### Pick the tier — difficulty × use-case (don't default to high)

Provider (above) is only half the choice; the other half is **tier + effort**. Default to the
**cheapest tier that clears the bar** and escalate only on a trigger. Model/tier is the primary
cost lever; **reasoning-effort is a secondary dial** — in the observed builds it was left at sensible
defaults (Codex `medium`, Kimi `max`, Grok default) and the *tier*, not the dial, was moved.

**Escalate to a HIGH tier (Opus/Fable · sol-high · grok-4.5-high · k3-max) ONLY when any of:**
convention-dense / shared-subsystem code · needs repo+ADR+skill context · long-horizon multi-file ·
ambiguous / underspecified (judgment-heavy) · high-stakes / irreversible · on the critical shared
path · output is **not** verified downstream. **None of those → drop a tier.**

**Why cheap is safe — the review net licenses it.** Routing the easy ~70% to cheap/fast lanes is
safe *because* the author≠validator cross-family review (Strategy 1) sits under everything. Remove
the review and you must move every row up a tier. Reversibility + verified-downstream is the single
biggest "drop a tier" signal.

| Use-case | Difficulty signal | Provider · tier | Effort | Strategy |
|---|---|---|---|---|
| Convention-dense core / shared subsystem | repo+ADR context, long-horizon, critical path | **Claude Opus/Fable** | high | Claude owns it; cross-family review |
| Self-contained feature / migration (blueprint-able) | well-specified, disjoint | **Codex gpt-5.6-sol** | medium | single-builder + cross-family review |
| Mechanical sweep / codemod / boilerplate | high-volume, low-judgment | **Grok grok-4.5** → `grok-composer-2.5-fast` for pure bulk | low / default | Grok-native fan-out |
| Test / sad-path suites | verifiable downstream | **Grok grok-4.5** | default | capability-routed |
| Frontend / UI implementation | visual judgment | **Kimi `-m kimi-code/k3`** (pin it — default K2.7 is mid-tier) | max | trusted worktree only |
| Adversarial branch review | correctness · gates · races | **Codex `review --base`** + **Grok `--sandbox read-only`** | codex medium | cross-family; author family excluded |
| Safe validation on an untrusted tree | must not mutate | **Grok `--sandbox read-only`** (kernel-enforced) | default | validator (NOT Kimi — soft RO only) |
| Bulk scouting / research / inventory | parallelizable, verified downstream | `gpt-5.6-luna` · `grok-composer-2.5-fast` · cheap researcher subagent (`haiku`/`sonnet`) | low | cost-tier / background fan-out |
| "Give me different angles" / meta-analysis | wants diverse judgment | **Opus + Codex + Grok** in parallel | — | angle panel; convergence = confidence |
| Genuinely uncertain hard design | no clear best builder | all families, separate worktrees | high | tournament — reserve (expensive) |
| Fix round after request-changes | spec'd by the reviewer's findings | **same builder family as the branch** | as-builder | follow-up, no re-route |
| Long-horizon unattended backend | judgment under vague prompts | **Claude** (NOT Kimi/Grok — drift) | high | capability-routed |

**Effort dial (secondary):** bump `--reasoning-effort high` (grok) / a higher codex effort ONLY for
the hard core or the adversarial-verify pass on a subtle finding; drop to `low` for mechanical
sweeps on a capable model. Kimi K3 defaults to `max`; leave it.

**Probation lane:** a newly-released model with vendor-only benchmarks (e.g. K3 at launch) is routed
**conservatively** — narrow domain + an extra review check — until independently validated; record
the outcome + date in the KB routing note.

**Common over/under-provisioning traps** (from real runs): treating Codex as *only* a reviewer (it's
a first-class builder now, ~⅓ cost); treating Grok as "weak" (it's **mis-routed, not weak** — wrong
for convention-dense code, right for mechanical/test/CLI work); paying Fable-high rates on the easy
majority (that's what cost-tiering exists to stop); routing all Kimi work to the CLI default K2.7
(under-provisions frontend — pin `k3`).

**Strategies (pick per situation):**
1. **Capability-routed pipeline (DEFAULT):** route each task by the table above — frontend/UI
   slices now go to kimi with `-m kimi-code/k3`; every branch gets cross-family review (`codex review` + grok
   read-only + claude convention check). Invariant: the author's model family NEVER validates
   its own branch. Kimi branches especially need the sad-path review pass (check for disabled/
   commented-out tests — a reported failure mode).
2. **Fixed-role assembly line:** one builds / one tests / one validates. Predictable; wastes edges.
3. **Tournament:** the contenders implement the same hard design in separate worktrees; a judge
   panel picks the winner. Expensive — reserve for one-off uncertain design calls. For a
   design-heavy UI page, a claude × kimi-k3 two-way is the cheapest high-signal tournament.
4. **Native fan-out:** for big mechanical sweeps, ONE pane using the runtime's own orchestrator —
   grok's 8-subagent git-worktree fan-out, or kimi's `AgentSwarm` (up to 128 template-driven
   subagents, BUT one shared working tree: partition file ownership in the template, or keep
   swarms analysis/read-shaped). Other families review the reconciled result.
5. **Cost-tiering:** `-m gpt-5.6-luna` / `grok-composer-2.5-fast` / kimi default K2.7 for bulk
   scouting/boilerplate; sol/fable/k3 + high effort only for hard cores.

**Hard rules regardless of strategy:** one writer per git worktree; blueprint prompt files
(self-contained: context, spec, file ownership, edge cases, tests, rules); tsoul bookkeeping
(claim → build → handoff-to-review with PR + evidence) when the work is tracked in TeamSoul;
at most ONE grok pane and ONE kimi pane per workspace when relying on completion events (their
events can't be attributed per-pane — two same-runtime panes force read-screen polling of both);
kimi AgentSwarm runs emit ONE Stop event for the whole swarm (subagent completions fire
`Notification` hooks, not `Stop`) — don't read the events file as per-subagent progress; mind
account quotas when four providers fan out at once (kimi panes + headless `-p` runs share one
OAuth account; K3 is plan-gated).

**K3 routing re-validation trigger:** the frontend→K3 edge rests on a days-old crowd Elo that
measures single-shot output appeal, not blueprint-driven agentic delivery. Before K3 becomes
the standing default: re-check its Arena standing and run a claude × kimi-k3 tournament on 2-3
real repo frontend slices; record the outcome + date in the TeamSoul KB routing note. Also
benchmark `kimi-code/kimi-for-coding-highspeed` for the bulk/cost-tier lane (registered by
login but unrouted; speed/pricing profile unverified).

**Codex dispatch gotchas (verified live 2026-07-16, codex 0.144.1):**
- **Codex is TTY-only in practice.** Both `codex review` and `codex exec` piped from a
  background shell park forever (0 CPU, no sockets, no error). ALWAYS dispatch codex into a
  cmux pane; never a headless `Bash` call.
- **`codex review --base BRANCH "prompt"` errors** — `--base` and a positional prompt are
  mutually exclusive in this version. For a focused review brief, use interactive
  `codex -a never "read <prompt-file> and do it"` instead of the review subcommand.
- **MCP tool approvals stall panes — fix it in config, not per-run (verified live
  2026-07-20).** `-a never` covers shell/exec approvals ONLY; MCP tool calls prompt
  separately, and the default per-tool `approval_mode` (`auto`) prompts for ANY tool that
  doesn't declare `read_only_hint` — so an orchestrated pane hits "Allow the … MCP server to
  run tool X?" modals, and a `cmux send` into that modal can freeze the pane. Root-cause fix
  in `~/.codex/config.toml` per server (value names read BACKWARDS — `"approve"` =
  pre-approved/never asks; `"prompt"` = always asks; `"writes"` = asks unless
  read_only_hint):
  ```toml
  [mcp_servers.gitnexus]
  default_tools_approval_mode = "approve"  # never prompt for this server's tools
  tool_timeout_sec = 30                    # cut a hung MCP call instead of freezing the pane
  ```
  Per-run `-c mcp_servers={}` (disable all servers) remains the fallback for one-offs — but
  note the override can silently fail to parse through cmux-send quoting; config is reliable.
  Two residual noise sources: a NEVER-indexed repo still stalls gitnexus at startup
  (`gitnexus analyze <path>` once), and a STALE index returns "symbol not found" that sends
  the agent into re-query loops (reindex after merges). `gitnexus analyze` also writes
  onboarding files into the repo (`.gitignore` edit + AGENTS.md/CLAUDE.md/.claude/) — revert
  the tracked `.gitignore` change and ignore `.gitnexus/` via `.git/info/exclude` to keep the
  tree clean for orchestrated builders.
- **Reviewer sandbox vs verdict file:** codex `-s read-only` blocks ALL writes including /tmp,
  so a reviewer told to write a verdict file can't. Use `-s workspace-write -a never` launched
  from /tmp-adjacent cwd (its writable roots include /tmp + $TMPDIR) — the review prompt itself
  forbids repo edits. (Grok differs: its `--sandbox read-only` still allows /tmp + ~/.grok
  writes, so grok reviewers CAN write verdict files.) Codex TUI output survives scrollback, so
  `read-screen --scrollback` recovers a verdict when the file write was blocked.
- **Sandboxed builders can't write the shared `.git`** of a linked worktree (index.lock EPERM
  for codex; grok converts the worktree to a standalone .git). Expect to commit FOR them from
  the orchestrator shell, and to `git fetch <worktree-path> BRANCH:NEWNAME` to recover a
  detached branch tip.

## Orchestration Commands

### /cmux run [runtime:]prompt... — Run multi-agent sessions

Spawns interactive agent sessions in split panes within the **current workspace**, dispatches
prompts, and lets the user interact with each agent. Each prompt may be prefixed `claude:`,
`codex:`, `grok:`, or `kimi:`; unprefixed defaults to `claude`.

**Workflow:**

1. **Get current context and make a session prompt dir:**
   ```bash
   cmux identify
   # Per-session prompt dir — prevents two concurrent orchestrator sessions
   # clobbering each other's /tmp prompt files
   PROMPT_DIR=$(mktemp -d /tmp/cmux-agents.XXXXXX)
   ```

2. **Write each agent's prompt file** to `$PROMPT_DIR/agent-N-<name>.md` (see Prompt engineering
   below — MANDATORY), and show them to the user for review before dispatching.

3. **Start the completion-event listener BEFORE dispatching** (see Completion detection):
   ```bash
   cmux events --name notification.requested --no-heartbeat --no-ack > "$PROMPT_DIR/events.jsonl" &
   # remember the PID to kill later
   ```

4. **Create split panes** — one per agent, without stealing focus:
   ```bash
   # First agent: split right
   cmux new-split right --workspace workspace:1 --focus false
   # Returns: OK surface:N workspace:1
   # Second agent: split down from the first split
   cmux new-split down --workspace workspace:1 --surface surface:N --focus false
   ```

5. **Launch each agent:**

   **codex** — prompt goes in as a CLI argument, one shot, no startup handling needed:
   ```bash
   cmux send --surface surface:N "codex -s workspace-write -a never 'read $PROMPT_DIR/agent-1-api.md and implement it'"
   cmux send-key --surface surface:N enter
   ```

   **grok** — prompt also goes in as a CLI argument, but handle the startup directory picker:
   ```bash
   cmux send --surface surface:N "grok --sandbox workspace --always-approve 'read $PROMPT_DIR/agent-1-api.md and implement it'"
   cmux send-key --surface surface:N enter
   # "Run Grok Build in a project directory?" picker — pick the current dir:
   sleep 3
   cmux send --surface surface:N '1'
   cmux send-key --surface surface:N enter
   # the queued prompt argument runs immediately after the picker is dismissed
   ```

   **kimi** — no CLI-arg prompt in interactive mode; launch-then-send like claude:
   ```bash
   cmux send --surface surface:N "kimi --auto -m kimi-code/k3"   # k3 for frontend work; omit -m for default K2.7
   cmux send-key --surface surface:N enter
   # Startup screens not yet live-validated — read-screen before sending the task:
   sleep 5
   cmux read-screen --surface surface:N --lines 15   # confirm idle composer, no login/consent screen
   cmux send --surface surface:N "read $PROMPT_DIR/agent-3-frontend.md and implement it"
   cmux send-key --surface surface:N enter
   ```

   **claude** — launch, handle startup prompts, then send the task:
   ```bash
   cmux send --surface surface:M 'claude --dangerously-skip-permissions'
   cmux send-key --surface surface:M enter
   # Workspace trust prompt (non-git dirs only) — auto-dismiss:
   sleep 3
   cmux send --surface surface:M '1'
   cmux send-key --surface surface:M enter
   # Wait for full startup, then send the task pointer (short string only)
   sleep 5
   cmux send --surface surface:M "read $PROMPT_DIR/agent-2-ui.md and implement it"
   cmux send-key --surface surface:M enter
   ```

   > **`cmux send` length limit is a confirmed upstream bug, not folklore** (manaflow-ai/cmux
   > #2396, #4275: no size-based chunking in the PTY write path; long strings truncate or freeze
   > the surface, and there is no `--file`/stdin option). Keep every `send` payload under ~200
   > chars and NEVER multi-line (a newline submits early). Long content always goes through a
   > prompt file + a short "read X and do it" pointer.

   > **Claude `.claude/` write prompt** — known bug since v2.1.78
   > ([#35718](https://github.com/anthropics/claude-code/issues/35718)): writes to `.claude/`
   > paths prompt even with `--dangerously-skip-permissions`. Structure agent tasks to avoid
   > `.claude/` writes; let the orchestrator handle those.

6. **Set sidebar status** for visibility:
   ```bash
   cmux set-status "agents" "2 running" --workspace workspace:1
   cmux set-progress 0.0 --label "Agents running"
   ```

7. **Wait for completion** — event-driven, not polling (see Completion detection below).

8. **Collect and clean up:**
   ```bash
   cmux read-screen --surface surface:N --scrollback --lines 60   # collect results
   kill $EVENTS_PID
   cmux close-surface --surface surface:N
   cmux clear-status "agents"
   cmux clear-progress
   cmux notify --title "Agents Done" --body "All tasks complete"
   rm -rf "$PROMPT_DIR"
   ```

### Completion detection (event-driven — the old read-screen polling is the fallback)

Claude, Codex, and Grok emit a cmux `notification.requested` event when an agent turn ends
(Claude via the cmux claude wrapper automatically; Codex via the one-time `cmux hooks setup
codex`; Grok via the one-time `cmux hooks setup grok`). **Kimi is NOT in cmux's supported hooks
list** (checked against cmux 0.64.17: codex, grok, opencode, gemini, copilot, … but no kimi) —
wire it manually via kimi's own Claude-Code-style hook system. Add to
`~/.kimi-code/config.toml`:

```toml
[[hooks]]
event = "Stop"    # fires when the model ends its turn
command = "/Applications/cmux.app/Contents/Resources/bin/cmux notify --title 'Kimi' --body 'turn ended'"
timeout = 10
```

The hook runs as a child of the kimi process inside the pane, so the cmux socket accepts it
(only processes started inside cmux can connect — use the absolute binary path since hook PATH
is not guaranteed). Kimi hooks are fail-open (errors/timeouts never block the agent), so a
broken hook silently drops events — treat kimi completion events as best-effort like codex, and
pair with read-screen. Whether the event carries a usable `surface_id` is unvalidated; assume
grok-style null attribution until proven otherwise. Subscribe once, before dispatch:

```bash
cmux events --name notification.requested --no-heartbeat --no-ack > "$PROMPT_DIR/events.jsonl" &
```

Then wait without blocking the orchestrator: use a `run_in_background` Bash call
(`sleep 60 && echo poll`) and on each wake-up check the events file for new lines; when one
arrives, `read-screen` the agent panes to see which one finished.

**Match events to panes by `surface_id`** (verified live against cmux 0.64.17): each event frame
carries a top-level `"surface_id"` (UUID). Resolve each agent pane's UUID once after creating it
(`cmux list-pane-surfaces --id-format both` or `cmux tree --all --json`), then:
```bash
grep -q "\"surface_id\":\"$AGENT_SURFACE_UUID\"" "$PROMPT_DIR/events.jsonl"
```
This is precise per-agent — matching on `workspace_id` alone false-positives on notifications
from any other pane in the same workspace.

**Hard-won gotchas (from community + live verification):**
- **Redirect events to a FILE.** Piping `cmux events | jq` directly stalls on stdout buffering.
- **The event is a signal, not a verdict.** A notification fires even when the agent *declined*
  the task (e.g. refused, or stopped to ask a question). ALWAYS `read-screen` the pane after the
  event to verify actual completion before acting on it.
- **Codex panes may not fire `notification.requested` at all** (observed live 2026-07-13 even
  with `cmux hooks setup codex` installed; Claude panes fired reliably). Treat events as
  best-effort for codex — pair the listener with a periodic `read-screen` check of the codex
  pane's done marker (a `─ Worked for Xs ─` separator line above the composer).
- **Grok events fire reliably but carry `surface_id: null`** (verified live 2026-07-13, grok
  0.2.99): the hook posts through the socket (`notify_target_async`), not a pane context, so
  per-agent surface matching is IMPOSSIBLE for grok panes. An event tells you *some* grok turn
  ended — `read-screen` the grok pane(s) for the `Worked for Xs.` done marker to attribute it.
- **Event payload titles/bodies are redacted** (`redacted_fields: [title, subtitle, body]` —
  confirmed) — you get surface/workspace/timing metadata only; content comes from `read-screen`.
- **Kill the listener** (`kill $EVENTS_PID`) during cleanup.

**Screen-verification markers** (used after an event, or as the pure-polling fallback if the
events channel is unavailable):
- Claude done: line matching `✻ Crunched for` / `✻ Worked for` (any past-tense cooking verb) +
  the `❯` prompt. Still working: `✶ Misting…` etc. with elapsed time.
- Codex done: the `Esc to interrupt` footer marker is gone and the composer input box is back.
  Still working: `Esc to interrupt` visible.
- Grok done: a `Worked for Xs.` line + the empty `❯` composer box (status bar shows
  `Grok 4.5 (high) · always-approve`). Still working: `◆ Thought for …` / `◆ Run …` activity
  lines streaming. Grok's TUI keeps finalized output in scrollback (like Codex, unlike Claude),
  so `read-screen --scrollback` recovers long deliverables.
- Do NOT use blocking `sleep` loops in the foreground — schedule checks with `run_in_background`
  so the orchestrator stays responsive.

**Prompt engineering (MANDATORY for all orchestrated agents, all four runtimes):**

Agents start with ZERO context — they don't see the orchestrator's conversation, design decisions,
or prior work. Every prompt file must be a **self-contained blueprint**, not a task list.

**Every agent prompt MUST include these sections:**

1. **Context** — What project, what tech stack, what the agent is building and why
2. **Full spec** — Exact schemas, interfaces, function signatures, YAML formats — not "implement a schema" but the actual schema with field names and types
3. **File ownership** — Which files the agent creates, which it modifies, and which it must NOT touch (to avoid conflicts with parallel agents)
4. **Edge cases** — Every known edge case with its specific fix, not just "handle errors"
5. **Integration points** — Exact exports, imports, and function signatures that other agents depend on
6. **Existing patterns** — Code snippets from the codebase the agent must follow (status colors, component patterns, naming conventions)
7. **Testing requirements** — Specific happy path AND sad path test cases with expected outcomes
8. **Rules** — What NOT to do (don't commit, don't touch X files, don't add comments to unchanged code)

**Prompt format:**
- Write each prompt to `$PROMPT_DIR/agent-N-{name}.md` using the Write tool
- Use markdown with code blocks for schemas, interfaces, and examples
- Typical length: 200-400 lines (comprehensive but focused)
- Structure by numbered sections so the agent can work through them sequentially

**Anti-patterns to avoid:**
- "Implement the chain feature" — too vague, agent will guess wrong
- "Fix the issues we discussed" — agent has no conversation context
- "Follow existing patterns" without showing what those patterns are
- Listing tasks without providing the data structures they operate on
- Assuming the agent knows what other agents are doing

**Before dispatching:** Show the user the prompt files for review. The user can catch missing
context that would cause the agent to drift.

**Important notes:**
- Parallel writers → separate file ownership per agent; if two agents must touch the same files,
  serialize them or give each its own git worktree (one writer per tree)
- Do NOT use `claude -p` or `codex exec` (non-interactive modes) — use interactive sessions so
  the user can intervene in the pane if needed. EXCEPTION: `kimi -p` is validated for headless
  one-shots from the orchestrator shell (see Kimi dispatch modes table) — but orchestrated
  multi-step builders still belong in interactive panes
- Create splits in the **current workspace** unless the user asks for a new workspace; always
  pass `--focus false` and never call `select-workspace`/`focus-pane` unless the user asks
- `cmux codex-teams` (native Codex-subagent panes) exists but is still fragile upstream
  (open bugs: subagent splits not opening #5698/#6832, approvals missing the Feed #6445) —
  don't build on it yet; revisit after a few releases

### /cmux multi [count] — Set up multi-agent split panes
1. Get current workspace: `cmux identify`
2. Create [count] split panes (default: 3) using `cmux new-split ... --focus false`
3. Layout pattern (community-standard):
   - 2 agents: split right
   - 3 agents: split right, then split the right pane down
   - 4+ agents: 2x2 grid (split right, split each side down)
4. Launch each pane's runtime (`claude` default; honor `runtime:` prefixes)
5. Dispatch per the /cmux run workflow above

### /cmux collect — Read results from agent panes
Read what's on each agent pane's screen to collect results without temp files.
```bash
# Read the last 30 lines from a surface
cmux read-screen --surface surface:N --lines 30

# Read with scrollback for full history
cmux read-screen --surface surface:N --scrollback --lines 100
```

> **Long Claude output does NOT survive in scrollback** (verified live): the Claude TUI runs in
> an alternate screen that redraws in place, so `read-screen --scrollback` returns only the last
> visible chunk — a multi-section review loses its top. Two reliable options: (a) for long
> deliverables, instruct the agent UP FRONT to write its final output to a file in `$PROMPT_DIR`
> and read that; (b) after the fact, send the still-open pane a short
> `save the full <thing> verbatim to $PROMPT_DIR/out.md` and read the file. Codex TUI output
> survives scrollback fine.

### /cmux close — Close agent panes
Close split panes created by `/cmux run` or `/cmux multi`:
```bash
cmux close-surface --surface surface:N
cmux clear-progress
cmux notify --title "Claude Code" --body "Agent panes closed"
```

---

## Workflow Templates

### /cmux review — Parallel code review
Spawns 2 agents for comprehensive code review:
- **Agent 1 (Logic)**: "Review this code for logic errors, edge cases, and potential bugs"
- **Agent 2 (Style)**: "Review this code for style, conventions, naming, and readability"

Workflow:
1. Create 2 split panes (right + down-right)
2. Launch interactive claude in each
3. Send review prompts with the relevant file paths
4. Set sidebar: `cmux set-status "review" "In progress"`
5. User approves permissions and reviews results in each pane
6. Close panes when done

### /cmux review --cross — Cross-model review (Claude × Codex)
The highest-signal review: an independent model family's second opinion instead of two instances
of the same model agreeing with each other.

- **Pane 1 (Codex, read-only)**: `codex review --base main` (or `--uncommitted` for the working
  tree; a scope flag is mandatory). Optionally append custom instructions as the prompt argument.
- **Pane 2 (Claude)**: `claude --dangerously-skip-permissions` + a review prompt focused on what
  Codex is weakest at for this diff (product intent, repo conventions, ADR compliance).

Variant — **implement × review handoff**: Claude (or the orchestrator) implements, then a Codex
pane reviews the diff before commit. Collect both verdicts with `read-screen`, synthesize
agreement/disagreement for the user, and let the user arbitrate conflicts.

Variant — **multi-family panel**: add a third pane with
`grok --sandbox read-only --always-approve "<review prompt>"` for an xAI-family opinion
(kernel-enforced read-only, so it can't touch the tree), and optionally a fourth with
`kimi --plan --auto -m kimi-code/k3` + a review prompt (pin the model or the seat runs mid-tier
K2.7; SOFT read-only only — no kernel enforcement — so reserve the kimi seat for trusted
trees; strongest on UI/frontend diffs where K3's judgment is best-in-class). Independent model families agreeing is a much stronger signal than any
two instances of one; disagreements pinpoint the judgment calls worth escalating to the user.

### /cmux debug — Parallel bug investigation
Spawns 2 agents to investigate a bug from different angles:
- **Agent 1 (Reproduce)**: "Try to reproduce this bug and identify the exact conditions"
- **Agent 2 (Trace)**: "Trace the code path and identify the root cause"

Cross-model variant on request: run one investigator as `codex:` for an independent take.

Workflow:
1. Create 2 split panes
2. Launch the runtime in each
3. Send debug prompts with bug description and relevant files
4. Set sidebar: `cmux set-status "debug" "Investigating"`
5. User interacts with each agent as needed
6. Close panes when done

### /cmux dev [url] — Dev server + browser setup
Sets up a terminal pane for the dev server alongside a browser pane for live preview.

Workflow:
1. Split right: create a browser pane
   ```bash
   cmux new-pane --type browser --direction right --workspace workspace:1 --url "[url]" --focus false
   ```
2. The left pane (current) runs the dev server or claude
3. Browser auto-loads the dev URL
4. Agent can verify UI changes by snapshotting the browser:
   ```bash
   cmux browser wait --surface surface:N --load-state complete
   cmux browser snapshot --surface surface:N --compact
   ```

### /cmux feature — Feature development workflow
Spawns 2 agents for parallel feature development:
- **Agent 1 (Explore)**: "Read and understand the existing implementation of [feature area]"
- **Agent 2 (Scaffold)**: "Create the scaffolding for [new feature] based on existing patterns"

### /cmux test — Parallel test writing
Spawns 2 agents:
- **Agent 1**: "Write unit tests for [module]"
- **Agent 2**: "Write integration tests for [module]"

---

## Browser Commands

> Full browser automation reference lives in the official `cmux-browser` skill — use it for
> anything beyond the basics below.

### /cmux browse [url] — Open a browser pane
```bash
cmux new-pane --type browser --direction right --workspace workspace:1 --url "https://example.com" --focus false
```
If no URL is provided, opens a blank browser.

**Core browser automation** (all use `--surface surface:N`):
```bash
cmux browser goto "https://url.com" --surface surface:N       # Navigate to URL
cmux browser screenshot --surface surface:N                    # Take screenshot
cmux browser snapshot --surface surface:N --compact            # DOM snapshot (find refs)
cmux browser wait --surface surface:N --load-state complete    # Wait for page load
cmux browser click --surface surface:N "css-selector"          # Click element
cmux browser fill --surface surface:N "css-selector" "text"    # Fill input
cmux browser eval --surface surface:N "document.title"         # Run JavaScript
```

### Browser verification loop
For self-correcting browser automation, use a snapshot-verify-retry pattern:
```bash
cmux browser wait --surface surface:N --load-state complete
cmux browser snapshot --surface surface:N --interactive --compact
cmux browser click --surface surface:N 'e14'     # interact via refs (e10, e14, ...)
cmux browser snapshot --surface surface:N --interactive --compact   # verify, adapt, retry
```

---

## Workspace Commands

### /cmux workspace [name] — Create a new workspace
1. Create workspace: `cmux new-workspace [--command "zsh"]`
2. Rename it: `cmux rename-workspace --workspace <id> "<name>"`
3. Set sidebar status: `cmux set-status "status" "Active" --workspace <id>`

---

## CLI Quick Reference (orchestration-relevant subset)

> The full, current CLI contract lives in the official `cmux-cli` skill and `cmux docs` /
> `cmux <cmd> --help` — discover there rather than trusting a stale table.

| Command | Description |
|---------|-------------|
| `cmux ping` / `cmux identify` | Liveness / current workspace+surface context |
| `cmux new-split <dir> --focus false` | Split pane (left/right/up/down) without stealing focus |
| `cmux close-surface --surface <id>` | Close a split pane |
| `cmux send --surface <id> <text>` | Type text into a pane (short, single-line only — see bug note) |
| `cmux send-key --surface <id> enter` | Submit (send never auto-submits) |
| `cmux read-screen --surface <id> [--scrollback] [--lines N]` | Read pane output |
| `cmux events --name notification.requested --no-heartbeat --no-ack` | Push-based agent-completion stream |
| `cmux hooks setup <agent> -y` | Wire an agent CLI (codex, opencode, gemini, …) into cmux events/Feed |
| `cmux wait-for <name> [--timeout s]` / `cmux wait-for --signal <name>` | Named barrier between panes (manual semaphore — NOT agent-completion) |
| `cmux notify / set-status / set-progress / trigger-flash / log` | Attention + sidebar surfaces |
| `cmux tree` / `cmux list-workspaces` | Topology inspection |
| `cmux new-pane --type browser --url <url>` | Open browser pane |
| `cmux capabilities --json` | Machine-readable feature probe before assuming a command exists |

## Key Shortcuts
| Shortcut | Action |
|----------|--------|
| Cmd+Shift+U | Jump to most recent unread |
| Cmd+D | Split pane horizontally |
| Cmd+Shift+D | Split pane vertically |

## Requirements
- macOS
- cmux installed (`brew tap manaflow-ai/cmux && brew install --cask cmux`) — validated: 0.64.17
- Official cmux skill pack (`npx skills add manaflow-ai/cmux-skills -g`)
- jq installed (`brew install jq`)
- Claude Code hooks configured in `~/.claude/settings.json`
- For the codex runtime: codex CLI installed + logged in (validated: 0.144.1),
  `cmux hooks setup codex -y` run once, repo paths trusted in `~/.codex/config.toml`
- For the grok runtime: grok CLI on PATH (cmux bundles it; validated: 0.2.99 "Grok Build"),
  logged in (`grok models`), `cmux hooks setup grok -y` run once
- For the kimi runtime: `brew install kimi-code` (validated: 0.26.0; NOT the legacy `kimi-cli`
  formula — that's the superseded Python CLI), logged in once via `kimi login` (device-code
  OAuth; K3 model needs a Moderato+ subscription), manual `Stop` hook in
  `~/.kimi-code/config.toml` (no `cmux hooks setup kimi` support yet — re-check on cmux
  upgrades; login MERGES config.toml and preserves the hook — verified 2026-07-17). Headless
  `-p` + tool-use + `kimi-code/k3` verified live 2026-07-17 (agentic file-write smoke test
  passed; session resume hint `kimi -r session_<id>` printed at end of each `-p` run). Fast 0.x
  release cadence (4 releases in 4 days mid-July 2026): `kimi upgrade` / `brew upgrade
  kimi-code` often, and re-verify flags after major bumps
