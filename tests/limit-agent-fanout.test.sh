#!/usr/bin/env bash
# Tests for hooks/limit-agent-fanout.sh.
# No agent is started: each case only pipes a sample Agent tool call into the
# hook. The dispatch count and the override flag live in the throwaway home, so
# a real /tmp/claude-agents-ok on this machine is neither read nor created.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
HOOK="$HOOKS_DIR/limit-agent-fanout.sh"
CNT="$TEST_HOME/.claude/logs/agent-dispatch.log"
FLAG="$TEST_HOME/agents-ok-flag"
CALL='{"session_id":"test-session","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"review the diff","prompt":"Review the diff.","subagent_type":"general-purpose"}}'

# dispatch [VAR=value ...] -> prints the hook exit code for one Agent call.
dispatch() {
  printf '%s' "$CALL" | env HOME="$TEST_HOME" AGENT_FANOUT_FLAG="$FLAG" "$@" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

reset_count() { rm -f -- "$CNT" "$FLAG"; }
count_lines() { if [ -f "$CNT" ]; then wc -l < "$CNT" | tr -d ' '; else echo 0; fi; }

# ---------- default limit: 8 in the window pass, the 9th is refused ----------
reset_count
for i in 1 2 3 4 5 6 7 8; do
  check "dispatch $i of 8 is allowed" 0 "$(dispatch)"
done
check "dispatch 9 is blocked" 2 "$(dispatch)"
check "dispatch 10 is blocked" 2 "$(dispatch)"
check "blocked dispatches are not counted" 8 "$(count_lines)"

# ---------- dispatches older than the window do not count ----------
reset_count
mkdir -p "$(dirname "$CNT")"
old=$(( $(date +%s) - 1000 ))
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "$old" >> "$CNT"; done
check "12 dispatches from before the window do not block" 0 "$(dispatch)"

# ---------- the override flag ----------
reset_count
for i in 1 2 3 4 5 6 7 8; do dispatch >/dev/null; done
check "over the limit without the flag is blocked" 2 "$(dispatch)"
touch "$FLAG"
check "a fresh override flag allows the dispatch" 0 "$(dispatch)"
check "a dispatch under the flag is still counted" 9 "$(count_lines)"
# Age the flag to 31 minutes: the grant lasts 30.
python3 -c 'import os, sys, time; t = time.time() - 31 * 60; os.utime(sys.argv[1], (t, t))' "$FLAG"
check "a flag older than 30 minutes no longer allows" 2 "$(dispatch)"

# ---------- settings from the environment ----------
reset_count
check "limit 2: first allowed" 0 "$(dispatch AGENT_FANOUT_LIMIT=2)"
check "limit 2: second allowed" 0 "$(dispatch AGENT_FANOUT_LIMIT=2)"
check "limit 2: third blocked" 2 "$(dispatch AGENT_FANOUT_LIMIT=2)"
check "a short window forgets the earlier two" 0 "$(sleep 2; dispatch AGENT_FANOUT_LIMIT=2 AGENT_FANOUT_WINDOW=1)"

reset_count
for i in 1 2 3 4 5 6 7 8; do dispatch AGENT_FANOUT_LIMIT=nonsense >/dev/null; done
check "a nonsense limit falls back to 8" 2 "$(dispatch AGENT_FANOUT_LIMIT=nonsense)"

# ---------- numbers with a leading zero are decimal, not octal ----------
reset_count
check "window 0900 and limit 08: first dispatch allowed" 0 "$(dispatch AGENT_FANOUT_WINDOW=0900 AGENT_FANOUT_LIMIT=08)"
for i in 2 3 4 5 6 7 8; do dispatch AGENT_FANOUT_WINDOW=0900 AGENT_FANOUT_LIMIT=08 >/dev/null; done
check "window 0900 and limit 08: ninth dispatch blocked" 2 "$(dispatch AGENT_FANOUT_WINDOW=0900 AGENT_FANOUT_LIMIT=08)"
msg="$(printf '%s' "$CALL" | env HOME="$TEST_HOME" AGENT_FANOUT_FLAG="$FLAG" AGENT_FANOUT_WINDOW=0900 AGENT_FANOUT_LIMIT=08 bash "$HOOK" 2>&1 >/dev/null)"
check "the block message says 15 minutes" yes "$(echo "$msg" | grep -q 'in the last 15 minutes' && echo yes || echo no)"
check "the block message carries no shell error" 0 "$(echo "$msg" | grep -c 'value too great')"

# ---------- the hook does not wait for input ----------
reset_count
check "run with no input at all, it still answers" 0 "$(env HOME="$TEST_HOME" AGENT_FANOUT_FLAG="$FLAG" bash "$HOOK" </dev/null >/dev/null 2>&1; echo $?)"

# ---------- broken input never blocks ----------
reset_count
check "empty stdin is allowed" 0 "$(printf '' | HOME="$TEST_HOME" AGENT_FANOUT_FLAG="$FLAG" bash "$HOOK" >/dev/null 2>&1; echo $?)"
check "non-JSON stdin is allowed" 0 "$(printf 'not json' | HOME="$TEST_HOME" AGENT_FANOUT_FLAG="$FLAG" bash "$HOOK" >/dev/null 2>&1; echo $?)"

finish
