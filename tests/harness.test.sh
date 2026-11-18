#!/usr/bin/env bash
# Tests for tests/lib.sh itself: the harness deletes its temporary folder when
# it exits, so it must never be able to mistake another folder for that one.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

PROBE="$TEST_HOME/probe.test.sh"
cat > "$PROBE" <<PROBE_EOF
#!/usr/bin/env bash
. "$KIT_DIR/tests/lib.sh"
echo "the harness carried on with TEST_HOME=[\$TEST_HOME]"
finish
PROBE_EOF

# A work folder with one file in it stands in for a user's clone.
WORK="$TEST_HOME/work"
mkdir -p "$WORK"
echo keep > "$WORK/keep.txt"

# With TMPDIR pointing nowhere, mktemp fails. The harness must stop at once.
out="$(cd "$WORK" && TMPDIR="$TEST_HOME/no-such-folder" bash "$PROBE" 2>&1)"
check "a failed mktemp stops the harness with exit 1" 1 "$(cd "$WORK" && TMPDIR="$TEST_HOME/no-such-folder" bash "$PROBE" >/dev/null 2>&1; echo $?)"
check "it says no test was run" yes "$(echo "$out" | grep -q 'no test was run' && echo yes || echo no)"
check "it did not carry on" 0 "$(echo "$out" | grep -c 'carried on')"
check "the folder it was started in is untouched" keep "$(cat "$WORK/keep.txt" 2>/dev/null)"

# With a working TMPDIR the same probe runs and removes only its own folder.
mkdir -p "$TEST_HOME/tmp-ok"
out="$(cd "$WORK" && TMPDIR="$TEST_HOME/tmp-ok" bash "$PROBE" 2>&1)"
check "with a working TMPDIR the probe runs" yes "$(echo "$out" | grep -q 'carried on with TEST_HOME=\[.*agent-guardrails-test\.' && echo yes || echo no)"
check "the probe removed its own temporary folder" 0 "$(find "$TEST_HOME/tmp-ok" -mindepth 1 | wc -l | tr -d ' ')"
check "the work folder is still untouched" keep "$(cat "$WORK/keep.txt" 2>/dev/null)"

finish
