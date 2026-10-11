#!/bin/bash
# ==============================================================================
# setupv4/tests/test-framework.sh - Framework: Syntax, CLI, Config, Ausgabe
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

section "1. Syntax aller Bash-Dateien"
syntax_fail=0
while IFS= read -r file; do
    if ! bash -n "$file" 2>/dev/null; then
        fail "Syntaxfehler: ${file#$SANDBOX_DIR/}"
        syntax_fail=1
    fi
done < <(find "$SANDBOX_DIR" -name '*.sh' -type f)
if [ $syntax_fail -eq 0 ]; then
    pass "Alle Shell-Dateien syntaktisch korrekt ($(find "$SANDBOX_DIR" -name '*.sh' | wc -l | tr -d ' ') Dateien)"
fi

section "2. Zeilenenden und BOM"
encoding_fail=0
while IFS= read -r file; do
    if grep -qU $'\r' "$file" 2>/dev/null; then
        fail "CRLF gefunden: ${file#$SANDBOX_DIR/}"
        encoding_fail=1
    fi
    if [ "$(head -c 3 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
        fail "BOM gefunden: ${file#$SANDBOX_DIR/}"
        encoding_fail=1
    fi
done < <(find "$SANDBOX_DIR" -name '*.sh' -type f)
[ $encoding_fail -eq 0 ] && pass "Keine CRLF-Zeilenenden und keine BOM"

section "3. --help und --list"
run_setup --help
assert_exit 0 "$EXIT_CODE" "--help liefert Exit 0"
assert_contains "$OUTPUT" "--config" "--help dokumentiert --config"
assert_contains "$OUTPUT" "--dry-run" "--help dokumentiert --dry-run"

run_setup --list
assert_exit 0 "$EXIT_CODE" "--list liefert Exit 0"
assert_contains "$OUTPUT" "system-update" "--list zeigt system-update"
assert_contains "$OUTPUT" "verify" "--list zeigt verify"

section "4. Selbstinstallation nach SETUP_HOME"
# setup.sh muss von jedem Startort aus nach $SETUP_HOME umziehen und dort
# weiterlaufen - inklusive der übergebenen Argumente (deshalb funktioniert
# der --list-Aufruf oben trotz Verlagerung).
if [ -f "$SANDBOX_HOME/setup.sh" ]; then
    pass "setup.sh liegt nach dem Lauf in SETUP_HOME"
else
    fail "setup.sh wurde nicht nach SETUP_HOME kopiert"
fi
if [ -f "$SANDBOX_HOME/logs/setup.log" ]; then
    pass "Logfile liegt unter SETUP_HOME/logs/"
    mode=$(stat -c '%a' "$SANDBOX_HOME/logs/setup.log" 2>/dev/null)
    assert_eq "600" "$mode" "Logfile hat Modus 600"
else
    fail "Kein Logfile unter SETUP_HOME/logs/"
fi
if [ -d "$SANDBOX_HOME/lib" ] && [ -d "$SANDBOX_HOME/modules" ]; then
    pass "Bibliotheken und Module liegen in SETUP_HOME"
else
    fail "lib/ oder modules/ fehlen in SETUP_HOME"
fi
# Kein Log im Ursprungsordner - sonst arbeitet es nicht vom Zielort aus
if [ -f "$SANDBOX_DIR/install.log" ] || [ -d "$SANDBOX_DIR/logs" ]; then
    fail "Im Ursprungsordner wurde ein Logfile erzeugt"
else
    pass "Im Ursprungsordner entsteht kein Logfile"
fi

section "5. Config-Validierung"
cat > "$SANDBOX_DIR/bad.conf" << 'EOF'
SERVER_HOSTNAME=" Ungueltig_Name! "
SSH_PORT=99999
ADMIN_USER="bad;user"
TIMEZONE="Mars/Olympus"
MODULES=(system-update)
EOF
run_setup --config bad.conf --non-interactive --dry-run
assert_exit 1 "$EXIT_CODE" "Ungültige Config führt zu Exit 1"
assert_contains "$OUTPUT" "SERVER_HOSTNAME ist ungültig" "Hostname-Fehler wird gemeldet"
assert_contains "$OUTPUT" "SSH_PORT ist ungültig" "Port-Fehler wird gemeldet"
assert_contains "$OUTPUT" "ADMIN_USER ist ungültig" "Benutzername-Fehler wird gemeldet"
assert_contains "$OUTPUT" "TIMEZONE ist unbekannt" "Zeitzonen-Fehler wird gemeldet"

cat > "$SANDBOX_DIR/good.conf" << 'EOF'
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SSH_PORT=2222
MODULES=(system-update)
EOF
run_setup --config good.conf --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "Gültige Config führt zu Exit 0"

section "6. Unbekannte Config-Schlüssel"
cat > "$SANDBOX_DIR/typo.conf" << 'EOF'
INSAL_DOCKER=true
SERVER_HOSTNAME="su-test"
MODULES=(system-update)
EOF
run_setup --config typo.conf --non-interactive --dry-run
assert_contains "$OUTPUT" "Unbekannter Config-Schlüssel" "Tippfehler wird gemeldet"
assert_contains "$OUTPUT" "INSAL_DOCKER" "Tippfehler wird beim Namen genannt"

section "7. Modulauswahl"
run_setup --modules gibtsnicht --non-interactive --dry-run
assert_exit 1 "$EXIT_CODE" "Unbekanntes Modul führt zu Exit 1"
assert_contains "$OUTPUT" "Unbekanntes Modul" "Unbekanntes Modul wird gemeldet"
assert_contains "$OUTPUT" "Verfügbare:" "Liste der verfügbaren Module wird gezeigt"

run_setup --config good.conf --set ADMIN_USER=override-user --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "--set wird akzeptiert"
assert_contains "$OUTPUT" "ADMIN_USER=override-user" "--set überschreibt den Wert"

run_setup --config good.conf --set KEIN_GUELTIGER_NAME --non-interactive --dry-run
assert_exit 1 "$EXIT_CODE" "--set ohne = wird abgelehnt"

run_setup --set "1BAD=2" --modules system-update --non-interactive --dry-run
assert_exit 1 "$EXIT_CODE" "--set mit ungültigem Variablennamen wird abgelehnt"

echo 'SERVER_HOSTNAME="su-test"' > "$SANDBOX_DIR/nomod.conf"
run_setup --config nomod.conf --non-interactive --dry-run
assert_exit 1 "$EXIT_CODE" "Non-interactive ohne Modulauswahl führt zu Exit 1"
assert_contains "$OUTPUT" "nicht-interaktiver Modus" "Abbruchgrund wird genannt"

section "8. Server-Profil"
HOST="$(hostname -s)"
mkdir -p "$SANDBOX_DIR/config/servers"
echo 'SERVER_HOSTNAME="aus-dem-profil"' > "$SANDBOX_DIR/config/servers/${HOST}.conf"
printf 'SERVER_HOSTNAME="aus-der-basis"\nMODULES=(system-update)\n' > "$SANDBOX_DIR/base.conf"

run_setup --config base.conf --non-interactive --dry-run
assert_contains "$OUTPUT" "Server-Profil gefunden" "Profil wird erkannt"
assert_contains "$OUTPUT" "SERVER_HOSTNAME=aus-dem-profil" "Profil gewinnt gegen Basis-Config"

run_setup --config base.conf --no-profile --non-interactive --dry-run
assert_not_contains "$OUTPUT" "Server-Profil gefunden" "--no-profile unterdrückt das Profil"
assert_contains "$OUTPUT" "SERVER_HOSTNAME=aus-der-basis" "Basis-Config gilt wieder"
rm -rf "$SANDBOX_DIR/config/servers"

section "9. Secrets aus der Umgebung"
# Die Config darf den Schlüssel NICHT leer zuweisen - sonst überschreibt sie
# den Wert aus der Umgebung.
cat > "$SANDBOX_DIR/zot.conf" << 'EOF'
ZOT_MIRRORS=true
ZOT_ENDPOINT="https://zot.sunriseing.dev"
MODULES=(zot-mirrors)
EOF
ZOT_API_KEY="MEIN_GEHEIMER_TOKEN_4711" run_setup --config zot.conf --non-interactive --dry-run
assert_contains "$OUTPUT" "ZOT_API_KEY=MEIN****4711" "API-Key aus Umgebung wird übernommen und maskiert"
assert_not_contains "$OUTPUT" "MEIN_GEHEIMER_TOKEN_4711" "API-Key erscheint nie im Klartext"

test_summary