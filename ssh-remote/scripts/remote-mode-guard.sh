#!/usr/bin/env bash
# PreToolUse hook (Bash tool) for ssh-remote "remote mode".
#
# When remote mode is locked to a host (ssh-remote remote-mode on / auto-locked on
# connect), every local shell command is blocked so that EVERYTHING runs on the
# remote machine via `ssh-remote run`. Only commands that go through the
# `ssh-remote` gateway are allowed through.
#
# Wired up in settings.json as:
#   "hooks": { "PreToolUse": [ { "matcher": "Bash",
#     "hooks": [ { "type": "command",
#       "command": "~/.claude/skills/ssh-remote/scripts/remote-mode-guard.sh" } ] } ] }
#
# Design note: this FAILS OPEN. Any parse error, missing tool, or unexpected input
# lets the command run. A bug in the guard must never lock you out of your own shell.
set -uo pipefail

SOCKET_DIR="${SSH_REMOTE_SOCKET_DIR:-$HOME/.ssh/claude-remote}"
LOCK_FILE="$SOCKET_DIR/remote-mode"

allow() { exit 0; }   # let Claude Code run the command unchanged

# Nothing locked -> don't interfere at all.
[ -f "$LOCK_FILE" ] || allow
HOST="$(cat "$LOCK_FILE" 2>/dev/null || true)"
[ -n "$HOST" ] || allow

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || allow

# --- read the command string out of the tool payload (tool_input.command) ---
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi
if [ -z "$cmd" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | python3 -c 'import sys,json
try:
    print((json.load(sys.stdin).get("tool_input") or {}).get("command") or "")
except Exception:
    pass' 2>/dev/null || true)"
fi
# Could not read the command -> be safe, allow.
[ -n "$cmd" ] || allow

# --- allow commands that route through the ssh-remote gateway ---
# Trim leading whitespace, then strip any leading `VAR=value ` env assignments so
# `FOO=bar ssh-remote run ...` is still recognised as an ssh-remote command.
rest="${cmd#"${cmd%%[![:space:]]*}"}"
while printf '%s' "$rest" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+'; do
  rest="$(printf '%s' "$rest" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')"
done
case "$rest" in
  ssh-remote|ssh-remote\ *) allow ;;
esac

# --- otherwise: DENY, and tell Claude exactly how to comply ---
reason="Locked to '$HOST' - local shell commands are blocked so that everything runs on the remote machine.

Run this on the host instead:
  ssh-remote run $HOST '<the command>'

Notes:
- Read/Edit/Write still work locally; only the Bash tool is gated here.
- If the user explicitly wants to run LOCALLY, turn it off first:
    ssh-remote remote-mode off
- If the session has expired, reconnect:  /ssh-remote $HOST"

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
elif command -v python3 >/dev/null 2>&1; then
  R="$reason" python3 -c 'import os,json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":os.environ["R"]}}))'
else
  esc="$reason"; esc="${esc//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$esc"
fi
exit 0
