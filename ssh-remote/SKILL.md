---
name: ssh-remote
description: >-
  SSH into a remote machine from THIS local Claude Code session and operate on
  it, so you keep using your own Claude account instead of the remote user's.
  Use whenever the user wants to ssh into a host / work on a remote server / run
  or edit things on another computer. Takes the host and password as command
  arguments, connects with no terminal, then reuses the connection. CLI only.
argument-hint: <host> [password]
allowed-tools: Bash(ssh-remote:*)
---

# ssh-remote

Your local Claude (your account) operates a remote machine over a persistent
SSH connection. `ssh-remote` commands are pre-approved — run them directly. No
terminal, no paste.

## Input comes from the arguments. Do NOT ask in chat. Do NOT use AskUserQuestion.

Arguments: `$ARGUMENTS`

Parse them: the **first whitespace token is `HOST`**; **everything after the
first space is `PASSWORD`** (verbatim, may contain spaces, may be empty). If the
skill was triggered by a natural-language message instead of `/ssh-remote`, take
`HOST` and `PASSWORD` from that message the same way.

- **No host found** → reply exactly this, then stop:
  `Run it like:  /ssh-remote <host> <password>   (or  /ssh-remote <host>  for key auth)`
- **Host found** → connect right away as your FIRST action (no preamble):
  - Password present → quoted heredoc (any characters survive):
    ```bash
    ssh-remote connect --password-stdin HOST <<'SSHPW'
    PASSWORD
    SSHPW
    ```
  - No password → `ssh-remote connect HOST`
    (if it prints `PASSWORD_REQUIRED`, reply `That host needs a password — run /ssh-remote HOST <password>` and stop.)

Report in **one line**: `Connected to HOST` on `CONNECTED`, else the failure
reason (wrong password / unreachable / timed out) on `NOT CONNECTED`.

## Remote mode — everything runs on the host
A successful connect **auto-engages remote mode** (the connect output says
`REMOTE MODE on`). While it is on, a guard blocks plain local shell commands, so
**run everything through `ssh-remote run HOST '...'`** — that is what makes it
execute on the remote, not your laptop. (`Read`/`Edit`/`Write` still act locally;
only the `Bash` tool is gated.)

If a `Bash` call is blocked with `Locked to remote host`, that is expected: re-issue
it as `ssh-remote run HOST '<that command>'`. Only run `ssh-remote remote-mode off`
if the user explicitly asks to do local work. Check state with
`ssh-remote remote-mode status`.

## Operate on the remote
```bash
ssh-remote run HOST 'uname -a && whoami'
ssh-remote run HOST 'cat /path/file'             # read
ssh-remote run HOST 'cat > /path/file' <<'EOF'   # write
contents
EOF
ssh-remote push HOST ./a /remote/b   |   ssh-remote pull HOST /remote/b ./a
```
If a command prints **`SSH SESSION DOWN`** (exit 3): STOP, tell the user the
session dropped/timed out, offer to reconnect with `/ssh-remote HOST`. Check any
time with `ssh-remote status`. Real TTY (editor/top/sudo): `! ssh-remote shell HOST`.

The session also expires on its own after ~4h idle. When it does, the Claude Code
**status line** flips to `NOT CONNECTED to remote host HOST` (always visible), and
the next `ssh-remote run` returns `SSH SESSION DOWN`. On either signal, tell the
user it expired and offer `/ssh-remote HOST` to reconnect.

## Exit
`ssh-remote disconnect HOST` (one) · `ssh-remote disconnect --all` (everything).

## Rules
Ask before destructive remote commands. Reuse the exact HOST string from connect.
Security (only if asked): the password reaches `ssh` via this session — never on
disk or in argv, but visible in the transcript; SSH keys avoid that.
