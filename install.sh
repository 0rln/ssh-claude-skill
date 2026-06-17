#!/usr/bin/env bash
# Install the ssh-remote Claude Code skill from GitHub, no clone needed.
#
#   curl -fsSL https://raw.githubusercontent.com/0rln/ssh-claude-skill/main/install.sh | bash
#
set -euo pipefail

REPO="0rln/ssh-claude-skill"
REF="${SSH_CLAUDE_REF:-main}"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
BIN_DIR="${SSH_CLAUDE_BIN_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { say "error: curl is required"; exit 1; }
command -v tar  >/dev/null 2>&1 || { say "error: tar is required";  exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Downloading $REPO@$REF ..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" \
  | tar -xzf - -C "$tmp"

src="$tmp/$(ls "$tmp")/ssh-remote"
[ -d "$src" ] || { say "error: ssh-remote/ not found in download"; exit 1; }

say "Installing skill -> $SKILLS_DIR/ssh-remote"
mkdir -p "$SKILLS_DIR"
rm -rf "$SKILLS_DIR/ssh-remote"
cp -R "$src" "$SKILLS_DIR/ssh-remote"
chmod +x "$SKILLS_DIR/ssh-remote/scripts/ssh-remote.sh"

say "Linking CLI    -> $BIN_DIR/ssh-remote"
mkdir -p "$BIN_DIR"
ln -sfn "$SKILLS_DIR/ssh-remote/scripts/ssh-remote.sh" "$BIN_DIR/ssh-remote"

say ""
say "Done. The /ssh-remote skill is installed."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "Note: add $BIN_DIR to your PATH:"
     say "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
