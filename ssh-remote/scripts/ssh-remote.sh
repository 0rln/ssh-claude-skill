#!/usr/bin/env bash
set -euo pipefail

SOCKET_DIR="${SSH_REMOTE_SOCKET_DIR:-$HOME/.ssh/claude-remote}"
PERSIST="${SSH_REMOTE_PERSIST:-4h}"
CONNECT_TIMEOUT="${SSH_REMOTE_CONNECT_TIMEOUT:-15}"
RECENT_FILE="$SOCKET_DIR/recent"
RECENT_MAX=10

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YEL=; C_BOLD=; C_DIM=; C_OFF=
fi

die() { printf 'ssh-remote: %s\n' "$*" >&2; exit 1; }
ensure_dir() { mkdir -p "$SOCKET_DIR"; chmod 700 "$SOCKET_DIR"; }

socket_for() {
  local target="${1:-}"; [ -n "$target" ] || die "no target given"
  local safe; safe="$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/%s.sock' "$SOCKET_DIR" "$safe"
}
is_up() { ssh -S "$1" -O check "$2" >/dev/null 2>&1; }
persist_host() { printf '%s\n' "$2" > "$1.host"; }

record_recent() {
  local host="$1" tmp; ensure_dir
  tmp="$(mktemp "$SOCKET_DIR/.recent.XXXXXX")"
  { printf '%s\n' "$host"; [ -f "$RECENT_FILE" ] && grep -vxF "$host" "$RECENT_FILE" || true; } \
    | awk 'NF' | head -n "$RECENT_MAX" > "$tmp"
  mv -f "$tmp" "$RECENT_FILE"
}

classify_ssh_error() {
  case "$1" in
    *"Permission denied"*|*"No more authentication methods"*|*"Authentications that can continue"*) echo auth ;;
    *"timed out"*|*"Operation timed out"*|*"Connection refused"*|*"Could not resolve"*|\
    *"No route to host"*|*"Network is unreachable"*|*"Name or service not known"*) echo net ;;
    *) echo other ;;
  esac
}

print_connected() {
  printf '%s\n' "${C_GREEN}${C_BOLD}CONNECTED${C_OFF} - now ssh'd into ${C_BOLD}$1${C_OFF}. (Session persists ${PERSIST} idle.)"
}
print_failed() {
  printf '%s\n' "${C_RED}${C_BOLD}NOT CONNECTED${C_OFF} - $1"
  case "$2" in
    auth) printf '  Reason: authentication failed - wrong password or not authorized.\n' ;;
    net)  printf '  Reason: could not reach the host - timed out, refused, or unknown name.\n' ;;
    *)    printf '  Reason: connection failed (see the ssh message above).\n' ;;
  esac
}
session_down_banner() {
  printf '%s\n' "${C_RED}${C_BOLD}SSH SESSION DOWN${C_OFF} - ${C_BOLD}$1${C_OFF}"
  printf '%s\n' "  The connection dropped or timed out. Nothing ran on the remote."
  printf '%s\n' "  Reconnect with: ${C_BOLD}/ssh-remote $1${C_OFF}"
}

usage() {
  cat <<'USAGE'
ssh-remote - drive a remote host over a persistent, multiplexed SSH connection.

  hosts                          List hosts for the picker (recent first, then ~/.ssh/config)
  connect [--password-stdin] [--interactive] <[user@]host>
                                 Open the connection. Default tries key auth (no prompt) and
                                 exits 2 printing PASSWORD_REQUIRED if a password is needed.
                                 --password-stdin reads the password from stdin (no terminal).
                                 --interactive prompts on the terminal (for manual ! use).
  status [<host>]                Show a LIVE/DOWN banner for one or all sessions
  check  <host>                  Exit 0 if the session is live, else non-zero (quiet)
  run    <host> <command...>     Run a command on the remote (reuses the socket; stdin passes through)
  shell  <host>                  Open an interactive remote shell (run via !)
  push   <host> <local> <remote> / pull <host> <remote> <local>   Copy files
  list                           List active session sockets
  disconnect <host> | --all      Close one session, or all of them   (alias: exit)
  statusline                     Compact one-line status for a Claude Code statusLine

Exit codes: 0 ok | 1 connect failed | 2 password required | 3 session down
Env: SSH_REMOTE_PERSIST (4h), SSH_REMOTE_CONNECT_TIMEOUT (15), SSH_REMOTE_SOCKET_DIR
USAGE
}

cmd_hosts() {
  ensure_dir
  local cfg="$HOME/.ssh/config" line printed=" "
  if [ -f "$RECENT_FILE" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"; printed="$printed$line "
    done < "$RECENT_FILE"
  fi
  if [ -f "$cfg" ]; then
    awk 'tolower($1)=="host"{for(i=2;i<=NF;i++){h=$i; if(h !~ /[*?!]/) print h}}' "$cfg" | sort -u | \
    while IFS= read -r line; do
      case "$printed" in *" $line "*) ;; *) printf '%s\n' "$line" ;; esac
    done
  fi
}

connect_askpass() {
  local target="$1" sock="$2"
  local pw; pw="$(cat)"
  [ -n "$pw" ] || die "no password on stdin."
  local helper; helper="$(mktemp "${TMPDIR:-/tmp}/.ssh-remote-askpass.XXXXXX")"
  printf '#!/bin/sh\nprintf "%%s\\n" "$SSH_REMOTE_PW"\n' > "$helper"; chmod 700 "$helper"
  export SSH_REMOTE_PW="$pw"
  set +e
  SSH_ASKPASS="$helper" SSH_ASKPASS_REQUIRE=force \
  ssh -M -S "$sock" \
      -o ControlPersist="$PERSIST" -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o NumberOfPasswordPrompts=1 \
      -fN "$target" </dev/null
  local rc=$?
  set -e
  unset SSH_REMOTE_PW
  rm -f "$helper" 2>/dev/null || true
  return "$rc"
}

keyless_connect() {
  local target="$1" sock="$2" err rc
  set +e
  err="$(ssh -M -S "$sock" -o BatchMode=yes \
        -o ControlPersist="$PERSIST" -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -fN "$target" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && is_up "$sock" "$target"; then return 0; fi
  rm -f "$sock" 2>/dev/null || true
  KEYLESS_CLASS="$(classify_ssh_error "$err")"
  return 1
}

cmd_connect() {
  local mode=keyless target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --password-stdin) mode=password ;;
      --interactive)    mode=interactive ;;
      *)                target="$1" ;;
    esac
    shift
  done
  if [ -z "$target" ] && [ "$mode" != "password" ]; then
    printf 'Machine to ssh into (e.g. stallion or user@host): ' >&2
    read -r target </dev/tty || true
  fi
  [ -n "$target" ] || die "no machine given."
  ensure_dir
  local sock; sock="$(socket_for "$target")"

  if is_up "$sock" "$target"; then
    record_recent "$target"; persist_host "$sock" "$target"; print_connected "$target"; return 0
  fi

  local rc=0
  case "$mode" in
    password)
      connect_askpass "$target" "$sock" || rc=$?
      if [ "$rc" -eq 0 ] && is_up "$sock" "$target"; then
        record_recent "$target"; persist_host "$sock" "$target"; print_connected "$target"; return 0
      fi
      print_failed "$target" auth; exit 1 ;;
    interactive)
      printf 'Connecting to %s - type your password if prompted...\n' "$target" >&2
      set +e
      ssh -M -S "$sock" -o ControlPersist="$PERSIST" -o ConnectTimeout="$CONNECT_TIMEOUT" \
          -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o NumberOfPasswordPrompts=3 \
          -fN "$target"
      rc=$?; set -e
      if [ "$rc" -eq 0 ] && is_up "$sock" "$target"; then
        record_recent "$target"; persist_host "$sock" "$target"; print_connected "$target"; return 0
      fi
      print_failed "$target" other; exit 1 ;;
    keyless)
      if keyless_connect "$target" "$sock"; then
        record_recent "$target"; persist_host "$sock" "$target"; print_connected "$target"; return 0
      fi
      if [ "${KEYLESS_CLASS:-other}" = "auth" ]; then
        printf '%s\n' "${C_YEL}PASSWORD_REQUIRED${C_OFF} - $target needs a password (no usable SSH key)."
        exit 2
      fi
      print_failed "$target" "${KEYLESS_CLASS:-other}"; exit 1 ;;
  esac
}

cmd_run() {
  local target="${1:-}"; shift || true
  [ -n "$target" ] || die "usage: ssh-remote run <[user@]host> <command...>"
  [ "$#" -gt 0 ] || die "no command given"
  local sock; sock="$(socket_for "$target")"
  if ! is_up "$sock" "$target"; then session_down_banner "$target"; exit 3; fi
  ssh -S "$sock" -o BatchMode=yes "$target" "$*"
}

cmd_shell() {
  local target="${1:-}"; [ -n "$target" ] || die "usage: ssh-remote shell <[user@]host>"
  local sock; sock="$(socket_for "$target")"
  is_up "$sock" "$target" || { session_down_banner "$target"; exit 3; }
  exec ssh -S "$sock" -t "$target"
}

cmd_push() {
  local target="${1:-}" lp="${2:-}" rp="${3:-}"
  [ -n "$target" ] && [ -n "$lp" ] && [ -n "$rp" ] || die "usage: ssh-remote push <host> <local> <remote>"
  local sock; sock="$(socket_for "$target")"
  is_up "$sock" "$target" || { session_down_banner "$target"; exit 3; }
  scp -o ControlPath="$sock" -o BatchMode=yes "$lp" "$target:$rp"
}
cmd_pull() {
  local target="${1:-}" rp="${2:-}" lp="${3:-}"
  [ -n "$target" ] && [ -n "$rp" ] && [ -n "$lp" ] || die "usage: ssh-remote pull <host> <remote> <local>"
  local sock; sock="$(socket_for "$target")"
  is_up "$sock" "$target" || { session_down_banner "$target"; exit 3; }
  scp -o ControlPath="$sock" -o BatchMode=yes "$target:$rp" "$lp"
}

status_line() {
  local target="$1" sock="$2"
  if is_up "$sock" "$target"; then
    printf '  %s%sLIVE%s   %s\n' "$C_GREEN" "$C_BOLD" "$C_OFF" "$target"
  else
    printf '  %s%sDOWN%s   %s %s(dropped or timed out - reconnect)%s\n' "$C_RED" "$C_BOLD" "$C_OFF" "$target" "$C_DIM" "$C_OFF"
  fi
}
cmd_status() {
  ensure_dir
  local target="${1:-}"
  if [ -n "$target" ]; then
    printf '%s\n' "${C_BOLD}SSH session:${C_OFF}"
    status_line "$target" "$(socket_for "$target")"; return 0
  fi
  shopt -s nullglob
  local socks=("$SOCKET_DIR"/*.sock)
  if [ "${#socks[@]}" -eq 0 ]; then
    printf '%s\n' "${C_DIM}No SSH sessions. Connect with /ssh-remote.${C_OFF}"; return 0
  fi
  printf '%s\n' "${C_BOLD}SSH sessions:${C_OFF}"
  local s host
  for s in "${socks[@]}"; do
    host=""; [ -f "$s.host" ] && host="$(cat "$s.host")"
    [ -n "$host" ] || { host="${s##*/}"; host="${host%.sock}"; }
    status_line "$host" "$s"
  done
}

cmd_check() {
  local target="${1:-}"; [ -n "$target" ] || die "usage: ssh-remote check <[user@]host>"
  is_up "$(socket_for "$target")" "$target"
}

cmd_list() {
  ensure_dir
  shopt -s nullglob
  local socks=("$SOCKET_DIR"/*.sock)
  if [ "${#socks[@]}" -eq 0 ]; then echo "(no active sessions)"; return 0; fi
  printf '%s\n' "${socks[@]}"
}

cmd_disconnect() {
  ensure_dir
  if [ "${1:-}" = "--all" ] || [ "${1:-}" = "-a" ]; then
    shopt -s nullglob
    local socks=("$SOCKET_DIR"/*.sock) any=0 s host
    for s in ${socks[@]+"${socks[@]}"}; do
      any=1; host=""; [ -f "$s.host" ] && host="$(cat "$s.host")"
      [ -n "$host" ] && ssh -S "$s" -O exit "$host" >/dev/null 2>&1 || true
      rm -f "$s" "$s.host"
    done
    [ "$any" -eq 1 ] && printf '%s\n' "${C_GREEN}Disconnected all SSH sessions.${C_OFF}" || echo "No active sessions."
    return 0
  fi
  local target="${1:-}"; [ -n "$target" ] || die "usage: ssh-remote disconnect <[user@]host> | --all"
  local sock; sock="$(socket_for "$target")"
  if is_up "$sock" "$target"; then
    ssh -S "$sock" -O exit "$target" >/dev/null 2>&1 || true
    printf '%s\n' "${C_GREEN}Disconnected from $target.${C_OFF}"
  else
    printf 'No live session for %s.\n' "$target"
  fi
  rm -f "$sock" "$sock.host"
}

cmd_statusline() {
  ensure_dir
  shopt -s nullglob
  local socks=("$SOCKET_DIR"/*.sock) out="" s host
  for s in ${socks[@]+"${socks[@]}"}; do
    host=""; [ -f "$s.host" ] && host="$(cat "$s.host")"; host="${host:-?}"
    if is_up "$s" "$host"; then out="$out up:$host"; else out="$out down:$host"; fi
  done
  [ -n "$out" ] && printf 'ssh:%s' "$out" || true
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    hosts)            cmd_hosts "$@" ;;
    connect)          cmd_connect "$@" ;;
    status)           cmd_status "$@" ;;
    check)            cmd_check "$@" ;;
    run)              cmd_run "$@" ;;
    shell)            cmd_shell "$@" ;;
    push)             cmd_push "$@" ;;
    pull)             cmd_pull "$@" ;;
    list)             cmd_list "$@" ;;
    disconnect|exit)  cmd_disconnect "$@" ;;
    statusline)       cmd_statusline "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
