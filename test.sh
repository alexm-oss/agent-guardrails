#!/usr/bin/env bash
# test.sh: run every check in the kit.
# Nothing here touches your real ~/.claude, runs git or rm against your files,
# or starts an agent. Hooks, installer and uninstaller all run against
# throwaway home directories that are deleted afterwards.
set -u
cd "$(dirname "$0")" || exit 1

failed=""
step() { printf '\n== %s\n' "$1"; }

step "syntax"
syntax_ok=1
for f in hooks/*.sh tests/*.sh install.sh uninstall.sh test.sh; do
  bash -n "$f" || syntax_ok=0
done
python3 -m py_compile lib/settings.py 2>&1 || syntax_ok=0
rm -rf -- lib/__pycache__
if [ "$syntax_ok" = 1 ]; then echo "ok"; else failed="$failed syntax"; fi

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x hooks/*.sh tests/*.sh install.sh uninstall.sh test.sh; then
    echo "ok"
  else
    failed="$failed shellcheck"
  fi
else
  echo "UNSUPPORTED: shellcheck is not installed, step skipped"
fi

for t in tests/*.test.sh; do
  step "$t"
  bash "$t" || failed="$failed $t"
done

echo
if [ -z "$failed" ]; then
  echo "ALL PASSED"
else
  echo "FAILED:$failed"
  exit 1
fi
