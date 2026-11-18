#!/usr/bin/env bash
# limit-agent-fanout.sh
# Claude Code PreToolUse(Agent|Task) guardrail. Stops runaway subagent fan-out.
# Why: a single review task once spawned a fleet of about 55 subagents and
# burned most of a usage quota in one go. The first reaction was to ban
# subagents outright, which was an over-correction: deliberate use is fine and
# often right (a reviewer, a dedicated driver for one window, a small
# pipeline). The real harm is a fleet-scale BURST, so that is all this blocks.
#
# Rule: once LIMIT dispatches have happened inside a rolling WINDOW, the next
# one is refused. The count is shared by every Claude Code session of this user
# on this machine, because they all draw on the same quota.
#
# Deliberate override for an intentional larger run:
#   touch /tmp/claude-agents-ok     (grants 30 minutes, then expires)
#
# Settings, read from the environment the hook runs in:
#   AGENT_FANOUT_LIMIT    dispatches allowed per window    (default 8)
#   AGENT_FANOUT_WINDOW   window length in seconds         (default 900)
#   AGENT_FANOUT_FLAG     override flag file               (default /tmp/claude-agents-ok)
LOG="$HOME/.claude/logs/agent-guardrails.log"
CNT="$HOME/.claude/logs/agent-dispatch.log"
mkdir -p "$HOME/.claude/logs" 2>/dev/null
FLAG="${AGENT_FANOUT_FLAG:-/tmp/claude-agents-ok}"
WINDOW="${AGENT_FANOUT_WINDOW:-900}"   # 15 minutes
LIMIT="${AGENT_FANOUT_LIMIT:-8}"       # this many dispatches already in the window = runaway fleet
case "$WINDOW" in ''|*[!0-9]*) WINDOW=900 ;; esac
case "$LIMIT" in ''|*[!0-9]*) LIMIT=8 ;; esac
# Read both as base 10, so a leading zero ("0900") is not taken for octal.
WINDOW=$((10#$WINDOW))
LIMIT=$((10#$LIMIT))
now=$(date +%s)
# The hook input is not read: the decision depends only on the dispatch count.

# File modification time in epoch seconds. GNU stat (Linux) is tried first,
# then BSD stat (macOS); only an all-digit answer is accepted, because each one
# prints something else when handed the other's option.
mtime() {
  local t
  for t in "$(stat -c %Y "$1" 2>/dev/null)" "$(stat -f %m "$1" 2>/dev/null)"; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    echo "$t"
    return
  done
  echo 0
}

# Explicit override flag bypasses the burst guard entirely.
if [ -f "$FLAG" ]; then
  mt=$(mtime "$FLAG")
  if [ $(( now - mt )) -lt 1800 ]; then
    echo "$(date '+%F %T') limit-agent-fanout ALLOW override-flag" >> "$LOG"
    echo "$now" >> "$CNT"
    exit 0
  fi
fi

# Count recent dispatches in the rolling window.
recent=0
if [ -f "$CNT" ]; then
  recent=$(awk -v n="$now" -v w="$WINDOW" '$1 >= n-w {c++} END{print c+0}' "$CNT")
fi

if [ "$recent" -ge "$LIMIT" ]; then
  echo "$(date '+%F %T') limit-agent-fanout BLOCK burst recent=$recent" >> "$LOG"
  cat >&2 <<MSG
BLOCKED by limit-agent-fanout: $recent agent dispatches in the last $(( WINDOW / 60 )) minutes is
fleet-scale fan-out. Deliberate single or small subagent use is fine and was not blocked;
this is a burst. Do the remaining work in this session, in sequence, or with a script.
If this larger run is intentional and the user has approved it: touch $FLAG
MSG
  exit 2
fi

echo "$(date '+%F %T') limit-agent-fanout ALLOW recent=$recent" >> "$LOG"
echo "$now" >> "$CNT"
exit 0
