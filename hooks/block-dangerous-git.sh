#!/usr/bin/env bash
# block-dangerous-git.sh
# Claude Code PreToolUse(Bash) guardrail. Blocks IRREVERSIBLE git commands.
# Normal `git push`, commit, add and branch-switch are ALLOWED (many setups
# deploy through a plain push). Only destructive, unrecoverable operations are
# blocked.
# Started as an adaptation of the git guardrails hook in mattpocock/skills
# (git-guardrails-claude-code, MIT).
# Exit 2 = block and show the message to the agent. Exit 0 = allow.
#
# ---------------------------------------------------------------------------
# KNOWN FALSE POSITIVE, DELIBERATELY NOT FIXED. Read this before trying to fix
# it, because three fixes were built and measured and every one of them bought
# the fix by opening a real hole.
#
# THE SYMPTOM. A read-only block can be blocked. Example, all three commands
# harmless:
#     git worktree list | head -20
#     echo "=== is it a clean fast-forward? ==="
#     git merge-base --is-ancestor main HEAD && echo YES
# The clean rule fires by combining `git` from command 1, the word `clean` from
# the quoted echo in command 2, and the `-f` from inside the word "fast-forward"
# in that same string. Three fragments, three different commands, two of them
# inside prose.
#
# WHY. The normalising step below flattens newlines into spaces, erasing the
# strongest command boundary in the input, and the `.*` between fragments is
# unbounded. Both are load-bearing: the greed is what catches `sh -c '...'` and
# heredoc bodies.
#
# WHY IT IS NOT FIXED. Blocking happens iff the flattened string matches, so any
# narrowing that stops matching prose also stops matching something real.
# Measured, each against the whole test suite:
#   1. Anchor the flag on its RIGHT (require space or end after it).
#      HOLE: `git clean -f${x}` with x unset expands to `git clean -f` and is
#      allowed. Also `git clean '-f' && true`.
#   2. Segment the command and match each region separately.
#      Fixes every false positive including the real one. HOLE: four of them,
#      `g=git; $g clean -fd` and separators inside `${...}`, all of which the
#      current greedy form blocks.
#   3. Anchor the flag on its LEFT (require a non-alphanumeric before it).
#      Keeps 1 and 2's holes shut and fixes most of the class. HOLE:
#      `git $(printf "clean\n-fd")`, where the `-f` follows the `n` of the
#      escape and the shell word-splits it back into a real invocation.
# All of these are MUST_BLOCK cases in the test file, so the next attempt gets
# told immediately rather than shipping.
#
# THE WORKAROUND. Do not narrate git words in prose inside a block that also
# runs git. Split the narration into a separate call, or reword it.
#
# The only direction with a chance is full shell-grammar segmentation (quotes,
# $( ), backticks, ${ }, ANSI-C quotes, escapes, heredocs) with fail-closed on
# any parse failure, plus a tripwire for variable indirection. That is a large
# build for a friction bug, and an earlier clever fix to this file was proven by
# an audit to have opened twenty holes.
# ---------------------------------------------------------------------------

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

norm="$(printf '%s' "$cmd" | tr -s "[:space:]" " ")"

# ---------------------------------------------------------------------------
# DROP THE VALUE OF -m / --message, AND ONLY THAT, AND ONLY WHEN THE COMMAND IS
# PROVABLY ONE SIMPLE `git` INVOCATION.
#
# The false positive being cured: `git commit -m "restore . is blocked"` was
# blocked, because the greedy rules below cannot tell a commit message that
# NAMES a destructive command from one that RUNS it. On work whose commit
# messages are about destructive git commands, that fires constantly.
#
# HOW THIS DIFFERS FROM THE EARLIER ATTEMPT THAT OPENED TWENTY HOLES. That one
# scrubbed quoted strings unconditionally, so `bash <<'EOF' ... EOF` had its
# executable body deleted before matching. This one refuses to act at all
# unless the command contains NO metacharacter that could introduce a second
# command or a substitution (; && || | ` $( << >( <( newline), AND shlex
# parses it, AND argv[0] is exactly `git`. Under those three conditions the
# command is one simple git invocation: the only thing that executes is git
# with those arguments.
#
# WHY DROPPING A -m VALUE CANNOT HIDE AN EXECUTION. Under the conditions
# above, a -m value is a message argument to git commit / merge / tag / stash.
# git does not execute it. Contrast `-c`, whose value git DOES execute (pager,
# sshCommand, bang-alias): `-c` is deliberately left untouched, and the test
# suite pins that.
#
# On ANY doubt (a metacharacter, a parse failure, a non-git argv[0], no
# python3) this block emits nothing and $norm keeps its original greedy value.
# Fail-closed by construction: it can only ever be a no-op.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the dollar signs below are Python text, not shell
stripped="$(printf '%s' "$cmd" | python3 -c '
import sys, shlex, os
raw = sys.stdin.read()
for bad in (";", "&&", "||", "|", "`", "$(", "<<", ">(", "<(", "\n", "\r"):
    if bad in raw:
        sys.exit(0)
try:
    toks = shlex.split(raw, posix=True)
except ValueError:
    sys.exit(0)
if not toks or os.path.basename(toks[0]) != "git":
    sys.exit(0)
out, skip = [], False
for t in toks:
    if skip:
        skip = False
        continue
    if t in ("-m", "--message"):
        out.append(t)
        skip = True
        continue
    if t.startswith("--message="):
        out.append("--message=")
        continue
    out.append(t)
print(" ".join(out))
' 2>/dev/null)"
[ -n "$stripped" ] && norm="$stripped"

# Only inspect git commands; everything else passes.
case "$norm" in
  *git*) ;;
  *) exit 0 ;;
esac

block() {
  printf 'BLOCKED by git-guardrails: %s\n' "$1" >&2
  printf 'Command: %s\n' "$cmd" >&2
  printf 'This is irreversible and was stopped on purpose. If you are certain, run it yourself in a terminal.\n' >&2
  # Diagnostics only, no effect on the decision. The guard matches across the
  # WHOLE block, including text inside quotes and comments, so a read-only
  # command can be caught by its own narration. See the known-false-positive
  # note at the top of this file. Reword the prose or split the call.
  printf 'NOTE: matching spans the entire block, quoted prose included. If every command here is read-only, a word in an echo or comment probably completed the pattern.\n' >&2
  exit 2
}

echo "$norm" | grep -Eq '\bgit\b.*\breset\b.*--hard'                                  && block 'git reset --hard (discards uncommitted work)'
echo "$norm" | grep -Eq '\bgit\b.*\bclean\b.*(--force|-[A-Za-z]*f)'                   && block 'git clean -f (permanently deletes untracked files)'
echo "$norm" | grep -Eq '\bgit\b.*\bcheckout\b.*(--force|-f)\b'                       && block 'git checkout --force (discards local changes)'
echo "$norm" | grep -Eq '\bgit\b.*\bcheckout\b.*(-- )?\.([[:space:]]|$)'              && block 'git checkout . (discards all working-tree changes)'
echo "$norm" | grep -Eq '\bgit\b.*\brestore\b.*\.([[:space:]]|$)'                     && block 'git restore . (discards working-tree changes)'
echo "$norm" | grep -Eq '\bgit\b.*\bpush\b.*(--force|--force-with-lease|[[:space:]]-f([[:space:]]|$))' && block 'git push --force (rewrites remote history)'
echo "$norm" | grep -Eq '\bgit\b.*\bbranch\b.*-D'                                     && block 'git branch -D (force-deletes a branch)'
echo "$norm" | grep -Eq '\bgit\b.*\bstash\b.*(clear|drop)'                            && block 'git stash clear/drop (permanently loses stashed work)'

# ---------------------------------------------------------------------------
# LATER ADDITIONS. The eight rules above are the original set and are left
# exactly as they were.
#
# WHY APPEND-ONLY. An earlier attempt rewrote the matching above to cure a
# false positive, and a cross-model audit proved it opened TWENTY holes. The
# root error: it SCRUBBED heredocs and quoted strings before matching, and a
# heredoc body is not prose: `bash <<'EOF' ... EOF` executes it as a script.
# Deleting text before inspecting it is how a guard gets evaded. The greedy
# `.*` above is not sloppiness, it is what makes those rules hard to evade.
# That attempt was reverted; this file is the original plus the rules below.
#
# Each rule is an independent `grep && block`, and block() exits immediately.
# So an added rule can only ever turn an ALLOW into a BLOCK, never the reverse.
# The only risk an addition carries is a false positive, never a new hole.
#
# The gaps below were found by adversarial audit against the original eight.
# Several are worse than anything it already blocked.

# --- arbitrary command execution through git config and transports ---
# NOTE the -i on the config rules: git config KEY NAMES ARE CASE-INSENSITIVE.
# `-c core.sshcommand=` is the same key to git as `core.sshCommand=`, and an
# audit proved the case-sensitive spelling sailed straight through.
# INTENTIONAL BREADTH: a bang-alias runs arbitrary shell and there is no static
# way to tell `!git log --graph` from `!rm -rf .`, so the whole class is blocked.
# A read-only alias has a trivial workaround: run the command directly.
# The bang-alias value pattern allows $'...' ANSI-C quoting, which was the
# other proven evasion: `git -c alias.x=$'!id' x` reaches git as `alias.x=!id`.
echo "$norm" | grep -Eqi "\bgit\b.*-c[[:space:]]+alias\.[A-Za-z0-9_-]+=[\$]?['\"]?!"  && block 'git -c alias.X=!cmd (a bang-alias runs arbitrary shell)'
echo "$norm" | grep -Eqi '\bgit\b.*-c[[:space:]]+clean\.requireForce=false'           && block 'git -c clean.requireForce=false (disables the -f safety, then deletes)'
# ext:: only where it can actually be a transport (a URL argument), not merely
# mentioned. Bare `ext::` matched prose and code symbols in commit messages.
echo "$norm" | grep -Eq '\bgit\b[^;&|]*[[:space:]](clone|fetch|push|pull|remote|ls-remote|submodule)\b' && echo "$norm" | grep -Eq "([[:space:]]|['\"])ext::" && block 'git ext:: transport (runs an arbitrary command)'
#
echo "$norm" | grep -Eqi "\bgit\b.*-c[[:space:]]+core\.sshCommand=[\$]?['\"]?[^ ]" && ! echo "$norm" | grep -Eqi "core\.sshCommand=[\$]?['\"]?ssh([[:space:]]|['\"]|$)" && block 'git -c core.sshCommand=<not ssh> (runs an arbitrary command)'
#
# DELIBERATELY NOT BLOCKED, after an audit found these were everyday commands:
#   core.pager= / core.editor= / core.askPass=   `-c core.pager=cat` is THE
#     standard non-interactive idiom and is used constantly. A genuinely
#     dangerous value (`-c core.pager='git reset --hard'`) still trips the
#     original rules above, because the literal text is still in the command.
#   core.sshCommand=   `ssh -i ~/.ssh/deploy_key -o IdentitiesOnly=yes` is the
#     ordinary deploy-key pattern. Same reasoning: a dangerous value that names
#     a destructive git command is caught by the rules above.
# Blocking these outright cost more than it bought.

# --- history and recovery destruction ---
# Each of these is scoped to a DESTRUCTIVE VALUE, not to the mere presence of a
# word. An audit found the bare-word forms blocked `git gc --prune=2.weeks.ago`
# (git's own default expiry, the safest possible value), `git prune
# --expire=2.weeks.ago`, `git filter-repo --analyze` (its read-only report
# mode), and `git log --grep=filter-branch`.
echo "$norm" | grep -Eq '\bgit\b.*\breflog\b[[:space:]]+expire\b[^;&|]*(--expire|--all)' && block 'git reflog expire --expire/--all (destroys the recovery log)'
echo "$norm" | grep -Eq '\bgit\b[^;&|]*[[:space:]]filter-branch([[:space:]]|$)'       && block 'git filter-branch (rewrites all history)'
echo "$norm" | grep -Eq '\bgit\b[^;&|]*[[:space:]]filter-repo([[:space:]]|$)' && ! echo "$norm" | grep -Eq 'filter-repo[^;&|]*(--analyze|--dry-run)' && block 'git filter-repo (rewrites all history)'
echo "$norm" | grep -Eq '\bgit\b.*\bgc\b.*--prune=(now|all|0)([[:space:]]|$)'         && block 'git gc --prune=now (drops unreachable objects immediately)'
echo "$norm" | grep -Eq '\bgit\b.*\bupdate-ref\b.*[[:space:]]-d([[:space:]]|$)'       && block 'git update-ref -d (deletes a ref outright)'
echo "$norm" | grep -Eq '\bgit\b.*\bprune\b.*--expire=(now|all|0)([[:space:]]|$)'     && block 'git prune --expire=now (drops unreachable objects)'

# --- working-tree and worktree destruction ---
echo "$norm" | grep -Eq '\bgit\b.*\bworktree\b.*\bremove\b.*(--force|[[:space:]]-f)'  && block 'git worktree remove --force (deletes a worktree with uncommitted work)'
echo "$norm" | grep -Eq '\bgit\b.*\bswitch\b.*--discard-changes'                      && block 'git switch --discard-changes (discards local changes)'
echo "$norm" | grep -Eq '\bgit\b.*\bsubmodule\b.*\bdeinit\b.*(--force|[[:space:]]-f)' && block 'git submodule deinit -f (removes submodule working trees)'
# `:/` only as the BARE whole-tree pathspec. `:/README.md` names one file and
# was being blocked by the looser form.
echo "$norm" | grep -Eq '\bgit\b.*\brestore\b.*[[:space:]]:/([[:space:]]|$)'          && block 'git restore :/ (discards changes across the whole tree)'

# --- long-form and bundled spellings the original 8 rules do not reach ---
echo "$norm" | grep -Eq '\bgit\b.*\bbranch\b.*--delete.*--force'                      && block 'git branch --delete --force (force-deletes a branch)'
echo "$norm" | grep -Eq '\bgit\b.*\bbranch\b.*--force.*--delete'                      && block 'git branch --force --delete (force-deletes a branch)'
echo "$norm" | grep -Eq '\bgit\b.*\bcheckout\b.*[[:space:]]-[A-Za-z]*f[A-Za-z]*[[:space:]]' && block 'git checkout with a bundled -f (discards local changes)'
echo "$norm" | grep -Eq '\bgit\b.*\bpush\b.*[[:space:]]-[A-Za-z]*f[A-Za-z]*[[:space:]]'     && block 'git push with a bundled -f (rewrites remote history)'
# A + refspec must look like src:dst, not merely `+word:` which matched inside
# quoted -o/message text (`-o title="Fix +1:1 ratio bug"`).
echo "$norm" | grep -Eq '\bgit\b.*\bpush\b.*[[:space:]]\+[A-Za-z0-9_./-]*[A-Za-z][A-Za-z0-9_./-]*:[A-Za-z0-9_./-]*[A-Za-z][A-Za-z0-9_./-]*([[:space:]]|$)' && block 'git push origin +src:dst (a + refspec is a force push)'

exit 0
