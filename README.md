# agent-guardrails

agent-guardrails is a small set of Claude Code hooks that refuse the handful of
commands an AI coding agent should never run on its own: the git commands that
throw work away for good, `rm -rf` aimed at a home directory or a system tree,
find-and-replace across everything under a folder, and a runaway burst of
subagents.

Each guard is one shell script. Claude Code runs it before the tool call, the
script reads the command, and if the command matches it exits with code 2 and a
message. The call does not happen, and the agent reads the message and picks
another way. Everything else passes untouched: the guards never approve
anything and never change a command.

They are plain bash with a little python3 (standard library only), for macOS
and Linux. There is no service and nothing to configure.

## The problem

An agent that can run shell commands will, sooner or later, run one of these:

- `git reset --hard` or `git checkout .` to "get back to a clean state", on top
  of an afternoon of uncommitted work.
- `rm -rf "$BUILD_DIR"/` where the variable turned out to be empty.
- `grep -rl old . | xargs sed -i 's/old/new/g'` from one folder too high, which
  rewrites every project, dependency folder and generated file below it.
- Fifty subagents for a job that needed three, which spends a week of quota in
  an hour.

None of these is malice. The agent is trying to finish the task, and each
command is a reasonable-looking shortcut. Instructions in a prompt help until
the day they are forgotten; a hook is run by Claude Code itself, every time.

These rules came out of real incidents on a machine that runs many agent
sessions at once. The comments in each script say why the rule exists.

## What is in it

| Guard | Runs before | What it refuses | An example it stops | When you really mean it |
|---|---|---|---|---|
| `block-dangerous-git.sh` | Bash | Irreversible git: `reset --hard`, `clean -f`, `checkout .`, `restore .`, any force push (`--force`, `--force-with-lease`, `-f`, a `+` refspec), `branch -D`, `stash drop` and `stash clear`, `reflog expire` with `--expire` or `--all`, `filter-branch`, `filter-repo`, `gc --prune=now`, `update-ref -d`, `worktree remove --force`, and `git -c` settings that run a command | `git reset --hard origin/main` | Run it yourself in a terminal. The agent has no override. |
| `block-catastrophic-rm.sh` | Bash | A recursive `rm` aimed at `/`, the home directory, bare `~/Documents`, `/Users`, `/home`, `/Applications`, `/Library`, `/System` or `/Volumes`, the `/*` form of each, or a target that is only an unexpanded variable | `rm -rf "$BUILD_DIR"/` | Name the deeper path literally (`rm -rf ~/code/app/dist` passes), or run it yourself. |
| `block-recursive-replace.sh` | Bash | `sed -i` or `perl -i` fed by `find -exec`, by `xargs`, or by `$(find ...)`, `$(grep ...)`, `$(rg ...)` | `find . -name '*.js' -exec sed -i 's/foo/bar/g' {} +` | Give it a named list of files (`sed -i 's/foo/bar/' src/a.js src/b.js` passes), or run it yourself. |
| `limit-agent-fanout.sh` | Agent | The next subagent once 8 have been started in the last 15 minutes, counted across all your sessions | The ninth `Agent` call in a quarter of an hour | `touch /tmp/claude-agents-ok` lifts the limit for 30 minutes. |
| `custom-bash-rules.sh` (optional) | Bash | Your own rules. It ships with one: an `adb install` of a release build | `adb install app-release.apk` | It is your file: edit or delete the rule. |

A plain `git push`, commit, merge, branch switch and `branch -d` all pass. So
does every scoped delete and every edit of named files.

When a guard fires, the agent sees something like this and carries on from
there:

    BLOCKED by git-guardrails: git reset --hard (discards uncommitted work)
    Command: git reset --hard origin/main
    This is irreversible and was stopped on purpose. If you are certain, run it yourself in a terminal.

## Install

Needs Claude Code, bash 3.2 or newer and python3 3.6 or newer, on macOS or
Linux.

    git clone https://github.com/alexm-oss/agent-guardrails.git
    cd agent-guardrails
    ./install.sh

That copies the four guards to `~/.claude/hooks/agent-guardrails/` and adds one
`PreToolUse` entry for each to `~/.claude/settings.json`:

    agent-guardrails: installing into ~/.claude/hooks/agent-guardrails
      copied: block-dangerous-git.sh
      copied: block-catastrophic-rm.sh
      copied: block-recursive-replace.sh
      copied: limit-agent-fanout.sh
      added PreToolUse(Bash): block-dangerous-git.sh
      added PreToolUse(Bash): block-catastrophic-rm.sh
      added PreToolUse(Bash): block-recursive-replace.sh
      added PreToolUse(Agent|Task): limit-agent-fanout.sh
      backup: ~/.claude/settings.json.bak-agent-guardrails-20261118-100543
      wrote: ~/.claude/settings.json

What the installer does and does not do:

- It keeps everything already in `settings.json`: your other hooks, in their
  order, and every other key. Its entries go at the end of the `PreToolUse`
  list. The file is written back with two-space indentation.
- It saves a copy of `settings.json` next to the original before it writes, and
  it only writes when something changes. Run it twice and the second run
  changes nothing.
- If `settings.json` is not valid JSON, is read-only, or its `hooks` section is
  not the shape Claude Code documents, it stops and changes nothing.
- `./install.sh --dry-run` shows what it would add and touches nothing.
- `./install.sh --with-custom-rules` also installs `custom-bash-rules.sh`.
- `./install.sh --claude-dir DIR` uses another folder instead of `~/.claude`.

The guards are copies, so the cloned folder can be deleted afterwards. Keep it
if you want `./uninstall.sh` or updates: pull, then run `./install.sh` again.

In Claude Code, type `/hooks` to see the guards listed. Edits to hooks in a
settings file are normally picked up by a running session without a restart.

### By hand

If you would rather edit `settings.json` yourself, copy the scripts anywhere and
add entries like this, with your own absolute paths:

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/block-dangerous-git.sh", "timeout": 10}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/block-catastrophic-rm.sh", "timeout": 10}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/path/to/block-recursive-replace.sh", "timeout": 10}]},
      {"matcher": "Agent|Task", "hooks": [{"type": "command", "command": "/path/to/limit-agent-fanout.sh", "timeout": 10}]}
    ]
  }
}
```

Put the same entries in a project's `.claude/settings.json` instead to guard
one project only.

## Try it

A hook is a program that reads one JSON object on standard input, so you can
run one without Claude Code:

    echo '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}' \
      | ~/.claude/hooks/agent-guardrails/block-dangerous-git.sh; echo "exit $?"

    BLOCKED by git-guardrails: git stash clear/drop (permanently loses stashed work)
    Command: git stash clear
    This is irreversible and was stopped on purpose. If you are certain, run it yourself in a terminal.
    NOTE: matching spans the entire block, quoted prose included. If every command here is read-only, a word in an echo or comment probably completed the pattern.
    exit 2

Nothing ran: the hook only read the text. Change the command to `git status`
and it prints nothing and exits 0.

## Remove

    ./uninstall.sh

It takes its own entries out of `settings.json` (after a backup copy), deletes
the guard scripts it installed and removes its folder if that is now empty.
Your other hooks and settings are left as they were, including any script of
your own that you keep in that folder. A `custom-bash-rules.sh`
you have edited is kept unless you pass `--purge`. The two log files under
`~/.claude/logs` are left alone.

To switch every hook off for a while without removing anything, Claude Code has
its own setting: `"disableAllHooks": true`.

## Add your own rule

The quickest way is `custom-bash-rules.sh`. Install it with
`./install.sh --with-custom-rules`, then edit
`~/.claude/hooks/agent-guardrails/custom-bash-rules.sh`. A rule is two lines:

```bash
echo "$norm" | grep -Eq '(^|[;&|] ?)terraform +destroy' \
  && block "no-terraform-destroy" "Never run terraform destroy. Show the user the plan and let them run it."
```

`$norm` is the command with whitespace squeezed. `block` logs the rule name,
prints the message for the agent and exits 2. Two things worth copying from the
rules already there:

- Put `(^|[;&|] ?)` in front of the program name when the word also turns up in
  ordinary text. Without it, a commit message that mentions the tool is blocked.
- Say what to do instead. The agent reads the message and acts on it.

The installer never overwrites this file once it exists, so your rules survive
an update.

For a guard that does not fit one regex, write a new script. The contract is
short:

1. Read the JSON on standard input. `tool_name` is the tool, `tool_input` holds
   its arguments (`tool_input.command` for Bash), `cwd` is the working
   directory.
2. To refuse the call, print the reason on standard error and exit 2.
3. Otherwise exit 0 and print nothing.
4. If the input cannot be parsed, exit 0. A broken guard must not block every
   command.

Then add it to `settings.json` with the tool name as the matcher, and add a
test next to the others in `tests/`: a list of commands that must be blocked
and a list that must pass. The second list matters as much as the first.

## How it works

Claude Code runs every matching `PreToolUse` hook before a tool call and passes
it the call as JSON. Exit code 0 means no objection. Exit code 2 blocks the
call, and whatever the hook wrote to standard error is shown to the model as
the reason. These guards only ever use those two outcomes. They do not return
"allow", so your normal permission prompts are unchanged.

Hooks in `~/.claude/settings.json` apply to every project and also run inside
subagents.

- `block-dangerous-git.sh` flattens the command to one line and matches it
  against a list of patterns, greedily and across the whole text. That is on
  purpose: it is what catches `sh -c '...'`, heredoc bodies and
  `g=git; $g clean -fd`. The cost is the false positive described under Limits.
- `block-catastrophic-rm.sh` tokenises the command the way a shell would, looks
  through `sudo`, `env`, `timeout`, `bash -c` and `eval`, finds each recursive
  `rm`, and resolves every target (including `~`, `$HOME` and paths relative to
  the working directory) against a short list of protected directories.
- `block-recursive-replace.sh` matches four command shapes.
- `limit-agent-fanout.sh` keeps one timestamp per dispatch in
  `~/.claude/logs/agent-dispatch.log` and counts the ones inside the window.
  `AGENT_FANOUT_LIMIT` and `AGENT_FANOUT_WINDOW` (seconds) change the numbers.

The rm guard, the fan-out guard and the custom rules write a line to
`~/.claude/logs/agent-guardrails.log` for each block. The git guard and the
replace guard keep no log.

## Limits

These guards stop mistakes. They are not a sandbox and they do not stop an
agent that is trying to get past them.

- **They read command text, not effects.** A script the agent writes and then
  runs, a Python one-liner that deletes a tree, `find ... -delete`,
  `find ... -exec rm -rf {} +`, `xargs rm -rf`, `rsync --delete`, a redirect
  that empties a file: none of these is seen.
- **The git guard blocks some harmless commands.** It matches across the whole
  command, quoted text included, so `git log` followed by
  `echo "is it a clean fast-forward?"` in one call is refused (`git`, `clean`
  and the `-f` in "fast-forward"). Three fixes were tried and each one let a
  real destructive command through, so it stays. The header of the script has
  the detail. The cure is to split the call or reword the text.
- **The git guard does not cover everything destructive.** Deleting a remote
  branch (`git push origin --delete name`), discarding one named file
  (`git checkout -- file`, `git restore file`), `commit --amend`, `rebase` and
  `tag -d` all pass.
- **The rm guard protects a short list of directories.** `rm -rf /etc`,
  `rm -rf /usr`, `rm -rf ~/Library` and `rm -rf ~/.ssh` pass. Add the ones you
  care about to the `BLOCKED` table in the script. A target built by command
  substitution, such as `rm -rf $(echo /)`, is not resolved.
- **The replace guard knows four shapes.** `xargs -0 sed -i`, `sed -E -i`,
  `sed --in-place`, `find -execdir`, a `for` or `while` loop around `sed -i`,
  and formatters or codemods that rewrite a whole tree all pass.
- **The fan-out guard counts dispatches, not cost.** One subagent can still
  spend a great deal. It only sees the Agent tool, not agents started some
  other way, and the count is per user on one machine.
- **They fail open.** If python3 is missing, is older than 3.6, or the input
  cannot be parsed, the command is allowed. A guard that blocked everything when it broke would be
  switched off within the day. `NOTES.md` says how to make a guard that fails
  to start block instead, if you prefer that.
- **An agent with a shell can undo them.** It can edit `settings.json`, edit
  the scripts or create the override flag. Nothing here prevents that. For
  hard limits use Claude Code's permission rules, a sandbox, or an account
  that cannot reach what you want protected.
- **Claude Code only, macOS and Linux only.** They were written and are used
  daily on macOS. The scripts avoid macOS-only commands, but Linux has had far
  less use.

## Tests

    ./test.sh

It checks syntax, runs shellcheck when it is installed (and says UNSUPPORTED
when it is not), then runs one test file per guard, the installer and
uninstaller tests, and a scan that keeps personal paths and addresses out of
the kit. The tests pipe sample tool calls into the hooks and read the exit
code; nothing is deleted, no git command runs and no agent is started. The
installer tests use throwaway home directories, never yours.

`NOTES.md` records which parts of the Claude Code hooks documentation the kit
relies on.

## Credits

`block-dangerous-git.sh` started from the git guardrails hook in
[mattpocock/skills](https://github.com/mattpocock/skills) (MIT) and grew from
there.

MIT licence, by Alex Maxey.
