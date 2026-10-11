#!/bin/bash
# ==============================================================================
# setupv4/tests/run-tests.sh - Test-Runner
# ==============================================================================
# Aufruf:
#   bash tests/run-tests.sh            alle Tests
#   bash tests/run-tests.sh framework  nur test-framework.sh
#
# Die Tests laufen ausschliesslich in einer Kopie unter $TMPDIR und setzen ein
# eigenes SETUP_HOME, sodass weder das Repository noch /opt/serversetup
# verändert werden.
# ==============================================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
    C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_GREEN=''; C_RED=''; C_BOLD=''; C_RESET=''
fi

# setup.sh verlangt Root. In CI und auf Serien ohne Root wird per sudo
# nachgeholt.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "Hinweis: setup.sh benötigt Root - Tests werden per sudo ausgeführt."
        exec sudo -E bash "$0" "$@"
    else
        echo "FEHLER: Root-Rechte erforderlich (setup.sh prüft das selbst)." >&2
        exit 1
    fi
fi

filter="${1:-}"
total_pass=0
total_fail=0
failed_files=()

if [ -n "$filter" ]; then
    test_files=("$TESTS_DIR/test-${filter}.sh")
else
    test_files=("$TESTS_DIR"/test-*.sh)
fi

if [ ! -e "${test_files[0]}" ]; then
    echo "Kein Test mit dem Namen '$filter' gefunden."
    echo "Verfügbar:"
    for f in "$TESTS_DIR"/test-*.sh; do
        echo "  $(basename "$f" .sh | sed 's/^test-//')"
    done
    exit 1
fi

printf "%s============================================================%s\n" "$C_BOLD" "$C_RESET"
printf "%ssetupv4 - Testsuite%s\n" "$C_BOLD" "$C_RESET"
printf "============================================================\n"

for test_file in "${test_files[@]}"; do
    [ -e "$test_file" ] || continue
    name=$(basename "$test_file" .sh | sed 's/^test-//')

    printf "\n%s### %s ###%s\n" "$C_BOLD" "$name" "$C_RESET"

    output=$(bash "$test_file" 2>&1)
    rc=$?
    echo "$output"

    # Die Zähler stehen in der Zusammenfassung der einzelnen Testdatei
    p=$(echo "$output" | grep -oE 'BESTANDEN  \([0-9]+\)' | grep -oE '[0-9]+' | tail -n1)
    f=$(echo "$output" | grep -oE '[0-9]+ FEHLGESCHLAGEN' | grep -oE '^[0-9]+' | tail -n1)
    [ -z "$p" ] && p=0
    [ -z "$f" ] && f=0

    total_pass=$((total_pass + p))
    total_fail=$((total_fail + f))

    if [ $rc -ne 0 ]; then
        failed_files+=("$name")
    fi
done

printf "\n%s============================================================%s\n" "$C_BOLD" "$C_RESET"
if [ ${#failed_files[@]} -eq 0 ] && [ "$total_fail" -eq 0 ]; then
    printf "%sGESAMT: %d Tests bestanden, 0 Fehler%s\n" "$C_GREEN" "$total_pass" "$C_RESET"
    printf "============================================================\n"
    exit 0
fi

printf "%sGESAMT: %d bestanden, %d Fehler%s\n" "$C_RED" "$total_pass" "$total_fail" "$C_RESET"
if [ ${#failed_files[@]} -gt 0 ]; then
    printf "Fehlgeschlagene Testdateien: %s\n" "${failed_files[*]}"
fi
printf "============================================================\n"
exit 1