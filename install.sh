#!/usr/bin/env bash
# install.sh: copy the guards into ~/.claude/hooks/agent-guardrails and add
# them to ~/.claude/settings.json, leaving everything already there alone.
#
#   ./install.sh                       the four guards
#   ./install.sh --with-custom-rules   also custom-bash-rules.sh (your own rules)
#   ./install.sh --dry-run             show what would change, change nothing
#   ./install.sh --claude-dir DIR      use DIR instead of ~/.claude
#
# Safe to run again: the guard scripts are refreshed, entries already in
# settings.json are not added twice, and settings.json is only rewritten (after
# a backup copy) when something actually changes.
set -eu

KIT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
WITH_CUSTOM=0
DRY_RUN=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --with-custom-rules) WITH_CUSTOM=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --claude-dir)
      [ $# -ge 2 ] || { echo "agent-guardrails: --claude-dir needs a folder" >&2; exit 1; }
      CLAUDE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-guardrails: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "agent-guardrails: python3 is needed (the guards and this installer use it)" >&2; exit 1; }

# Always an absolute, tidy path: the hook commands written to settings.json
# must work from any directory, and "dir/" must mean the same place as "dir".
CLAUDE_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CLAUDE_DIR")"

SETTINGS="$CLAUDE_DIR/settings.json"
DEST="$CLAUDE_DIR/hooks/agent-guardrails"
CORE="block-dangerous-git.sh block-catastrophic-rm.sh block-recursive-replace.sh limit-agent-fanout.sh"
CUSTOM="custom-bash-rules.sh"

# Refuse before touching anything if settings.json cannot be merged safely.
python3 "$KIT/lib/settings.py" check "$SETTINGS"

echo "agent-guardrails: installing into $DEST"

if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$DEST"
  for name in $CORE; do
    cp "$KIT/hooks/$name" "$DEST/$name"
    chmod 755 "$DEST/$name"
    echo "  copied: $name"
  done
  if [ "$WITH_CUSTOM" = 1 ]; then
    if [ -e "$DEST/$CUSTOM" ]; then
      echo "  kept your existing copy: $CUSTOM"
    else
      cp "$KIT/hooks/$CUSTOM" "$DEST/$CUSTOM"
      chmod 755 "$DEST/$CUSTOM"
      echo "  copied: $CUSTOM"
    fi
  fi
else
  echo "  dry run: no files copied"
fi

set -- block-dangerous-git.sh=Bash block-catastrophic-rm.sh=Bash block-recursive-replace.sh=Bash "limit-agent-fanout.sh=Agent|Task"
if [ "$WITH_CUSTOM" = 1 ]; then
  set -- "$@" "$CUSTOM=Bash"
fi

if [ "$DRY_RUN" = 1 ]; then
  python3 "$KIT/lib/settings.py" add "$SETTINGS" "$DEST" --dry-run "$@"
else
  python3 "$KIT/lib/settings.py" add "$SETTINGS" "$DEST" "$@"
  echo "agent-guardrails: done. In Claude Code, type /hooks to see the guards listed."
fi
