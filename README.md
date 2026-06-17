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

```bash
ln -sfn "$PWD/ssh-remote" "$HOME/.claude/skills/ssh-remote"
ln -sfn "$PWD/ssh-remote/scripts/ssh-remote.sh" "$HOME/.local/bin/ssh-remote"
```

Needs the OpenSSH client (8.4+) and `~/.local/bin` on your `PATH`. CLI only.

## Notes

- Tries your SSH key first; only asks for a password if it has to.
- Passwords go straight to `ssh` (never written to disk or a command line), but
  they do pass through the session transcript. Use key auth for zero exposure.
- Connection state is always clear: `CONNECTED`, `NOT CONNECTED` (with the
  reason), and a loud `SSH SESSION DOWN` if it drops or times out.
