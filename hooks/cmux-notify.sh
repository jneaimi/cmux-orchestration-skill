#!/bin/bash
# cmux local notification hook for Claude Code
# Sends notifications via cmux (local only) when:
#   - Stop: session turn completes
#   - Notification: Claude needs user attention (AskUserQuestion, etc.)
#   - PostToolUse(Task): agent task finished

EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.hook_event_name // "unknown"')

# --- cmux (local, best-effort) ---
cmux_available=false
cmux ping >/dev/null 2>&1 && cmux_available=true

$cmux_available || exit 0

case "$EVENT_TYPE" in
  "Stop")
    cmux clear-progress 2>/dev/null
    cmux notify --title "Claude Code" --body "Session complete — ready for input"
    ;;

  "PostToolUse")
    cmux notify --title "Claude Code" --body "Agent task finished"
    ;;

  "Notification")
    MESSAGE=$(echo "$EVENT" | jq -r '.message // "Notification"')
    cmux notify --title "Claude Code" --body "$MESSAGE"
    ;;
esac
