#!/usr/bin/env bash
# shellcheck disable=SC2016  # the cases are literal command text; nothing here should expand
# Tests for hooks/block-catastrophic-rm.sh.
# Nothing is deleted: each case only pipes a command string into the hook.
# H is the throwaway home directory the hook sees as $HOME.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
HOOK="$HOOKS_DIR/block-catastrophic-rm.sh"
H="$TEST_HOME"

# ---------- MUST BLOCK: the root and the home directory ----------
must_block 'rm -rf /'
must_block 'rm -rf /*'
must_block 'rm -rf -- /'
must_block 'rm --recursive --force /'
must_block 'rm -r /'
must_block 'rm -Rf /'
must_block 'rm -fr /'
must_block 'rm -rf ~'
must_block 'rm -rf ~/'
must_block 'rm -rf ~/*'
must_block 'rm -rf $HOME'
must_block 'rm -rf "$HOME"'
must_block 'rm -rf "$HOME"/'
must_block 'rm -rf ${HOME}/*'
must_block "rm -rf $H"
must_block "rm -rf $H/"

# ---------- MUST BLOCK: system and shared trees ----------
must_block 'rm -rf /Users'
must_block 'rm -rf /Users/'
must_block 'rm -rf /Users/*'
must_block 'rm -rf /home'
must_block 'rm -rf /Applications'
must_block 'rm -rf /Library'
must_block 'rm -rf /System'
must_block 'rm -rf /Volumes'
must_block 'rm -rf /Volumes/*'
must_block 'rm -rf ~/Documents'
must_block 'rm -rf ~/Documents/*'
must_block 'rm -rf "$HOME/Documents"'
must_block "rm -rf $H/Documents"

# ---------- MUST BLOCK: unexpanded variable targets ----------
# If the variable is empty at run time these become rm on / or on the wrong tree.
must_block 'rm -rf $BUILD_DIR'
must_block 'rm -rf "$BUILD_DIR"'
must_block 'rm -rf $BUILD_DIR/'
must_block 'rm -rf "${BUILD_DIR}"/*'
must_block 'rm -rf $1'

# ---------- MUST BLOCK: wrapped, nested and compound forms ----------
must_block 'sudo rm -rf /'
must_block 'sudo -u root rm -rf /'
must_block 'env FOO=1 rm -rf /'
must_block 'timeout 5 rm -rf ~'
must_block 'nohup rm -rf ~'
must_block '/bin/rm -rf /'
must_block 'grm -rf /'
must_block 'cd /tmp && rm -rf ~'
must_block 'echo start; rm -rf /'
must_block 'echo start
rm -rf ~'
must_block "bash -c 'rm -rf ~'"
must_block "sh -c 'cd /tmp && rm -rf /'"
must_block 'eval "rm -rf /"'
must_block 'if true; then rm -rf ~; fi'
must_block 'rm -rf /tmp/build ~'

# ---------- MUST BLOCK: relative targets resolved against cwd ----------
must_block 'rm -rf Documents' "$H"
must_block 'rm -rf .' "$H"
must_block 'rm -rf ..' "$H/Documents"
must_block 'rm -rf ../..' "$H/Documents/project"

# ---------- MUST ALLOW: scoped deletes ----------
must_allow 'rm -rf /tmp/build'
must_allow 'rm -rf ~/Documents/project/dist'
must_allow 'rm -rf "$HOME/Documents/project/node_modules"'
must_allow 'rm -rf $HOME/.cache/some-tool'
must_allow 'rm -rf "$BUILD_DIR/output"'
must_allow 'rm -rf /Volumes/Backup/old-snapshots'
must_allow 'rm -rf node_modules' "$H/Documents/project"
must_allow 'rm -rf ./dist build' "$H/Documents/project"
must_allow 'rm -rf ..' "$H/Documents/project/src"
must_allow "rm -rf $H/Documents/project"

# ---------- MUST ALLOW: not a recursive rm at all ----------
must_allow 'rm notes.txt'
must_allow 'rm -f notes.txt'
must_allow 'ls -la ~'
must_allow 'echo "rm -rf /"'
must_allow 'git rm -r --cached build'
must_allow 'npm run format'
must_allow 'grep -rn "rm -rf" docs'

must_fail_open
finish
