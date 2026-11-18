#!/usr/bin/env bash
# shellcheck disable=SC2016  # the cases are literal command text; nothing here should expand
# Tests for hooks/block-dangerous-git.sh.
# MUST BLOCK includes every evasion an adversarial audit found.
# MUST ALLOW includes false positives that were seen in real use and cured.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
HOOK="$HOOKS_DIR/block-dangerous-git.sh"

# ---------- MUST BLOCK: the original eight ----------
must_block 'git reset --hard origin/main'
must_block 'git clean -fd'
must_block 'git clean --force'
must_block 'git checkout --force main'
must_block 'git checkout .'
must_block 'git checkout -- .'
must_block 'git restore .'
must_block 'git push --force origin main'
must_block 'git push --force-with-lease'
must_block 'git push -f origin main'
must_block 'git branch -D feature'
must_block 'git stash clear'
must_block 'git stash drop'

# ---------- MUST BLOCK: audit-found evasions ----------
must_block "git -c alias.x='!rm -rf .' x"
must_block "git -c alias.x=\$'!id' x"
must_block 'git -c core.sshcommand=curl fetch origin'
must_block 'git -c clean.requireForce=false clean'
must_block 'git clone ext::sh -c whoami origin'
must_block 'git reflog expire --expire=now --all'
must_block 'git filter-branch --tree-filter rm'
must_block 'git gc --prune=now'
must_block 'git update-ref -d refs/heads/main'
must_block 'git prune --expire=now'
must_block 'git worktree remove --force /tmp/wt'
must_block 'git switch --discard-changes main'
must_block 'git submodule deinit -f mod'
must_block 'git restore :/'
must_block 'git branch --delete --force feature'
must_block 'git checkout -fb newbranch'
must_block 'git push -fu origin main'
must_block 'git push origin +main:main'

# ---------- MUST BLOCK: compound and heredoc forms ----------
# These are the reason the hook never deletes text before matching it.
must_block 'cd /tmp && git reset --hard'
must_block 'echo hi; git clean -fd'
must_block "bash <<'EOF'
git reset --hard
EOF"
must_block 'git status && git checkout .'
must_block "sh -c 'git reset --hard'"

# ---------- MUST ALLOW: false positives seen in real use ----------
must_allow 'git worktree remove /tmp/wt'
must_allow 'git commit -m "worktree removed cleanly, no --force needed"'
must_allow 'git merge --no-ff allowfix -m "merge: browser policy is clean now"'
must_allow 'git commit -m "fix: restore . and checkout . are both blocked by the guard"'
must_allow 'git commit -m "the hook false-positived on git checkout . inside prose"'

# ---------- MUST ALLOW: ordinary everyday commands ----------
must_allow 'git status'
must_allow 'git add -A'
must_allow 'git push origin main'
must_allow 'git commit -m "normal message"'
must_allow 'git log --oneline -5'
must_allow 'git -c core.pager=cat log'
must_allow 'git gc --prune=2.weeks.ago'
must_allow 'git filter-repo --analyze'
must_allow 'git worktree add /tmp/wt main'
must_allow 'git checkout main'
must_allow 'git switch main'
must_allow 'git diff --stat'
must_allow 'git merge --no-ff branch'
must_allow 'git branch -d merged-branch'
must_allow "git -c core.sshCommand='ssh -i ~/.ssh/k -o IdentitiesOnly=yes' fetch"
must_allow 'ls -la'
must_allow 'npm test'

# ---------- MUST BLOCK: tripwires for the next "fix" ----------
# Every case below is blocked today, but only by the greedy `.*` in the rules.
# Three separate attempts to cure the known false positive (see the header of
# the hook) each opened one of them. They are here so the next attempt is told
# at once.
#
# Each one is a REAL destructive invocation after shell expansion, not a
# lookalike.

# Right-anchoring the flag pattern lets these two through.
# `${x}` with x unset expands to nothing, so the shell runs `git clean -f`.
must_block 'git clean -f${x}'
# The metacharacter keeps the -m stripper off, so the quotes survive into the
# matcher; the shell strips them and runs it.
must_block "git clean '-f' && true"

# Segmenting the command on textual separators lets these through. The shell
# word-splits the substitution output back into `git clean -fd`, while the
# fragments land in different segments.
must_block 'git $(echo clean; echo -fd)'
must_block 'git `echo clean; echo -fd`'

# Left-anchoring the flag pattern lets this one through: the `-f` follows the
# `n` of the escape, so it is preceded by a letter rather than a space.
must_block 'git $(printf "clean\n-fd")'

# Segmentation also loses variable indirection. The executing command contains
# no literal "git" at all; only the assignment does.
must_block 'g=git; $g clean -fd'
must_block 'g=git && $g clean -fd'

# And separators inside a parameter expansion, which are not command boundaries
# to the shell. The default value word-splits back into -fd.
must_block 'git clean ${p:-
-fd}'
must_block 'git clean ${p:-;} -fd'

must_fail_open
finish
