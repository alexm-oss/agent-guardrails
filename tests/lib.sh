#!/usr/bin/env bash
# Shared helpers for the hook tests. Source this file; do not run it.
#
# Every hook runs with HOME pointed at a throwaway directory, so no test ever
# reads or writes the real ~/.claude. No test runs git, rm, sed or an agent:
# each one only pipes a sample tool call into a hook and reads the exit code.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${HOOKS_DIR:-$KIT_DIR/hooks}"

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-guardrails-test.XXXXXX" 2>/dev/null)" || TEST_HOME=""
# Stop here if there is no temporary folder. Carrying on with an empty value
# would point the hooks, and the cleanup below, at the current directory.
if [ -z "$TEST_HOME" ] || [ ! -d "$TEST_HOME" ]; then
  echo "cannot create a temporary folder under ${TMPDIR:-/tmp}; no test was run" >&2
  exit 1
fi
# macOS hands out /var/... paths that are links into /private/var; use the real one.
TEST_HOME="$(cd "$TEST_HOME" && pwd -P)"

# Deletes only a folder this file created: the name must carry the mktemp prefix.
cleanup() {
  case "${TEST_HOME:-}" in
    */agent-guardrails-test.*)
      if [ -d "$TEST_HOME" ]; then
        rm -rf -- "$TEST_HOME"
      fi
      ;;
  esac
}
trap cleanup EXIT

pass=0
fail=0

# bash_call COMMAND [CWD] -> the JSON Claude Code sends a PreToolUse(Bash) hook.
bash_call() {
  python3 -c '
import sys, json
d = {
    "session_id": "test-session",
    "hook_event_name": "PreToolUse",
    "permission_mode": "default",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1]},
}
if sys.argv[2]:
    d["cwd"] = sys.argv[2]
print(json.dumps(d))' "$1" "${2:-}"
}

# run_hook HOOK COMMAND [CWD] -> prints the hook exit code.
run_hook() {
  bash_call "$2" "${3:-}" | HOME="$TEST_HOME" bash "$1" >/dev/null 2>&1
  echo $?
}

# run_raw HOOK STDIN_TEXT -> prints the hook exit code for arbitrary stdin.
run_raw() {
  printf '%s' "$2" | HOME="$TEST_HOME" bash "$1" >/dev/null 2>&1
  echo $?
}

# must_block COMMAND [CWD] / must_allow COMMAND [CWD], against $HOOK.
must_block() {
  local r
  r=$(run_hook "$HOOK" "$1" "${2:-}")
  if [ "$r" = "2" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "HOLE (exit $r, must block): $1"
  fi
}

must_allow() {
  local r
  r=$(run_hook "$HOOK" "$1" "${2:-}")
  if [ "$r" = "0" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FALSE POSITIVE (exit $r, must allow): $1"
  fi
}

# check DESCRIPTION EXPECTED ACTUAL
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected '$2', got '$3')"
  fi
}

# A hook must never block because its input is broken: fail open.
must_fail_open() {
  check "empty stdin is allowed" 0 "$(run_raw "$HOOK" '')"
  check "non-JSON stdin is allowed" 0 "$(run_raw "$HOOK" 'this is not json')"
  check "JSON without a command is allowed" 0 "$(run_raw "$HOOK" '{"tool_name":"Bash","tool_input":{}}')"
  check "JSON with an empty command is allowed" 0 "$(run_raw "$HOOK" '{"tool_name":"Bash","tool_input":{"command":""}}')"
}

finish() {
  echo "pass=$pass fail=$fail"
  [ "$fail" = "0" ]
}
