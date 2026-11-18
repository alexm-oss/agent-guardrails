#!/usr/bin/env python3
"""Add or remove this kit's hook entries in a Claude Code settings.json.

Used by install.sh and uninstall.sh. Standard library only.

    settings.py check  SETTINGS
    settings.py add    SETTINGS HOOK_DIR [--dry-run] NAME=MATCHER ...
    settings.py remove SETTINGS HOOK_DIR [--dry-run] NAME ...

Rules it keeps:
  - Nothing that is already in the file is changed, reordered or removed,
    except this kit's own entries on `remove`. An entry is this kit's own only
    when it runs HOOK_DIR/NAME for one of the names given.
  - A file that cannot be read back exactly (not UTF-8, not valid JSON, a
    duplicate key, a number JSON cannot hold) or whose "hooks" section has an
    unexpected shape is left exactly as it is and the script exits 1.
  - The file is only written when something changes, and a copy is saved next
    to it first (settings.json.bak-agent-guardrails-<time>).
  - Running `add` twice changes nothing the second time.
"""
import json
import os
import re
import shlex
import shutil
import sys
import tempfile
import time

TIMEOUT_SECONDS = 10
SAFE_PATH = re.compile(r"^[A-Za-z0-9_@%+=:,./-]+$")
SHELLS = ("bash", "sh")


def die(msg):
    sys.stderr.write("agent-guardrails: %s\n" % msg)
    sys.exit(1)


def no_duplicate_keys(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("the key %r appears twice in one object" % key)
        out[key] = value
    return out


def finite_float(text):
    value = float(text)
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError("the number %s is too large to write back" % text)
    return value


def not_a_number(name):
    raise ValueError("%s is not a JSON number" % name)


def load(path):
    """Return (data, existed). Exits 1 on anything that cannot be written back as it was."""
    if not os.path.exists(path):
        return {}, False
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        die("cannot read %s: %s. Nothing was changed." % (path, exc))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        die("%s is not UTF-8 text. Fix it first. Nothing was changed." % path)
    if not text.strip():
        return {}, True
    try:
        data = json.loads(
            text,
            object_pairs_hook=no_duplicate_keys,
            parse_float=finite_float,
            parse_constant=not_a_number,
        )
    except ValueError as exc:
        die("%s cannot be read as plain JSON (%s). Fix it first. Nothing was changed." % (path, exc))
    if not isinstance(data, dict):
        die("%s does not hold a JSON object. Nothing was changed." % path)
    return data, True


def pretooluse(data, path, create):
    """Return the PreToolUse list, or None when it is absent and create is False."""
    hooks = data.get("hooks")
    if hooks is None:
        if not create:
            return None
        hooks = data["hooks"] = {}
    if not isinstance(hooks, dict):
        die('"hooks" in %s is not an object. Nothing was changed.' % path)
    groups = hooks.get("PreToolUse")
    if groups is None:
        if not create:
            return None
        groups = hooks["PreToolUse"] = []
    if not isinstance(groups, list):
        die('"hooks.PreToolUse" in %s is not a list. Nothing was changed.' % path)
    return groups


def command_for(script):
    """The settings.json command string for a script path (shell form)."""
    return script if SAFE_PATH.match(script) else shlex.quote(script)


def script_of(handler):
    """The script a command handler runs, as a normalised path, or None.

    Recognises a bare path and `bash <path>` / `sh <path>`. Anything with more
    words than that is somebody's own command and is never treated as ours.
    """
    if not isinstance(handler, dict) or handler.get("type") != "command":
        return None
    cmd = handler.get("command")
    if not isinstance(cmd, str):
        return None
    try:
        parts = shlex.split(cmd)
    except ValueError:
        return None
    if len(parts) == 2 and os.path.basename(parts[0]) in SHELLS:
        parts = parts[1:]
    if len(parts) != 1 or not parts[0]:
        return None
    return os.path.normpath(parts[0])


def handlers(groups):
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            for handler in group["hooks"]:
                yield handler


def backup(path):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = "%s.bak-agent-guardrails-%s" % (path, stamp)
    n = 1
    while os.path.exists(dest):
        n += 1
        dest = "%s.bak-agent-guardrails-%s-%d" % (path, stamp, n)
    shutil.copy2(path, dest)
    return dest


def write(path, data, existed):
    """Back up, then replace the file in one step. Follows a symlinked settings file."""
    real = os.path.realpath(path)
    if existed and not os.access(real, os.W_OK):
        die("%s is read-only. Nothing was changed." % path)
    try:
        text = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    except ValueError as exc:
        die("%s cannot be written back as JSON (%s). Nothing was changed." % (path, exc))
    folder = os.path.dirname(real) or "."
    tmp = None
    try:
        os.makedirs(folder, exist_ok=True)
        saved = backup(real) if existed else None
        fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=folder)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        if existed:
            shutil.copymode(real, tmp)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, real)
    except OSError as exc:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        die("cannot write %s: %s. The settings file was not changed." % (path, exc))
    return saved


def cmd_check(path):
    data, _ = load(path)
    pretooluse(data, path, create=False)
    return 0


def cmd_add(path, hook_dir, pairs, dry_run):
    data, existed = load(path)
    groups = pretooluse(data, path, create=True)
    present = {script_of(h) for h in handlers(groups)}
    added = []
    for pair in pairs:
        name, _, matcher = pair.partition("=")
        if not name or not matcher:
            die("bad NAME=MATCHER argument: %r" % pair)
        script = os.path.normpath(os.path.join(hook_dir, name))
        if script in present:
            print("  already in settings: %s" % name)
            continue
        groups.append({
            "matcher": matcher,
            "hooks": [{"type": "command", "command": command_for(script), "timeout": TIMEOUT_SECONDS}],
        })
        present.add(script)
        added.append((name, matcher))
    for name, matcher in added:
        print("  %s PreToolUse(%s): %s" % ("would add" if dry_run else "added", matcher, name))
    if not added:
        print("  settings unchanged: %s" % path)
        return 0
    if dry_run:
        print("  dry run: %s was not written" % path)
        return 0
    saved = write(path, data, existed)
    if saved:
        print("  backup: %s" % saved)
    print("  wrote: %s" % path)
    return 0


def cmd_remove(path, hook_dir, names, dry_run):
    data, existed = load(path)
    if not existed:
        print("  no settings file at %s, nothing to remove" % path)
        return 0
    groups = pretooluse(data, path, create=False)
    if groups is None:
        print("  settings unchanged: %s" % path)
        return 0
    ours = {os.path.normpath(os.path.join(hook_dir, name)) for name in names}
    removed = []
    kept_groups = []
    for group in groups:
        if not (isinstance(group, dict) and isinstance(group.get("hooks"), list)):
            kept_groups.append(group)
            continue
        kept = []
        for handler in group["hooks"]:
            script = script_of(handler)
            if script in ours:
                removed.append(os.path.basename(script))
            else:
                kept.append(handler)
        if len(kept) == len(group["hooks"]):
            kept_groups.append(group)
        elif kept:
            group["hooks"] = kept
            kept_groups.append(group)
        # a group left with no handlers held only this kit's entries: drop it
    if not removed:
        print("  settings unchanged: %s" % path)
        return 0
    for name in removed:
        print("  %s: %s" % ("would remove" if dry_run else "removed", name))
    if dry_run:
        print("  dry run: %s was not written" % path)
        return 0
    if kept_groups:
        data["hooks"]["PreToolUse"] = kept_groups
    else:
        del data["hooks"]["PreToolUse"]
        if not data["hooks"]:
            del data["hooks"]
    saved = write(path, data, existed)
    if saved:
        print("  backup: %s" % saved)
    print("  wrote: %s" % path)
    return 0


def main(argv):
    if len(argv) < 3:
        die("usage: settings.py check|add|remove SETTINGS [HOOK_DIR] [--dry-run] [NAME ...]")
    action, path, rest = argv[1], argv[2], argv[3:]
    dry_run = "--dry-run" in rest
    rest = [a for a in rest if a != "--dry-run"]
    if action == "check":
        return cmd_check(path)
    if action in ("add", "remove") and len(rest) >= 2:
        hook_dir = os.path.abspath(rest[0])
        if action == "add":
            return cmd_add(path, hook_dir, rest[1:], dry_run)
        return cmd_remove(path, hook_dir, rest[1:], dry_run)
    die("bad arguments for %r" % action)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
