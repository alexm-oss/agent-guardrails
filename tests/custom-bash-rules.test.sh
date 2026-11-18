#!/usr/bin/env bash
# Tests for hooks/custom-bash-rules.sh: the rule it ships with, and the
# switched-off example rule, which is switched on in a temporary copy so the
# README never teaches a pattern that does not work.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# ---------- the shipped rule: no-release-sideload ----------
HOOK="$HOOKS_DIR/custom-bash-rules.sh"
must_block 'adb install app-release.apk'
must_block 'adb install -r app/build/outputs/apk/release/app-release.apk'
must_block 'adb -s emulator-5554 install build/Release/app.apk'
must_block 'cd android && adb install app-release.apk'
must_allow 'adb install app-debug.apk'
must_allow 'adb -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk'
must_allow 'adb devices'
must_allow './gradlew assembleRelease'
must_allow 'adb install app-debug.apk && echo release notes updated'
# The example rule is off in the shipped file.
must_allow 'othercli deploy --prod'
must_fail_open

# ---------- the example rule, switched on in a temporary copy ----------
ENABLED="$TEST_HOME/custom-bash-rules.enabled.sh"
sed 's/^#EXAMPLE //' "$HOOKS_DIR/custom-bash-rules.sh" > "$ENABLED"
check "the temporary copy still parses" 0 "$(bash -n "$ENABLED" >/dev/null 2>&1; echo $?)"
HOOK="$ENABLED"
must_block 'othercli deploy --prod'
must_block 'npx othercli deploy'
must_block 'cd site && othercli deploy'
must_block 'npm run build; othercli deploy'
must_block 'npm install -g othercli'
must_block 'brew install othercli'
# Anchored to command position: prose that only mentions the tool passes.
must_allow 'echo "we do not use othercli deploy"'
must_allow 'git commit -m "docs: say why othercli deploy is banned"'
must_allow 'grep -rn othercli docs'
must_allow 'npm install'
# The shipped rule still works in the copy.
must_block 'adb install app-release.apk'

finish
