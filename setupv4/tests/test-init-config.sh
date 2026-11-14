#!/bin/bash
# ==============================================================================
# setupv4/tests/test-init-config.sh - --init und --config-Pfadauflösung
# ==============================================================================
# Prüft das Verhalten, das auf einem frischen Server auffiel:
#   1. "--init" erzeugt eine benutzbare config/setup.conf (Exit 0)
#   2. Ein zweiter "--init" überschreibt die Datei nicht (Exit 1)
#   3. Die erzeugte Datei ist gültiges Bash und enthält keine Anleitung
#      mehr, die auf setup.conf.example zeigt
#   4. Ein relativer --config-Pfad wird auch unter $CONFIG_DIR gefunden;
#      ein nicht existierender Pfad nennt den absoluten Pfad (Exit 1)
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

# SETUP_HOME der Sandbox - dorthin verlagert sich das Script.
GENERATED="$SANDBOX_HOME/config/setup.conf"

section "1. --init erzeugt config/setup.conf"

run_setup --init
assert_exit 0 "$EXIT_CODE" "--init endet mit Exit 0"

if [ -f "$GENERATED" ]; then
    pass "config/setup.conf wurde im Configverzeichnis erzeugt"
else
    fail "config/setup.conf fehlt: $GENERATED"
fi

assert_contains "$OUTPUT" "$GENERATED" "Ausgabe nennt den Pfad der erzeugten Datei"
assert_not_contains "$OUTPUT" "setup.conf.example" "Ausgabe erwähnt die Vorlage nicht"

section "2. Zweiter --init überschreibt nicht"

if [ -f "$GENERATED" ]; then
    before="$(cat "$GENERATED")"

    run_setup --init
    assert_exit 1 "$EXIT_CODE" "Zweiter --init endet mit Exit 1"

    after="$(cat "$GENERATED")"
    assert_eq "$before" "$after" "Inhalt der setup.conf bleibt unverändert"
    assert_contains "$OUTPUT" "rm $GENERATED" "Warnung nennt den konkreten rm-Befehl"
else
    fail "Voraussetzung fehlt: $GENERATED wurde nicht erzeugt"
fi

section "3. Erzeugte Datei ist gültiges Bash"

if [ -f "$GENERATED" ]; then
    content="$(cat "$GENERATED")"

    assert_not_contains "$content" "setup.conf.example" "Kein Verweis auf die Vorlage"
    assert_contains "$content" "config/setup.conf" "Datei nennt ihren eigenen Pfad"
    assert_contains "$content" "sudo bash setup.sh --config" "Datei nennt den Aufruf"

    bash -n "$GENERATED" 2>/dev/null
    assert_true "$?" "Erzeugte setup.conf ist syntaktisch gültiges Bash (bash -n)"

    listed=$(sed -n '/^MODULES=(/,/^)/p' "$GENERATED" | grep -cE '^[[:space:]]+[a-z0-9-]+')
    expected=$(find "$SANDBOX_DIR/modules" -name '*.sh' -type f | wc -l | tr -d ' ')
    assert_eq "$expected" "$listed" "Erzeugte setup.conf listet jedes Modul"
else
    fail "Voraussetzung fehlt: $GENERATED wurde nicht erzeugt"
fi

section "4. Relativer --config-Pfad"

# Die Datei liegt nur unter $CONFIG_DIR, nicht im Arbeitsverzeichnis -
# genau der Fall, der vorher mit "Config-Datei nicht gefunden" abbrach.
run_setup --config config/setup.conf --list
assert_exit 0 "$EXIT_CODE" "Relativer Pfad wird unter \$CONFIG_DIR gefunden"
assert_contains "$OUTPUT" "verwende: $GENERATED" "Verwendete Datei wird als INFO geloggt"
assert_contains "$OUTPUT" "Config geladen: $GENERATED" "Geladene Datei wird ausgegeben"

# Ein Pfad, der nirgends existiert
run_setup --config config/gibtsnicht.conf --list
assert_exit 1 "$EXIT_CODE" "Nicht existierender Pfad endet mit Exit 1"
assert_contains "$OUTPUT" "$SANDBOX_DIR/config/gibtsnicht.conf" \
    "Fehlermeldung nennt den aufgeloesten absoluten Pfad"
assert_contains "$OUTPUT" "$SANDBOX_HOME/config/setup.conf" \
    "Fehlermeldung verweist auf \$CONFIG_DIR/setup.conf"

section "5. .gitignore schützt die erzeugte Datei"

GITIGNORE="$SANDBOX_DIR/.gitignore"
if [ -f "$GITIGNORE" ]; then
    assert_contains "$(cat "$GITIGNORE")" "config/setup.conf" \
        ".gitignore schließt die erzeugte config/setup.conf aus"
else
    fail ".gitignore fehlt in setupv4"
fi

test_summary
