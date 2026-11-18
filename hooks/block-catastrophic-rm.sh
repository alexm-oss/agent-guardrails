#!/usr/bin/env bash
# block-catastrophic-rm.sh
# Claude Code PreToolUse(Bash) guardrail. Hard rail against catastrophic rm.
# Background: agents have been seen running rm -rf on a home directory through
# a bad variable expansion. Exit 2 blocks and explains. Fail-open: any problem
# parsing the hook input exits 0, so a broken parser never blocks every command.
#
# Blocks rm with a recursive flag (-r, -R, -rf, -fr, --recursive; force optional)
# aimed at any of:
#   /   /*   $HOME   ~   /Users   /home   /Applications   /Library   /System
#   /Volumes   ~/Documents (bare)   and the <dir>/* form of each.
# Also blocks any target that is an unexpanded variable followed by nothing or a
# slash ($VAR, "$VAR"/, ${VAR}/*), because an empty expansion turns those into
# rm on / or on the wrong tree. A variable followed by a real subpath
# ("$HOME/Documents/x/dist") is allowed.
# Allows scoped deletes: deeper paths under $HOME, relative paths inside a repo,
# /tmp, specific /Volumes/<name>/<path> subpaths. Relative targets are resolved
# against the cwd field of the hook input, so "rm -rf Documents" with the home
# directory as cwd is caught too.
# Known conservative edge: heredoc bodies are scanned like command lines, so a
# heredoc line that is itself a catastrophic rm blocks; write that file with
# the Write tool instead.
# To protect more directories, add them to the BLOCKED table below (keys are
# lower case).
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

# Fast path: no rm-shaped token anywhere in the string, skip the analyzer.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_])g?rm([^[:alnum:]_-]|$)' || exit 0

block() {
  echo "$(date '+%F %T') block-catastrophic-rm BLOCK $1" >> "$LOG" 2>/dev/null
  printf 'BLOCKED by block-catastrophic-rm (%s): %s\n' "$1" "$2" >&2
  printf 'Command: %s\n' "$cmd" >&2
  # shellcheck disable=SC2016  # the dollar signs are literal text in the message
  printf 'Recursive rm aimed at /, $HOME, ~, /Users, /home, /Applications, /Library, /System, /Volumes, bare ~/Documents, or an unexpanded-variable target is hard-blocked. Delete a specific deeper path with a literal absolute path instead.\n' >&2
  exit 2
}

# shellcheck disable=SC2016  # the dollar signs below are Python text, not shell
verdict="$(printf '%s' "$input" | python3 -c '
import sys, json, os, re, shlex

HOME = os.path.normpath(os.environ.get("HOME") or os.path.expanduser("~"))
HL = HOME.lower()
BLOCKED = {
    "/": "the filesystem root",
    "/users": "/Users (every account on a Mac)",
    "/home": "/home (every account on a Linux machine)",
    HL: "the home directory",
    "/applications": "/Applications",
    "/library": "/Library",
    "/system": "/System",
    "/volumes": "/Volumes (all mounted drives)",
    HL + "/documents": "bare ~/Documents (everything kept under it)",
}
VAR_RE = re.compile(r"^\$(\{[^}]+\}|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?!])(/\*?)?$")
PUNCT = set("();<>|&")
WRAPPERS = {"sudo", "doas", "command", "builtin", "exec", "nohup", "nice", "ionice", "time", "caffeinate", "stdbuf", "env", "timeout"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "su"}
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "for", "case", "esac", "{", "}", "!"}

def tokenize(text):
    lex = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)

def split_simple(tokens):
    cmds = []
    cur = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t and all(c in PUNCT for c in t):
            if "<" in t or ">" in t:
                i += 2
                continue
            if cur:
                cmds.append(cur)
                cur = []
            i += 1
            continue
        cur.append(t)
        i += 1
    if cur:
        cmds.append(cur)
    return cmds

def classify(tok, cwd):
    t = tok.strip("`").strip()
    if not t:
        return None
    if t in ("$HOME", "${HOME}"):
        t = HOME
    elif t.startswith("$HOME/"):
        t = HOME + t[5:]
    elif t.startswith("${HOME}/"):
        t = HOME + t[7:]
    if VAR_RE.match(t):
        return "target %r is an unexpanded variable followed by nothing or a slash; an empty expansion turns this into rm on / or on the wrong tree. Use a literal path." % tok
    glob = False
    if t.endswith("/*"):
        glob = True
        t = t[:-2]
        if not t:
            t = "/"
    if t == "~":
        t = HOME
    elif t.startswith("~/"):
        t = HOME + t[1:]
    elif t.startswith("~"):
        t = os.path.expanduser(t)
    if not t.startswith("/"):
        if cwd and cwd.startswith("/"):
            t = os.path.join(cwd, t)
        else:
            return None
    t = os.path.normpath(t)
    if re.fullmatch(r"/+", t):
        t = "/"
    key = t.lower()
    if key != "/":
        key = key.rstrip("/") or "/"
    label = BLOCKED.get(key)
    if label is None:
        return None
    verb = "empties" if glob else "recursively deletes"
    return "target %r %s %s" % (tok, verb, label)

def analyze(words, cwd, depth, hits):
    i = 0
    n = len(words)
    while i < n:
        w = words[i].lstrip("`")
        if w in RESERVED:
            i += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
            i += 1
            continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            i += 1
            while i < n and words[i].startswith("-"):
                if base in ("sudo", "doas") and words[i] in ("-u", "-g") and i + 1 < n:
                    i += 2
                else:
                    i += 1
            if base == "timeout" and i < n and re.match(r"^[0-9]", words[i]):
                i += 1
            if base == "env":
                while i < n and "=" in words[i]:
                    i += 1
            continue
        break
    if i >= n:
        return
    w0 = words[i].lstrip("`")
    base = os.path.basename(w0)
    rest = words[i + 1:]
    if base in SHELLS and depth < 3:
        for j, w in enumerate(rest):
            if re.fullmatch(r"-[A-Za-z]*c", w) and j + 1 < len(rest):
                hits.extend(scan(rest[j + 1], cwd, depth + 1))
                break
        return
    if base == "eval" and depth < 3:
        hits.extend(scan(" ".join(rest), cwd, depth + 1))
        return
    if base not in ("rm", "grm"):
        return
    recursive = False
    ddash = False
    operands = []
    for w in rest:
        if not ddash and w == "--":
            ddash = True
            continue
        if not ddash and w.startswith("--") and len(w) > 2:
            if w == "--recursive":
                recursive = True
            continue
        if not ddash and w.startswith("-") and len(w) > 1:
            body = w[1:]
            if "r" in body or "R" in body:
                recursive = True
            continue
        operands.append(w)
    if not recursive:
        return
    for t in operands:
        r = classify(t, cwd)
        if r:
            hits.append(r)

def scan(cmd, cwd, depth):
    hits = []
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return hits
    for words in split_simple(tokens):
        analyze(words, cwd, depth, hits)
    return hits

def main():
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not cmd.strip():
        return
    cwd = data.get("cwd") or ""
    hits = scan(cmd, cwd, 0)
    if hits:
        seen = []
        for h in hits:
            if h not in seen:
                seen.append(h)
        sys.stdout.write("; ".join(seen))

try:
    main()
except Exception:
    pass
' 2>/dev/null)"

[ -z "$verdict" ] && exit 0
block "catastrophic-rm" "$verdict"
