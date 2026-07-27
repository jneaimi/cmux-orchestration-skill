#!/usr/bin/env bash
# cmux-fan.sh — footgun-proof multi-agent fan-out for cmux orchestration.
#
# Encodes, as STRUCTURE, the four things a week of session-mining showed we keep
# getting wrong by hand (see skill.md "Completion detection"):
#   1. Collect from a FILE + .done marker, never by polling the screen.
#   2. A closed pane's "Surface not found" means DONE — read the file, don't retry.
#   3. Never eval `===`/`{}` through a send — we only ever send one short, quoted pointer.
#   4. No `timeout(1)` (absent on macOS) — bounded waits use bash SECONDS.
#
# Subcommands share a work dir via $CMUX_FAN_DIR (or --dir). Typical flow:
#   DIR=$(cmux-fan.sh init)
#   cmux-fan.sh prompt reviewer-claude ./brief-claude.md      # appends the .done contract
#   cmux-fan.sh send   reviewer-claude surface:12             # readiness-gated, safe send
#   cmux-fan.sh wait   --timeout 900                          # polls .done markers
#   cmux-fan.sh collect                                       # cats verdicts, prints summary
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

# ── send <name> <surface> [--warmup N] [--ready-regex RE] [--ready-timeout N] : safe, readiness-gated ──
cmd_send() {
  _resolve_dir
  local name="${1:?usage: send <name> <surface>}"; local surface="${2:?usage: send <name> <surface>}"; shift 2
  local warmup=5 ready_re="" ready_to=45
  while [ $# -gt 0 ]; do case "$1" in
    --warmup) warmup="$2"; shift 2;;
    --ready-regex) ready_re="$2"; shift 2;;
    --ready-timeout) ready_to="$2"; shift 2;;
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
  "$CMUX_BIN" send --surface "$surface" "read $pf and follow it exactly, including the final step"
  "$CMUX_BIN" send-key --surface "$surface" enter
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
    send) cmd_send "$@";;
    wait) cmd_wait "$@";;
    collect) cmd_collect "$@";;
    clean) cmd_clean;;
    ""|-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//';;
    *) die "unknown subcommand '$sub' (init|prompt|send|wait|collect|clean)";;
  esac
}
main "$@"
