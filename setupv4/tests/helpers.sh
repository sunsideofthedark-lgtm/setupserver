#!/bin/bash
# ==============================================================================
# setupv4/tests/helpers.sh - Hilfsfunktionen für die Testsuite
# ==============================================================================
# Alle Tests laufen in einer Kopie unter $TMPDIR und verändern weder das
# Repository noch das Wirtssystem. Damit setup.sh nicht nach /opt/serversetup
# zieht, bekommt jeder Lauf ein eigenes SETUP_HOME im Sandkastenverzeichnis.
# ==============================================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="$(cd "$TESTS_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()
CURRENT_TEST=""

if [ -t 1 ]; then
    T_GREEN='\033[0;32m'; T_RED='\033[0;31m'; T_YELLOW='\033[0;33m'
    T_BLUE='\033[0;34m'; T_BOLD='\033[1m'; T_RESET='\033[0m'
else
    T_GREEN=''; T_RED=''; T_YELLOW=''; T_BLUE=''; T_BOLD=''; T_RESET=''
fi

test_case() { printf "  %s→%s %s\n" "$T_BLUE" "$T_RESET" "$1"; }
section()   { printf "\n%s%s%s\n" "$T_BOLD" "$1" "$T_RESET"; }

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "    %sOK%s   %s\n" "$T_GREEN" "$T_RESET" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("[$CURRENT_TEST] $1")
    printf "    %sFAIL%s %s\n" "$T_RED" "$T_RESET" "$1"
    [ -n "$2" ] && printf "         %s%s%s\n" "$T_YELLOW" "$2" "$T_RESET"
    return 0
}

# --- Assertions ---
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "erwartet: '$1' | erhalten: '$2'"; fi
}

assert_ne() {
    if [ "$1" != "$2" ]; then pass "$3"; else fail "$3" "sollte nicht sein: '$1'"; fi
}

assert_exit() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "Exit-Code erwartet: $1 | erhalten: $2"; fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "gesucht: '$2'"; fi
}

assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unerwartet gefunden: '$2'"; fi
}

assert_true() {
    if [ "$1" = "0" ]; then pass "$2"; else fail "$2"; fi
}

# --- Sandbox ---
SANDBOX_DIR=""
SANDBOX_HOME=""

sandbox_setup() {
    SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/setupv4-test-XXXXXX")" || return 1
    cp -r "$SETUP_DIR/." "$SANDBOX_DIR/" 2>/dev/null || return 1
    # Frühere Logfiles und ein eventuell vorhandenes Zielverzeichnis nicht mitschleppen
    rm -rf "$SANDBOX_DIR/logs" "$SANDBOX_DIR/.serversetup" 2>/dev/null
    SANDBOX_HOME="$SANDBOX_DIR/.serversetup"
    mkdir -p "$SANDBOX_HOME"
    echo "$SANDBOX_DIR"
}

sandbox_cleanup() {
    [ -n "$SANDBOX_DIR" ] && rm -rf "$SANDBOX_DIR"
    SANDBOX_DIR=""
    SANDBOX_HOME=""
}

# Führt setup.sh in der Sandbox aus. stdout+stderr landen in $OUTPUT,
# der Exit-Code in $EXIT_CODE. SETUP_HOME zeigt in die Sandbox, damit die
# Selbstinstallation nach /opt/serversetup nicht getestet wird.
OUTPUT=""
EXIT_CODE=0
run_setup() {
    OUTPUT=$(cd "$SANDBOX_DIR" && SETUP_HOME="$SANDBOX_HOME" bash ./setup.sh "$@" 2>&1)
    EXIT_CODE=$?
    return 0
}

test_summary() {
    echo ""
    echo "============================================================"
    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "  %sALLE TESTS BESTANDEN%s  (%d)\n" "$T_GREEN" "$T_RESET" "$PASS_COUNT"
        echo "============================================================"
        return 0
    fi

    printf "  %s%d FEHLGESCHLAGEN%s, %d bestanden\n" "$T_RED" "$FAIL_COUNT" "$T_RESET" "$PASS_COUNT"
    echo "------------------------------------------------------------"
    local t
    for t in "${FAILED_TESTS[@]}"; do
        echo "  • $t"
    done
    echo "============================================================"
    return 1
}