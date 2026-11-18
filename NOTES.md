# Notes

What this kit relies on in Claude Code, and the choices that follow from it.
Source for everything quoted here: the Claude Code hooks reference at
https://code.claude.com/docs/en/hooks, read on 18 November 2026. If Claude Code
changes one of these, this is the list to check.

## What the hooks rely on

**The input.** A `PreToolUse` hook receives one JSON object on standard input.
The fields the guards read are `tool_input.command` (the Bash command) and
`cwd`. An example, shortened from the one in the documentation:

```json
{
  "session_id": "abc123",
  "cwd": "/path/to/project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": {"command": "npm test"},
  "tool_use_id": "toolu_01ABC123..."
}
```

**Exit code 2 blocks.** The reference describes exit 2 as a "Blocking error"
that, for `PreToolUse`, "Blocks the tool call", and says: "A hook that blocks by
exiting 2 routes the same way as `"deny"`: Claude sees the stderr message as the
denial reason." Every guard here blocks this way: reason on standard error,
then `exit 2`.

**Exit code 0 allows, and stderr is then dropped.** "Claude never sees stderr
from a hook that exits 0." So a guard that allows prints nothing.

**Other exit codes do not block.** They are a "Non-blocking error": "your hook
exits with any other code, or fails in some other way, such as not starting or
printing invalid JSON. The action goes ahead". A guard that crashes, is missing
or times out therefore lets the command through. The guards are written to
fail open on purpose, and this is the platform behaviour that makes a crash
equivalent.

**Failing closed is available.** "To block the action instead, set
`"onFailure": "block"` on a `command` or `http` hook. Requires Claude Code
v2.1.295 or later." The installer does not set it. Add it to an entry by hand
if you would rather have a broken guard stop every call than let one through.
It only covers a guard that fails to run; a guard that runs and cannot parse
its input still exits 0.

**The JSON decision format exists and is not used here.** A hook can instead
exit 0 and print

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "..."
  }
}
```

with `permissionDecision` one of `allow`, `deny`, `ask` or `defer`. Exit 2 is
the same as `deny` and needs no JSON, so the guards use it. They never return
`allow`, which would skip the user's permission prompt.

**The older top-level format is deprecated for this event.** "PreToolUse
previously used top-level `decision` and `reason` fields, but these are
deprecated for this event." One guard in the private setup this kit was copied
from still printed `{"decision":"block","reason":...}`; the copy here uses
exit 2 instead.

**Matchers.** A matcher made only of letters, digits, `_`, `-`, spaces, `,` and
`|` is an "Exact string, or list of exact strings"; one that contains any other
character is a "JavaScript regular expression, unanchored". The guards use
`Bash` and `Agent|Task`, both exact. The reference lists `Agent` as the
subagent tool. `Task` is kept in the matcher for older versions of Claude Code,
which used that name.

**Several hooks on one event.** "When an event fires, its matching hooks run in
parallel", and "When multiple PreToolUse hooks return different decisions,
precedence is `deny` > `defer` > `ask` > `allow`." So one guard blocking is
enough, and a guard cannot be overruled by another hook that allows.

**Where hooks live.** `~/.claude/settings.json` applies to all projects,
`.claude/settings.json` to one. Hooks from settings files "also run inside"
subagents: "When a subagent calls a tool, tool events such as `PreToolUse` and
`PostToolUse` fire the same configured hooks as in the main conversation".

**Reloading.** "Direct edits to hooks in settings files are normally picked up
automatically by the file watcher." `/hooks` opens a read-only list of the
configured hooks.

**Switching hooks off.** "To temporarily disable all hooks without removing
them, set `"disableAllHooks": true` in your settings file."

**Hooks run as you.** "Command hooks execute shell commands with your full user
permissions." Read the scripts before installing them; they are short.

## What the installer relies on

**The entry shape.** Each guard is added as

```json
{"matcher": "Bash", "hooks": [{"type": "command", "command": "<absolute path>", "timeout": 10}]}
```

**Shell form.** A command hook with no `args` field is in shell form: "The
`command` string is passed to a shell: `sh -c` on macOS and Linux". The
installer writes the absolute path of the script as the command, and quotes it
when the path holds a space or another character the shell would act on. The
installer tests run the stored command through `sh -c` to prove it.

**Timeout.** `timeout` is in seconds; the default for a command hook is 600.
The guards are given 10, far more than they need. A slow hook delays every
Bash call, so a short limit is the safer failure.

**No duplicates.** The installer treats an entry as already present when an
existing handler's command resolves to the same script path, so running it
again adds nothing.

## Choices worth knowing

- **Block by text, fail open.** The guards match the text of a command. They
  cannot know what a script or a binary will do. Where a guard cannot parse its
  input it allows the call. Both are stated in the README under Limits.
- **No agent-side override for the destructive guards.** An environment
  variable the agent could set in the command itself would not be a guard. The
  way past is a person running the command in their own terminal. The fan-out
  limit is different: it is about cost, not data loss, so it has a flag file.
- **Append-only rules in the git guard.** Each rule is an independent
  `grep && block`. Adding one can only turn an allow into a block. The one
  attempt to make the matching cleverer was shown by an audit to have opened
  twenty holes, and was reverted. The tests named "tripwires" pin the cases
  that later attempts broke.
- **One process per guard.** A guard is started for every Bash call, so each
  one is a single short script with an early exit for commands that cannot
  concern it.

## Differences from the setup this was copied from

The guards are copies of hooks in daily use, with private names, paths and
incident details removed. Behaviour is the same except:

- `block-catastrophic-rm.sh`: a hard-coded home directory was replaced by
  `$HOME`, and `/home` was added next to `/Users`.
- `block-recursive-replace.sh`: reads its input with python3 instead of jq, and
  blocks with exit 2 instead of the deprecated JSON form.
- `limit-agent-fanout.sh`: the flag file, limit and window can be set from the
  environment, and the flag's age is read with GNU or BSD `stat`.
- `custom-bash-rules.sh`: a rule banning one named deploy tool became the
  switched-off `othercli` example.
- The guards that keep a log (rm, fan-out, custom rules) write to
  `~/.claude/logs/agent-guardrails.log`. The git and replace guards never
  logged and still do not.

## Known edges of the installer

- The file is parsed and written back, so its layout changes to two-space
  indentation and a number such as `1.50` comes back as `1.5`.
- A settings file with a duplicate key, a number too large for JSON, or bytes
  that are not UTF-8 is refused rather than rewritten.
- A `"hooks": null` or an empty file is treated as no hooks. After an install
  and an uninstall it reads `{}`.
- An entry is recognised as this kit's when its command is the script path, or
  `bash` or `sh` followed by the script path. A command edited into anything
  longer is treated as yours: install adds a fresh entry beside it and
  uninstall leaves it alone.
