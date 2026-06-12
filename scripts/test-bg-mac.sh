#!/usr/bin/env bash
# Validation harness for tap-bg / type-bg.
# Assertion model:
#   - "Click landed" = the app's observable state changed (counter, log, value).
#   - "No focus steal" = MacTestApp NEVER became frontmost during the test.
#     (iTerm2 going frontmost is fine — it's running this script.)
set -uo pipefail

P=~/.claude/skills/debug-kit/scripts
export MAC_APP=MacTestApp

read_counter() {
    bash "$P/mac-ctl.sh" read 2>/dev/null | grep -E "^\s+StaticText: [-]?[0-9]+$" | head -1 | grep -oE '[-]?[0-9]+$'
}

read_logs() {
    bash "$P/mac-ctl.sh" read 2>/dev/null | grep -E "Counter:|Alert " | head -3
}

read_first_textfield_val() {
    PID=$(pgrep -f MacTestApp | head -1)
    swift "$P/bg-act.swift" "$PID" dump 2>/dev/null | grep -E "id=nameInput" | head -1
}

is_mac_test_app_frontmost() {
    local f
    f=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null)
    [[ "$f" == "MacTestApp" ]]
}

PASSES=0
FAILS=0

run_test() {
    local name="$1" assertion="$2"
    shift 2
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    sleep 0.3

    # Sample frontmost during test (background poller)
    local sample_file=/tmp/_front_samples.txt
    : > "$sample_file"
    (
        for _ in {1..20}; do
            osascript -e 'tell application "System Events" to name of first process whose frontmost is true' >> "$sample_file" 2>/dev/null
            sleep 0.05
        done
    ) &
    local poller=$!

    # Run the action
    "$@" >/tmp/_test_out 2>&1
    local rc=$?
    sleep 0.4

    wait "$poller" 2>/dev/null
    local stole_focus="no"
    if grep -q '^MacTestApp$' "$sample_file" 2>/dev/null; then
        stole_focus="YES"
    fi

    # Run assertion (passed as bash function name)
    local pass_msg
    pass_msg=$($assertion 2>&1)
    local pass=$?

    if [[ $pass -eq 0 && "$stole_focus" == "no" ]]; then
        echo "  PASS  $name"
        echo "        $pass_msg"
        PASSES=$((PASSES + 1))
    else
        echo "  FAIL  $name (rc=$rc, stole_focus=$stole_focus)"
        echo "        $pass_msg"
        echo "        out: $(cat /tmp/_test_out | head -3)"
        FAILS=$((FAILS + 1))
    fi
}

# === Assertions for each test ===

assert_counter_incremented() {
    local now; now=$(read_counter)
    if [[ "$now" -eq "$((BEFORE_COUNTER + 1))" ]]; then
        echo "counter: $BEFORE_COUNTER → $now (+1) ✓"
        return 0
    fi
    echo "counter: $BEFORE_COUNTER → $now (expected +1)"
    return 1
}

assert_counter_decremented() {
    local now; now=$(read_counter)
    if [[ "$now" -eq "$((BEFORE_COUNTER - 1))" ]]; then
        echo "counter: $BEFORE_COUNTER → $now (-1) ✓"
        return 0
    fi
    echo "counter: $BEFORE_COUNTER → $now (expected -1)"
    return 1
}

assert_textfield_set() {
    local now; now=$(read_first_textfield_val)
    if [[ "$now" == *"$EXPECTED_VAL"* ]]; then
        echo "textfield contains \"$EXPECTED_VAL\" ✓"
        return 0
    fi
    echo "textfield = $now (expected to contain \"$EXPECTED_VAL\")"
    return 1
}

assert_log_appended() {
    local logs; logs=$(read_logs)
    if [[ "$logs" == *"$EXPECTED_LOG"* ]]; then
        echo "log contains \"$EXPECTED_LOG\" ✓"
        return 0
    fi
    echo "logs lack \"$EXPECTED_LOG\""
    return 1
}

# === Tests ===

echo ""
echo "=== bg-tap / bg-type validation ==="

# T1: tap-bg by id (incrementButton)
BEFORE_COUNTER=$(read_counter)
run_test "T1: tap-bg id incrementButton" assert_counter_incremented \
    bash "$P/mac-ctl.sh" tap-bg id incrementButton

# T2: tap-bg by id (decrementButton)
BEFORE_COUNTER=$(read_counter)
run_test "T2: tap-bg id decrementButton" assert_counter_decremented \
    bash "$P/mac-ctl.sh" tap-bg id decrementButton

# T3: tap-bg by desc (the "+" character)
BEFORE_COUNTER=$(read_counter)
run_test "T3: tap-bg desc +" assert_counter_incremented \
    bash "$P/mac-ctl.sh" tap-bg desc "+"

# T4: tap-bg by desc "Show Alert"
EXPECTED_LOG="Alert shown"
run_test "T4: tap-bg desc 'Show Alert'" assert_log_appended \
    bash "$P/mac-ctl.sh" tap-bg desc "Show Alert"

# Dismiss alert (cmd-period or click OK) — we'll just press OK by id
sleep 0.2
osascript -e 'tell application "System Events" to keystroke return' >/dev/null 2>&1 || true
# That may steal focus from the test if it requires the alert to be focused. Skip if alert lingers.

# T5: type-bg into nameInput (by id)
EXPECTED_VAL="Charlie"
run_test "T5: type-bg id nameInput Charlie" assert_textfield_set \
    bash "$P/mac-ctl.sh" type-bg "Charlie" id nameInput

# T6: type-bg first text field
EXPECTED_VAL="Bob"
run_test "T6: type-bg (first textfield) Bob" assert_textfield_set \
    bash "$P/mac-ctl.sh" type-bg "Bob"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
exit $FAILS
