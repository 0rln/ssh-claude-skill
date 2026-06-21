# ssh-claude

A Claude Code skill for working on a remote machine without losing your Claude account.


When you SSH into a box and run `claude` there, you're using *that machine's*
Claude login - usually whoever owns the server, not you. So you either can't use
Claude on remote work, or you end up on someone else's account.

## Use it

```
/ssh-remote <host> [password]
```

Type it right on the command line — as you type `/ssh-remote`, a hint shows
`<host> [password]`, so there's no second prompt and nothing to navigate. It
connects (no terminal, nothing to paste) and then runs whatever you need on the
remote for you. Leave the password off for key-auth hosts. Say "disconnect" when
you're done.

## Install

Quick install (no clone needed):

```bash
curl -fsSL https://raw.githubusercontent.com/0rln/ssh-claude-skill/main/install.sh | bash
```

Or, from a clone, symlink it in place:

```bash
ln -sfn "$PWD/ssh-remote" "$HOME/.claude/skills/ssh-remote"
ln -sfn "$PWD/ssh-remote/scripts/ssh-remote.sh" "$HOME/.local/bin/ssh-remote"
```

Needs the OpenSSH client (8.4+) and `~/.local/bin` on your `PATH`. CLI only.

## Status line & remote mode

Two extras make the remote session visible and safe. Add them to
`~/.claude/settings.json` (merge into your existing keys):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.local/bin/ssh-remote statusline",
    "padding": 0,
    "refreshInterval": 10
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command",
            "command": "~/.claude/skills/ssh-remote/scripts/remote-mode-guard.sh" }
        ]
      }
    ]
  }
}
```

- **Status indicator (knows when it expires).** The status line always shows the
  remote state in plain words: `connected to HOST` while live, and
  `NOT CONNECTED to HOST — reconnect: /ssh-remote HOST` the moment the
  session drops or times out (≈4h idle). No need to run a command to find out.
- **Remote mode (everything runs on the host).** A successful connect auto-engages
  remote mode. While it is on, the `PreToolUse` guard blocks plain local shell
  commands and tells Claude to route them through `ssh-remote run HOST '...'` — so
  *everything* runs on the remote, not your laptop. `Read`/`Edit`/`Write` still work
  locally; only `Bash` is gated. Turn it off any time with
  `ssh-remote remote-mode off`, or set `SSH_REMOTE_AUTO_LOCK=0` to not auto-engage.
  Disconnecting releases it automatically.

## Notes

- Tries your SSH key first; only asks for a password if it has to.
- Passwords go straight to `ssh` (never written to disk or a command line), but
  they do pass through the session transcript. Use key auth for zero exposure.
- Connection state is always clear: `CONNECTED`, `NOT CONNECTED` (with the
  reason), a loud `SSH SESSION DOWN` if it drops, and the always-on status line.
- The remote-mode guard fails **open**: if anything goes wrong it lets the command
  run, so a bug can never lock you out of your own shell. The lock is per machine
  (it affects all Claude sessions for your user) — `ssh-remote remote-mode off`
  clears it.
