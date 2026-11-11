#!/usr/bin/env bash
# Notification hook: alert the human when Claude is waiting for input/permission.
# Cross-platform best effort; never fails the session.
MSG="${1:-Claude Code 需要你处理（人工门/权限确认）}"
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$MSG\" with title \"Claude Code\"" >/dev/null 2>&1
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "Claude Code" "$MSG" >/dev/null 2>&1
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "[console]::beep(880,300)" >/dev/null 2>&1
else
  printf '\a' >&2
fi
# Optional: push to your phone/chat. Uncomment and set HARNESS_WEBHOOK (Slack/Discord/ntfy...).
# [ -n "$HARNESS_WEBHOOK" ] && curl -fsS -m 5 -d "$MSG" "$HARNESS_WEBHOOK" >/dev/null 2>&1
exit 0
