#!/usr/bin/env bash
# install.sh — install debug-kit as a Claude Code skill.
#   bash install.sh           # symlink this checkout into ~/.claude/skills/debug-kit
#   bash install.sh --copy    # copy the files instead of symlinking
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/debug-kit"
MODE="${1:-symlink}"

mkdir -p "$(dirname "$DEST")"

if [[ -e "$DEST" || -L "$DEST" ]]; then
    echo "Backing up existing $DEST → $DEST.bak.$(date +%s)"
    mv "$DEST" "$DEST.bak.$(date +%s)"
fi

if [[ "$MODE" == "--copy" || "$MODE" == "copy" ]]; then
    cp -R "$SRC" "$DEST"
    # don't copy VCS/meta into the skill dir
    rm -rf "$DEST/.git" "$DEST/install.sh" 2>/dev/null || true
    echo "Copied debug-kit → $DEST"
else
    ln -s "$SRC" "$DEST"
    echo "Symlinked debug-kit → $DEST"
fi

echo
echo "Done. In Claude Code the 'debug-kit' skill is now available."
echo "macOS: grant Accessibility + Screen Recording to your terminal, then relaunch it."
