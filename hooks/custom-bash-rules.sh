#!/usr/bin/env bash
# custom-bash-rules.sh
# Claude Code PreToolUse(Bash) guardrail. A place for YOUR OWN rules: the
# things you have told an agent more than once and want enforced instead of
# remembered. One script, several rules, so every Bash call spawns one process.
# Fail-open: any problem parsing the hook input exits 0. Exit 2 blocks and
# shows the message to the agent.
#
# This file is yours to edit. install.sh copies it once and never overwrites
# your copy afterwards.
#
# HOW TO WRITE A RULE
#   echo "$norm" | grep -Eq '<extended regex>' \
#     && block "<short-rule-name>" "<what to do instead, in one or two sentences>"
# $norm is the command with every run of whitespace squeezed to one space.
# Say what to do instead: the agent reads the message and acts on it.
#
# Two things learned the hard way:
#   1. Anchor a rule to COMMAND POSITION, (^|[;&|] ?) in front of the program
#      name, when the word also turns up in prose. An unanchored rule once
#      blocked a command whose quoted prompt text merely mentioned the banned
#      tool.
#   2. A rule here can only add a block. Keep each one an independent
#      `grep && block` line so adding a rule never loosens another.
LOG="$HOME/.claude/logs/agent-guardrails.log"
mkdir -p "$HOME/.claude/logs" 2>/dev/null

input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

norm="$(printf '%s' "$cmd" | tr -s "[:space:]" " ")"

block() {
  echo "$(date '+%F %T') custom-bash-rules BLOCK $1" >> "$LOG" 2>/dev/null
  printf 'BLOCKED by custom-bash-rules (%s): %s\n' "$1" "$2" >&2
  printf 'Command: %s\n' "$cmd" >&2
  exit 2
}

# Rule no-release-sideload: never adb-install a release build onto a device.
# Release builds go out through the store's test track; a sideloaded one is
# easy to mistake for the shipped app. Debug builds are fine.
echo "$norm" | grep -Eq 'adb( -s [^ ]+)? (shell pm )?install[^&|;]*[Rr]elease' \
  && block "no-release-sideload" "Never sideload RELEASE builds. Upload the build to the store's internal test track instead. Debug builds are fine."

# EXAMPLE, switched off. A rule anchored to command position: ban a deploy tool
# this machine must never use (here the made-up `othercli`), and its install.
# Because of the (^|[;&|] ?) anchor, `echo "we do not use othercli deploy"`
# still passes. To switch it on, delete the `#EXAMPLE ` prefix from both lines
# and replace othercli with the real name.
#EXAMPLE echo "$norm" | grep -Eq '(^|[;&|] ?)(npx +)?othercli +(deploy|init|dev|link|login|build)|(^|[;&|] ?)(npm (i|install)( -g)?|brew install|pnpm add|yarn (global )?add) [^&|;]*othercli' \
#EXAMPLE   && block "no-othercli" "othercli is not used here. Deploy with the project's own deploy command."

exit 0
