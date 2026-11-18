#!/usr/bin/env bash
# uninstall.sh: take this kit's entries out of ~/.claude/settings.json and
# delete the guard scripts it installed. Everything else is left alone.
#
#   ./uninstall.sh                  remove the guards
#   ./uninstall.sh --purge          also delete an edited custom-bash-rules.sh
#   ./uninstall.sh --dry-run        show what would change, change nothing
#   ./uninstall.sh --claude-dir DIR use DIR instead of ~/.claude
#
# settings.json is only rewritten (after a backup copy) when it holds entries
# of this kit. The log files under ~/.claude/logs are not touched.
set -eu

KIT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
PURGE=0
DRY_RUN=0

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --claude-dir)
      [ $# -ge 2 ] || { echo "agent-guardrails: --claude-dir needs a folder" >&2; exit 1; }
      CLAUDE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-guardrails: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || { echo "agent-guardrails: python3 is needed" >&2; exit 1; }

# The same absolute, tidy path install.sh used.
CLAUDE_DIR="$(python3 -c 'import os, sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CLAUDE_DIR")"

SETTINGS="$CLAUDE_DIR/settings.json"
DEST="$CLAUDE_DIR/hooks/agent-guardrails"
CORE="block-dangerous-git.sh block-catastrophic-rm.sh block-recursive-replace.sh limit-agent-fanout.sh"
CUSTOM="custom-bash-rules.sh"

echo "agent-guardrails: removing from $CLAUDE_DIR"

# Settings first: an entry must never point at a script that is already gone.
# Only entries that run one of these five scripts are removed; anything else
# you keep in that folder stays in settings.json.
set -- block-dangerous-git.sh block-catastrophic-rm.sh block-recursive-replace.sh limit-agent-fanout.sh "$CUSTOM"
if [ "$DRY_RUN" = 1 ]; then
  python3 "$KIT/lib/settings.py" remove "$SETTINGS" "$DEST" --dry-run "$@"
  echo "  dry run: no files deleted"
  exit 0
fi
python3 "$KIT/lib/settings.py" remove "$SETTINGS" "$DEST" "$@"

if [ -d "$DEST" ]; then
  for name in $CORE; do
    if [ -e "$DEST/$name" ]; then
      rm -f -- "$DEST/$name"
      echo "  deleted: $name"
    fi
  done
  if [ -e "$DEST/$CUSTOM" ]; then
    if [ "$PURGE" = 1 ] || cmp -s "$DEST/$CUSTOM" "$KIT/hooks/$CUSTOM"; then
      rm -f -- "$DEST/$CUSTOM"
      echo "  deleted: $CUSTOM"
    else
      echo "  kept: $DEST/$CUSTOM (you edited it; --purge deletes it too)"
    fi
  fi
  # Only goes if it is empty: anything else you put there stays.
  if rmdir "$DEST" 2>/dev/null; then
    echo "  deleted: $DEST"
  fi
fi

echo "agent-guardrails: done."
