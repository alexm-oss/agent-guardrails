#!/usr/bin/env bash
# Keeps the kit shareable: no personal paths, no addresses, no stray bytes.
# The patterns are generic shapes on purpose; this file lists nobody's names.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

result="$(python3 - "$KIT_DIR" <<'PY'
import os, re, sys

root = sys.argv[1]
checks = [
    ("a home path with a user name in it", re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+")),
    ("an email address", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("an IPv4 address", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
]
problems = []
files = 0
for folder, dirs, names in os.walk(root):
    dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
    for name in sorted(names):
        if name == ".DS_Store" or name.endswith(".pyc"):
            continue  # files the operating system or Python leaves behind; .gitignore keeps them out
        path = os.path.join(folder, name)
        rel = os.path.relpath(path, root)
        with open(path, "rb") as fh:
            raw = fh.read()
        files += 1
        try:
            text = raw.decode("ascii")
        except UnicodeDecodeError as exc:
            line = raw[:exc.start].count(b"\n") + 1
            problems.append("%s:%d: a non-ASCII byte (the kit is plain ASCII)" % (rel, line))
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for label, rx in checks:
                if rx.search(line):
                    problems.append("%s:%d: %s" % (rel, n, label))
for p in problems:
    print(p)
print("files=%d problems=%d" % (files, len(problems)))
PY
)"

echo "$result" | grep -v '^files=' || true
summary="$(echo "$result" | tail -1)"
check "no personal paths, addresses or non-ASCII bytes ($summary)" 0 "${summary##*problems=}"
check "the scan read the kit files" yes "$(echo "$summary" | grep -Eq '^files=[1-9]' && echo yes || echo no)"

finish
