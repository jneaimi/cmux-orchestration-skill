#!/usr/bin/env bash
# cmux-fan.sh — footgun-proof multi-agent fan-out for cmux orchestration.
#
# Encodes, as STRUCTURE, the footguns a 10-day session-mining showed we keep
# hand-rolling wrong (see skill.md "Completion detection" / "Context hygiene"):
#   1. Collect from a FILE + .done marker, never by polling the screen.
#   2. A closed pane's "Surface not found" means DONE — read the file, don't retry.
#   3. Never eval `===`/`{}` through a send — we only ever send one short, quoted pointer.
#   4. No `timeout(1)` (absent on macOS) — bounded waits use bash SECONDS.
#   5. The Enter-drop is universal — `send` verifies submission and resends Enter.
#   6. Runtime startup (claude/codex/grok/kimi/qwen) is encapsulated in `launch`, not re-derived.
#
# Subcommands share a work dir via $CMUX_FAN_DIR (or --dir). Typical flow:
#   DIR=$(cmux-fan.sh init)
#   cmux-fan.sh prompt reviewer-claude ./brief-claude.md         # appends the .done contract
#   cmux new-split right --workspace workspace:1 --focus false   # → surface:12 (caller creates it)
#   cmux-fan.sh launch reviewer-claude surface:12 claude         # runtime-aware startup in the split
#   cmux-fan.sh send   reviewer-claude surface:12                # readiness-gated, submit-verified send
#   cmux-fan.sh wait   --timeout 900                             # polls .done markers
#   cmux-fan.sh collect                                          # cats verdicts, prints summary
set -euo pipefail

CMUX_BIN="${CMUX_BIN:-$(command -v cmux || echo /Applications/cmux.app/Contents/Resources/bin/cmux)}"
FAN_DIR="${CMUX_FAN_DIR:-}"

die() { echo "cmux-fan: $*" >&2; exit 1; }
_resolve_dir() { [ -n "$FAN_DIR" ] && [ -d "$FAN_DIR" ] || die "no work dir — run 'init' and export CMUX_FAN_DIR, or pass --dir"; }

# ── init: create the shared work dir and print it (capture into $CMUX_FAN_DIR) ──
cmd_init() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agents.XXXXXX")
  echo "$d"
}

# ── prompt <name> <file|-> : write prompt-<name>.md with the completion contract appended ──
# The contract is what makes collection file-based and race-free for EVERY provider.
cmd_prompt() {
  _resolve_dir
  local name="${1:?usage: prompt <name> <file|->}"; local src="${2:?usage: prompt <name> <file|->}"
  local body
  if [ "$src" = "-" ]; then body=$(cat); else [ -f "$src" ] || die "no such prompt file: $src"; body=$(cat "$src"); fi
  local pf="$FAN_DIR/prompt-$name.md"
  {
    printf '%s\n\n' "$body"
    printf -- '---\n'
    printf '## MANDATORY final step (do this as your LAST action, always)\n'
    printf 'Write your complete result to `%s/verdict-%s.md`.\n' "$FAN_DIR" "$name"
    printf 'Then run exactly: `touch %s/%s.done`\n' "$FAN_DIR" "$name"
    printf 'The `.done` marker is how the orchestrator knows you finished — never skip it,\n'
    printf 'even if your answer is short or you are only reporting that you could not proceed.\n'
  } > "$pf"
  echo "$pf"
}

# ── launch <name> <surface> <runtime> [--model M] [--prompt-file F] [--warmup N] ──
# Encapsulates runtime-specific startup (footgun 6). The CALLER has already created the
# split (cmux new-split) and passes the resulting <surface>; launch starts the agent IN it
# with the right flags + startup handling. Does NOT require the work dir — it composes on a
# surface + optional prompt file, so it works standalone.
#   claude/kimi     → launch-then-idle; task goes in via a subsequent `send` (awaiting-send).
#   codex/grok/qwen → prompt is a LAUNCH ARG; the task runs immediately (prompt-as-arg), no `send`.
cmd_launch() {
  local name="${1:?usage: launch <name> <surface> <runtime> (claude|codex|grok|kimi|qwen)}"
  local surface="${2:?usage: launch <name> <surface> <runtime> (claude|codex|grok|kimi|qwen)}"
  local runtime="${3:?usage: launch <name> <surface> <runtime> (claude|codex|grok|kimi|qwen)}"
  shift 3
  local model="" prompt_file="" warmup=0
  while [ $# -gt 0 ]; do case "$1" in
    --model) model="$2"; shift 2;;
    --prompt-file) prompt_file="$2"; shift 2;;
    --warmup) warmup="$2"; shift 2;;
    *) die "launch: unknown flag $1";;
  esac; done

  case "$runtime" in claude|codex|grok|kimi|qwen) ;; *) die "launch: unknown runtime '$runtime' (claude|codex|grok|kimi|qwen)";; esac
  [ -z "$prompt_file" ] || [ -f "$prompt_file" ] || die "launch: no such prompt file: $prompt_file"
  [ "$warmup" -gt 0 ] && sleep "$warmup"

  # Guard (same abort as send): never type into a surface that never spawned.
  local screen; screen=$("$CMUX_BIN" read-screen --surface "$surface" --lines 20 2>&1 || true)
  case "$screen" in
    *"Surface not found"*|*"not_found"*|*"Remote Control failed"*|*"Session creation failed"*)
      die "launch: $surface failed to spawn — abort this lane";;
  esac

  local status_kind="awaiting-send"
  case "$runtime" in
    claude)
      local m="${model:-sonnet}"
      "$CMUX_BIN" send --surface "$surface" "claude --model $m --dangerously-skip-permissions"
      "$CMUX_BIN" send-key --surface "$surface" enter
      sleep 3
      screen=$("$CMUX_BIN" read-screen --surface "$surface" --lines 20 2>&1 || true)
      case "$screen" in
        *[Tt]rust*|*"Do you trust"*|*"proceed"*)   # workspace-trust prompt (non-git dirs)
          "$CMUX_BIN" send --surface "$surface" '1'
          "$CMUX_BIN" send-key --surface "$surface" enter;;
      esac
      sleep 5
      model="$m"
      ;;
    kimi)
      local kcmd="kimi --auto"
      [ -n "$model" ] && kcmd="$kcmd -m $model"
      "$CMUX_BIN" send --surface "$surface" "$kcmd"
      "$CMUX_BIN" send-key --surface "$surface" enter
      sleep 5
      screen=$("$CMUX_BIN" read-screen --surface "$surface" --lines 15 2>&1 || true)   # confirm idle composer
      ;;
    codex)
      if [ -n "$prompt_file" ]; then
        local ccmd="codex -s workspace-write -a never"
        [ -n "$model" ] && ccmd="$ccmd -m $model"
        "$CMUX_BIN" send --surface "$surface" "$ccmd 'read $prompt_file and implement it, following its final step exactly'"
        "$CMUX_BIN" send-key --surface "$surface" enter
        status_kind="prompt-as-arg"
      else
        "$CMUX_BIN" send --surface "$surface" "codex"
        "$CMUX_BIN" send-key --surface "$surface" enter
      fi
      ;;
    grok)
      if [ -n "$prompt_file" ]; then
        local gcmd="grok --sandbox workspace --always-approve"
        [ -n "$model" ] && gcmd="$gcmd -m $model"
        "$CMUX_BIN" send --surface "$surface" "$gcmd 'read $prompt_file and implement it, following its final step exactly'"
        "$CMUX_BIN" send-key --surface "$surface" enter
        sleep 3
        # "Run Grok Build in a project directory?" picker — pick the current dir, queued prompt runs.
        "$CMUX_BIN" send --surface "$surface" '1'
        "$CMUX_BIN" send-key --surface "$surface" enter
        status_kind="prompt-as-arg"
      else
        "$CMUX_BIN" send --surface "$surface" "grok --sandbox workspace --always-approve"
        "$CMUX_BIN" send-key --surface "$surface" enter
        sleep 3
        "$CMUX_BIN" send --surface "$surface" '1'
        "$CMUX_BIN" send-key --surface "$surface" enter
      fi
      ;;
    qwen)
      # gemini-cli fork: prompt-as-arg via -i (--prompt-interactive: runs the prompt, stays
      # interactive — live-verified in a cmux pane). NO trust picker (folderTrust off by default).
      # --approval-mode is a real flag (hidden from --help but accepted); auto = bounded autonomy.
      # BYOM gateway: -m names the model per the configured provider (no free tier — BYOK).
      local qcmd="qwen --approval-mode auto"
      [ -n "$model" ] && qcmd="$qcmd -m $model"
      if [ -n "$prompt_file" ]; then
        "$CMUX_BIN" send --surface "$surface" "$qcmd -i 'read $prompt_file and implement it, following its final step exactly'"
        "$CMUX_BIN" send-key --surface "$surface" enter
        status_kind="prompt-as-arg"
      else
        "$CMUX_BIN" send --surface "$surface" "$qcmd"
        "$CMUX_BIN" send-key --surface "$surface" enter
      fi
      ;;
  esac

  echo "launched → $name ($surface) runtime=$runtime model=${model:-default} $status_kind"
}

# ── send <name> <surface> [--warmup N] [--ready-regex RE] [--ready-timeout N] [--submit-retries N] ──
# Safe, readiness-gated send + submit-verify loop (footgun 5: the Enter-drop is universal).
cmd_send() {
  _resolve_dir
  local name="${1:?usage: send <name> <surface>}"; local surface="${2:?usage: send <name> <surface>}"; shift 2
  local warmup=5 ready_re="" ready_to=45 submit_retries=2
  while [ $# -gt 0 ]; do case "$1" in
    --warmup) warmup="$2"; shift 2;;
    --ready-regex) ready_re="$2"; shift 2;;
    --ready-timeout) ready_to="$2"; shift 2;;
    --submit-retries) submit_retries="$2"; shift 2;;
    *) die "send: unknown flag $1";;
  esac; done
  local pf="$FAN_DIR/prompt-$name.md"; [ -f "$pf" ] || die "no prompt for '$name' — run 'prompt $name ...' first"

  # Readiness gate (feeds on B's finding: never send into a pane that never came up).
  sleep "$warmup"
  local screen; screen=$("$CMUX_BIN" read-screen --surface "$surface" --lines 20 2>&1 || true)
  case "$screen" in
    *"Surface not found"*|*"not_found"*) die "send: $surface does not exist";;
    *"Remote Control failed"*|*"Session creation failed"*) die "send: $surface failed to spawn (remote-control drop) — abort this lane";;
  esac
  if [ -n "$ready_re" ]; then
    local waited=0
    until printf '%s' "$screen" | grep -qE "$ready_re"; do
      [ "$waited" -ge "$ready_to" ] && die "send: $surface not ready after ${ready_to}s (regex: $ready_re)"
      sleep 3; waited=$((waited+3))
      screen=$("$CMUX_BIN" read-screen --surface "$surface" --lines 20 2>&1 || true)
    done
  fi

  # Safe send: ONE short, single-quoted pointer. No newlines, no ===/{} — footguns 3 & 4 gone.
  local ptr="read $pf and follow it exactly, including the final step"
  "$CMUX_BIN" send --surface "$surface" "$ptr"
  "$CMUX_BIN" send-key --surface "$surface" enter

  # Submit-verify loop (footgun 5). The tell (skill.md "Context hygiene"): the pointer text
  # sitting verbatim INSIDE the composer box = the Enter was dropped. Resend Enter up to N
  # times; warn (never die) if still stuck — the lane may still recover on its own.
  local resent=0 submitted=0
  while [ "$resent" -le "$submit_retries" ]; do
    sleep 2
    local after; after=$("$CMUX_BIN" read-screen --surface "$surface" --lines 8 2>&1 || true)
    case "$after" in
      *"$ptr"*) ;;                       # still in the composer — the send did not submit
      *) submitted=1; break;;            # pointer no longer verbatim on screen — submitted
    esac
    [ "$resent" -ge "$submit_retries" ] && break
    "$CMUX_BIN" send-key --surface "$surface" enter
    resent=$((resent+1))
  done
  [ "$submitted" -eq 1 ] || echo "send: WARN $surface may not have submitted after $submit_retries retries" >&2

  echo "sent → $name ($surface)"
}

# ── wait [--timeout N] [--poll N] : block until every prompt-*.md has a matching .done marker ──
cmd_wait() {
  _resolve_dir
  local timeout=1800 poll=15
  while [ $# -gt 0 ]; do case "$1" in
    --timeout) timeout="$2"; shift 2;;
    --poll) poll="$2"; shift 2;;
    *) die "wait: unknown flag $1";;
  esac; done
  local names=(); for pf in "$FAN_DIR"/prompt-*.md; do [ -e "$pf" ] || continue; local n; n=$(basename "$pf"); n="${n#prompt-}"; n="${n%.md}"; names+=("$n"); done
  [ "${#names[@]}" -gt 0 ] || die "wait: no prompts in $FAN_DIR"

  SECONDS=0
  while :; do
    local done_n=0 pending=()
    for n in "${names[@]}"; do
      if [ -f "$FAN_DIR/$n.done" ]; then done_n=$((done_n+1)); else pending+=("$n"); fi
    done
    echo "[${SECONDS}s] done $done_n/${#names[@]}${pending:+ — pending: ${pending[*]}}" >&2
    [ "$done_n" -eq "${#names[@]}" ] && { echo "all ${#names[@]} agents done in ${SECONDS}s" >&2; return 0; }
    [ "$SECONDS" -ge "$timeout" ] && { echo "cmux-fan: TIMEOUT after ${timeout}s — still pending: ${pending[*]}" >&2; return 1; }
    sleep "$poll"
  done
}

# ── collect [--out FILE] : concatenate every verdict; note any missing (never wrote its file) ──
cmd_collect() {
  _resolve_dir
  local out=""; while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2;; *) die "collect: unknown flag $1";; esac; done
  local buf="" missing=()
  for pf in "$FAN_DIR"/prompt-*.md; do
    [ -e "$pf" ] || continue
    local n; n=$(basename "$pf"); n="${n#prompt-}"; n="${n%.md}"
    local vf="$FAN_DIR/verdict-$n.md"
    if [ -f "$vf" ]; then
      buf+=$'\n'"===== $n ====="$'\n'"$(cat "$vf")"$'\n'
    else
      missing+=("$n"); buf+=$'\n'"===== $n (NO verdict file — write was blocked or agent skipped it) ====="$'\n'
    fi
  done
  if [ -n "$out" ]; then printf '%s\n' "$buf" > "$out"; echo "collected → $out" >&2; else printf '%s\n' "$buf"; fi
  [ "${#missing[@]}" -eq 0 ] || echo "cmux-fan: ${#missing[@]} agent(s) left no verdict: ${missing[*]}" >&2
}

# ── clean : remove the work dir ──
cmd_clean() { _resolve_dir; rm -rf "$FAN_DIR"; echo "removed $FAN_DIR" >&2; }

main() {
  local sub="${1:-}"; shift || true
  # allow a leading --dir on any subcommand
  local rest=(); while [ $# -gt 0 ]; do case "$1" in --dir) FAN_DIR="$2"; shift 2;; *) rest+=("$1"); shift;; esac; done
  if [ "${#rest[@]}" -gt 0 ]; then set -- "${rest[@]}"; else set --; fi
  case "$sub" in
    init) cmd_init;;
    prompt) cmd_prompt "$@";;
    launch) cmd_launch "$@";;
    send) cmd_send "$@";;
    wait) cmd_wait "$@";;
    collect) cmd_collect "$@";;
    clean) cmd_clean;;
    ""|-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//';;
    *) die "unknown subcommand '$sub' (init|prompt|launch|send|wait|collect|clean)";;
  esac
}
main "$@"
