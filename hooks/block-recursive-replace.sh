#!/usr/bin/env bash
# block-recursive-replace.sh
# Claude Code PreToolUse(Bash) guardrail. Blocks recursive in-place
# find-and-replace: a sed or perl -i fed by find, xargs, grep or rg.
# Why: one unscoped substitution of a short string, run from a parent folder,
# rewrote dozens of unrelated projects at once, including dependency folders,
# virtual environments, generated reports and vendored library files. None of
# it was reviewable and little of it was in version control.
# Exit 2 = block and show the message to the agent. Exit 0 = allow.
# Fail-open: if the hook input cannot be parsed, the command is allowed.

set -u
input="$(cat)"

cmd="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null)"

[ -z "$cmd" ] && exit 0

match=""
if echo "$cmd" | grep -qE 'find[[:space:]][^|]*-exec[[:space:]]+(sed|perl)[[:space:]]+-[pi]*i'; then
  match="find ... -exec sed/perl -i"
elif echo "$cmd" | grep -qE 'xargs[[:space:]]+(sed|perl)[[:space:]]+-[pi]*i'; then
  match="... | xargs sed/perl -i"
elif echo "$cmd" | grep -qE '(sed|perl)[[:space:]]+-[pi]*i[[:space:]]+[^|]*\$\((find|grep|rg)'; then
  match="sed/perl -i ... \$(find|grep|rg ...)"
elif echo "$cmd" | grep -qE '(sed|perl)[[:space:]]+-[pi]*i[[:space:]]+[^|]*`(find|grep|rg)'; then
  match="sed/perl -i ... \`find|grep|rg ...\`"
fi

if [ -n "$match" ]; then
  printf 'BLOCKED by block-recursive-replace: recursive in-place replacement pattern detected ("%s").\n' "$match" >&2
  printf 'Command: %s\n' "$cmd" >&2
  printf 'An unscoped substitution like this can rewrite every project, dependency folder and generated file under the starting directory in one pass. For a broad find and replace: scope it to one directory with an explicit file list, use git-aware edits, or break it into reviewable Edit tool calls. If this exact command is really what is wanted, ask the user to run it themselves.\n' >&2
  exit 2
fi
exit 0
