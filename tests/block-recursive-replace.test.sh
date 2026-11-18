#!/usr/bin/env bash
# Tests for hooks/block-recursive-replace.sh.
# Nothing is edited: each case only pipes a command string into the hook.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
HOOK="$HOOKS_DIR/block-recursive-replace.sh"

# ---------- MUST BLOCK: find -exec ----------
must_block "find . -name '*.js' -exec sed -i 's/foo/bar/g' {} +"
must_block "find . -type f -exec sed -i '' 's/foo/bar/g' {} \\;"
must_block "find src -type f -exec perl -pi -e 's/foo/bar/' {} \\;"
must_block "find . -exec perl -i -pe 's/foo/bar/' {} +"

# ---------- MUST BLOCK: xargs ----------
must_block "grep -rl foo . | xargs sed -i 's/foo/bar/g'"
must_block "rg -l foo | xargs perl -pi -e 's/foo/bar/g'"
must_block "find . -name '*.md' | xargs sed -i 's/foo/bar/'"

# ---------- MUST BLOCK: command substitution ----------
must_block "sed -i 's/foo/bar/g' \$(grep -rl foo .)"
must_block "sed -i 's/foo/bar/g' \$(find . -name '*.py')"
must_block "perl -pi -e 's/a/b/' \$(rg -l a)"
must_block "sed -i 's/foo/bar/' \`find . -name '*.md'\`"
must_block "perl -pi -e 's/a/b/' \`grep -rl a .\`"
must_block "cd repo && sed -i 's/foo/bar/g' \$(grep -rl foo src)"

# ---------- MUST ALLOW: scoped edits and read-only searches ----------
must_allow "sed -i 's/foo/bar/' src/app.js"
must_allow "sed -i '' 's/foo/bar/' README.md"
must_allow "perl -pi -e 's/a/b/' README.md docs/guide.md"
must_allow "sed 's/foo/bar/' file.txt"
must_allow "find . -name '*.log' -print"
must_allow "find . -name '*.tmp' -exec ls -l {} +"
must_allow 'grep -rn foo src'
must_allow 'grep -rl foo . | xargs wc -l'
must_allow 'rg -l foo | xargs ls -l'
must_allow 'git status'

must_fail_open
finish
