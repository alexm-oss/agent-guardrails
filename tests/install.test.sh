#!/usr/bin/env bash
# Tests for install.sh, uninstall.sh and lib/settings.py.
# Every run uses a throwaway HOME, so the real ~/.claude is never read or written.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# jget FILE PYTHON_EXPRESSION -> evaluates the expression with d = parsed JSON.
jget() {
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
print(eval(sys.argv[2]))' "$1" "$2"
}

# same_json FILE_A FILE_B -> yes when both hold the same JSON value.
same_json() {
  python3 -c '
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
b = json.load(open(sys.argv[2], encoding="utf-8"))
print("yes" if a == b else "no")' "$1" "$2"
}

count_backups() { find "$1" -maxdepth 1 -name 'settings.json.bak-agent-guardrails-*' | wc -l | tr -d ' '; }

new_home() {
  local h
  h="$(mktemp -d "$TEST_HOME/home.XXXXXX")"
  echo "$h"
}

install_into() { HOME="$1" bash "$KIT_DIR/install.sh" "${@:2}" >"$1/install.out" 2>&1; echo $?; }
uninstall_from() { HOME="$1" bash "$KIT_DIR/uninstall.sh" "${@:2}" >"$1/uninstall.out" 2>&1; echo $?; }

OURS='len([h for g in d["hooks"]["PreToolUse"] for h in g["hooks"] if "/hooks/agent-guardrails/" in h["command"]])'

# ---------- 1. fresh machine: no ~/.claude at all ----------
H1="$(new_home)"
check "fresh install exits 0" 0 "$(install_into "$H1")"
S1="$H1/.claude/settings.json"
D1="$H1/.claude/hooks/agent-guardrails"
check "settings.json was created" yes "$([ -f "$S1" ] && echo yes || echo no)"
check "four entries were added" 4 "$(jget "$S1" "$OURS")"
check "no backup when there was nothing to back up" 0 "$(count_backups "$H1/.claude")"
for name in block-dangerous-git.sh block-catastrophic-rm.sh block-recursive-replace.sh limit-agent-fanout.sh; do
  check "$name is installed and executable" yes "$([ -x "$D1/$name" ] && echo yes || echo no)"
done
check "custom rules are not installed by default" no "$([ -e "$D1/custom-bash-rules.sh" ] && echo yes || echo no)"
check "the fan-out guard is matched to Agent|Task" "Agent|Task" "$(jget "$S1" '[g["matcher"] for g in d["hooks"]["PreToolUse"] if "limit-agent-fanout" in g["hooks"][0]["command"]][0]')"
check "each entry has a 10 second timeout" "[10, 10, 10, 10]" "$(jget "$S1" '[g["hooks"][0]["timeout"] for g in d["hooks"]["PreToolUse"]]')"

# The command stored in settings.json really blocks when Claude Code runs it.
GIT_CMD="$(jget "$S1" '[g["hooks"][0]["command"] for g in d["hooks"]["PreToolUse"] if "block-dangerous-git" in g["hooks"][0]["command"]][0]')"
check "installed git guard blocks through its settings command" 2 "$(bash_call 'git reset --hard' | HOME="$H1" sh -c "$GIT_CMD" >/dev/null 2>&1; echo $?)"
check "installed git guard allows an ordinary command" 0 "$(bash_call 'git status' | HOME="$H1" sh -c "$GIT_CMD" >/dev/null 2>&1; echo $?)"
RM_CMD="$(jget "$S1" '[g["hooks"][0]["command"] for g in d["hooks"]["PreToolUse"] if "block-catastrophic-rm" in g["hooks"][0]["command"]][0]')"
check "installed rm guard blocks through its settings command" 2 "$(bash_call 'rm -rf ~' | HOME="$H1" sh -c "$RM_CMD" >/dev/null 2>&1; echo $?)"

# ---------- 2. running it again changes nothing ----------
cp "$S1" "$H1/before-second-run.json"
check "second install exits 0" 0 "$(install_into "$H1")"
check "second install leaves settings.json byte-identical" yes "$(cmp -s "$S1" "$H1/before-second-run.json" && echo yes || echo no)"
check "second install makes no backup" 0 "$(count_backups "$H1/.claude")"
check "still four entries" 4 "$(jget "$S1" "$OURS")"

# ---------- 3. uninstall on that machine ----------
check "uninstall exits 0" 0 "$(uninstall_from "$H1")"
check "uninstall leaves an empty object" "{}" "$(jget "$S1" 'd')"
check "uninstall made one backup" 1 "$(count_backups "$H1/.claude")"
check "the hook folder is gone" no "$([ -e "$D1" ] && echo yes || echo no)"
check "uninstalling twice exits 0" 0 "$(uninstall_from "$H1")"
check "uninstalling twice makes no second backup" 1 "$(count_backups "$H1/.claude")"

# ---------- 4. an existing settings.json keeps everything it had ----------
H2="$(new_home)"
mkdir -p "$H2/.claude/hooks"
S2="$H2/.claude/settings.json"
cat > "$S2" <<'JSON'
{
    "env": {"EXAMPLE_FLAG": "1"},
    "permissions": {"allow": ["Bash(npm test:*)"], "deny": ["Read(./.env)"]},
    "model": "sonnet",
    "hooks": {
        "PreToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/tools/my-own-guard.sh"}]},
            {"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "python3 /opt/tools/lint.py", "timeout": 5}]}
        ],
        "Stop": [
            {"hooks": [{"type": "command", "command": "/opt/tools/on-stop.sh"}]}
        ]
    },
    "unknownFutureKey": [1, 2, {"three": null}]
}
JSON
cp "$S2" "$H2/original.json"
chmod 600 "$S2"
check "install over existing settings exits 0" 0 "$(install_into "$H2")"
check "one backup was made" 1 "$(count_backups "$H2/.claude")"
BK="$(find "$H2/.claude" -maxdepth 1 -name 'settings.json.bak-agent-guardrails-*')"
check "the backup is the original, byte for byte" yes "$(cmp -s "$BK" "$H2/original.json" && echo yes || echo no)"
check "four entries were added" 4 "$(jget "$S2" "$OURS")"
check "the two existing PreToolUse entries are still first, unchanged" yes "$(python3 -c '
import json, sys
new = json.load(open(sys.argv[1])); old = json.load(open(sys.argv[2]))
print("yes" if new["hooks"]["PreToolUse"][:2] == old["hooks"]["PreToolUse"] else "no")' "$S2" "$H2/original.json")"
check "every other key is unchanged" yes "$(python3 -c '
import json, sys
new = json.load(open(sys.argv[1])); old = json.load(open(sys.argv[2]))
same = all(new[k] == old[k] for k in old if k != "hooks") and new["hooks"]["Stop"] == old["hooks"]["Stop"] and list(new) == list(old)
print("yes" if same else "no")' "$S2" "$H2/original.json")"
check "the file mode is kept" 600 "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$S2")"

check "uninstall exits 0" 0 "$(uninstall_from "$H2")"
check "after uninstall the settings equal the original" yes "$(same_json "$S2" "$H2/original.json")"
check "the user's own hooks folder is still there" yes "$([ -d "$H2/.claude/hooks" ] && echo yes || echo no)"

# ---------- 5. broken or odd settings are refused and left alone ----------
H3="$(new_home)"
mkdir -p "$H3/.claude"
printf '{"hooks": {"PreToolUse": [ this is not json' > "$H3/.claude/settings.json"
cp "$H3/.claude/settings.json" "$H3/original.txt"
check "invalid JSON makes install exit 1" 1 "$(install_into "$H3")"
check "invalid JSON is left byte-identical" yes "$(cmp -s "$H3/.claude/settings.json" "$H3/original.txt" && echo yes || echo no)"
check "nothing was copied before the refusal" no "$([ -e "$H3/.claude/hooks/agent-guardrails" ] && echo yes || echo no)"
check "no backup was made" 0 "$(count_backups "$H3/.claude")"

H4="$(new_home)"
mkdir -p "$H4/.claude"
printf '{"hooks": {"PreToolUse": "not a list"}}\n' > "$H4/.claude/settings.json"
cp "$H4/.claude/settings.json" "$H4/original.txt"
check "an unexpected hooks shape makes install exit 1" 1 "$(install_into "$H4")"
check "an unexpected hooks shape is left byte-identical" yes "$(cmp -s "$H4/.claude/settings.json" "$H4/original.txt" && echo yes || echo no)"

# ---------- 6. dry runs change nothing ----------
H5="$(new_home)"
check "dry-run install exits 0" 0 "$(install_into "$H5" --dry-run)"
check "dry-run install creates nothing" no "$([ -e "$H5/.claude" ] && echo yes || echo no)"
check "dry-run install says what it would add" 4 "$(grep -c 'would add' "$H5/install.out")"
install_into "$H5" >/dev/null
cp "$H5/.claude/settings.json" "$H5/installed.json"
check "dry-run uninstall exits 0" 0 "$(uninstall_from "$H5" --dry-run)"
check "dry-run uninstall leaves settings byte-identical" yes "$(cmp -s "$H5/.claude/settings.json" "$H5/installed.json" && echo yes || echo no)"
check "dry-run uninstall leaves the scripts" yes "$([ -x "$H5/.claude/hooks/agent-guardrails/block-dangerous-git.sh" ] && echo yes || echo no)"

# ---------- 7. custom rules: installed on request, never overwritten ----------
H6="$(new_home)"
check "install --with-custom-rules exits 0" 0 "$(install_into "$H6" --with-custom-rules)"
C6="$H6/.claude/hooks/agent-guardrails/custom-bash-rules.sh"
check "five entries were added" 5 "$(jget "$H6/.claude/settings.json" "$OURS")"
check "custom rules are installed" yes "$([ -x "$C6" ] && echo yes || echo no)"
echo '# my own rule goes here' >> "$C6"
cp "$C6" "$H6/edited-copy.sh"
check "re-install exits 0" 0 "$(install_into "$H6" --with-custom-rules)"
check "re-install keeps the edited custom rules" yes "$(cmp -s "$C6" "$H6/edited-copy.sh" && echo yes || echo no)"
check "still five entries" 5 "$(jget "$H6/.claude/settings.json" "$OURS")"
check "uninstall exits 0" 0 "$(uninstall_from "$H6")"
check "uninstall keeps the edited custom rules" yes "$(cmp -s "$C6" "$H6/edited-copy.sh" && echo yes || echo no)"
check "uninstall removed all five entries" "{}" "$(jget "$H6/.claude/settings.json" 'd')"
check "uninstall --purge exits 0" 0 "$(uninstall_from "$H6" --purge)"
check "--purge deletes the edited custom rules" no "$([ -e "$C6" ] && echo yes || echo no)"

# ---------- 8. a home folder with a space in its name ----------
H7="$TEST_HOME/home with space"
mkdir -p "$H7"
check "install into a path with a space exits 0" 0 "$(install_into "$H7")"
SP_CMD="$(jget "$H7/.claude/settings.json" '[g["hooks"][0]["command"] for g in d["hooks"]["PreToolUse"] if "block-dangerous-git" in g["hooks"][0]["command"]][0]')"
check "the quoted command still runs and blocks" 2 "$(bash_call 'git reset --hard' | HOME="$H7" sh -c "$SP_CMD" >/dev/null 2>&1; echo $?)"
check "second install with a space adds nothing" 4 "$(install_into "$H7" >/dev/null; jget "$H7/.claude/settings.json" "$OURS")"
check "uninstall with a space exits 0" 0 "$(uninstall_from "$H7")"
check "uninstall with a space removed the entries" "{}" "$(jget "$H7/.claude/settings.json" 'd')"

# ---------- 9. --claude-dir and a symlinked settings file ----------
H8="$(new_home)"
mkdir -p "$H8/dotfiles" "$H8/alt-claude"
printf '{"model": "sonnet"}\n' > "$H8/dotfiles/settings.json"
ln -s "$H8/dotfiles/settings.json" "$H8/alt-claude/settings.json"
check "install --claude-dir exits 0" 0 "$(install_into "$H8" --claude-dir "$H8/alt-claude")"
check "the default ~/.claude was not created" no "$([ -e "$H8/.claude" ] && echo yes || echo no)"
check "the settings symlink is still a symlink" yes "$([ -L "$H8/alt-claude/settings.json" ] && echo yes || echo no)"
check "the real file behind the symlink got the entries" 4 "$(jget "$H8/dotfiles/settings.json" "$OURS")"
check "the existing key is kept" sonnet "$(jget "$H8/dotfiles/settings.json" 'd["model"]')"
check "uninstall --claude-dir exits 0" 0 "$(uninstall_from "$H8" --claude-dir "$H8/alt-claude")"
check "uninstall restored the original content" "{'model': 'sonnet'}" "$(jget "$H8/dotfiles/settings.json" 'd')"

# ---------- 10. --claude-dir given as a relative path, with and without a slash ----------
H9="$(new_home)"
check "install with a relative --claude-dir exits 0" 0 "$(cd "$H9" && install_into "$H9" --claude-dir rel-claude)"
check "the stored commands are absolute paths" yes "$(jget "$H9/rel-claude/settings.json" '"yes" if all(g["hooks"][0]["command"].startswith("/") for g in d["hooks"]["PreToolUse"]) else "no"')"
check "the same folder with a trailing slash exits 0" 0 "$(cd "$H9" && install_into "$H9" --claude-dir rel-claude/)"
check "a trailing slash does not install the guards twice" 4 "$(jget "$H9/rel-claude/settings.json" "$OURS")"
check "uninstall with the absolute form exits 0" 0 "$(uninstall_from "$H9" --claude-dir "$H9/rel-claude/")"
check "uninstall removed all four entries" "{}" "$(jget "$H9/rel-claude/settings.json" 'd')"

# ---------- 11. a script of the user's own in our folder is not ours ----------
H10="$(new_home)"
install_into "$H10" >/dev/null
D10="$H10/.claude/hooks/agent-guardrails"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D10/my-own.sh"
python3 - "$H10/.claude/settings.json" "$D10/my-own.sh" <<'PY'
import json, sys
path, script = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
d["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": script}]})
json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
PY
check "uninstall exits 0" 0 "$(uninstall_from "$H10")"
check "the user's own entry is still in settings" 1 "$(jget "$H10/.claude/settings.json" 'len(d["hooks"]["PreToolUse"])')"
check "the user's own entry is unchanged" "$D10/my-own.sh" "$(jget "$H10/.claude/settings.json" 'd["hooks"]["PreToolUse"][0]["hooks"][0]["command"]')"
check "the user's own script is still on disk" yes "$([ -f "$D10/my-own.sh" ] && echo yes || echo no)"
check "our scripts are gone" no "$([ -e "$D10/block-dangerous-git.sh" ] && echo yes || echo no)"

# ---------- 12. an entry hand-edited to "bash <path>" is still recognised ----------
H11="$(new_home)"
install_into "$H11" >/dev/null
python3 - "$H11/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path, encoding="utf-8"))
for g in d["hooks"]["PreToolUse"]:
    h = g["hooks"][0]
    if "block-dangerous-git" in h["command"]:
        h["command"] = "bash " + h["command"]
json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
PY
check "re-install exits 0" 0 "$(install_into "$H11")"
check "re-install adds no duplicate beside the edited entry" 4 "$(jget "$H11/.claude/settings.json" "$OURS")"
check "uninstall exits 0" 0 "$(uninstall_from "$H11")"
check "uninstall removed the edited entry too" "{}" "$(jget "$H11/.claude/settings.json" 'd')"

# ---------- 13. settings that cannot be written back exactly are refused ----------
refused() {
  # refused NAME FILE_CONTENT_COMMAND...: installs over the file and expects a clean refusal.
  local h="$1"
  cp "$h/.claude/settings.json" "$h/original.bin"
  check "$2: install exits 1" 1 "$(install_into "$h")"
  check "$2: the file is byte-identical" yes "$(cmp -s "$h/.claude/settings.json" "$h/original.bin" && echo yes || echo no)"
  check "$2: a plain message, not a traceback" 0 "$(grep -c Traceback "$h/install.out")"
  check "$2: the message says nothing was changed" yes "$(grep -q 'Nothing was changed' "$h/install.out" && echo yes || echo no)"
  check "$2: nothing was copied" no "$([ -e "$h/.claude/hooks/agent-guardrails" ] && echo yes || echo no)"
}
H12="$(new_home)"; mkdir -p "$H12/.claude"
printf '{"a": 1, "a": 2}\n' > "$H12/.claude/settings.json"
refused "$H12" "duplicate key"
H13="$(new_home)"; mkdir -p "$H13/.claude"
printf '{"n": 1e999}\n' > "$H13/.claude/settings.json"
refused "$H13" "number too large for JSON"
H14="$(new_home)"; mkdir -p "$H14/.claude"
printf '{"name": "caf\351"}\n' > "$H14/.claude/settings.json"
refused "$H14" "not UTF-8"

# A read-only settings file. Skipped for root, which can write anything.
if [ "$(id -u)" != "0" ]; then
  H15="$(new_home)"; mkdir -p "$H15/.claude"
  printf '{"model": "sonnet"}\n' > "$H15/.claude/settings.json"
  chmod 400 "$H15/.claude/settings.json"
  cp "$H15/.claude/settings.json" "$H15/original.bin"
  check "read-only settings: install exits 1" 1 "$(install_into "$H15")"
  check "read-only settings: the file is byte-identical" yes "$(cmp -s "$H15/.claude/settings.json" "$H15/original.bin" && echo yes || echo no)"
  check "read-only settings: a plain message, not a traceback" 0 "$(grep -c Traceback "$H15/install.out")"
  check "read-only settings: no backup was made" 0 "$(count_backups "$H15/.claude")"
  chmod 600 "$H15/.claude/settings.json"
fi

finish
