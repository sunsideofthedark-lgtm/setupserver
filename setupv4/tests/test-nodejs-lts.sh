#!/bin/bash
# ==============================================================================
# setupv4/tests/test-nodejs-lts.sh - Node.js installiert die aktuellste LTS
# ==============================================================================
# Prueft das Verhalten, das auf einem Server auffiel: das Modul hatte die
# LTS-Reihe 20.x fest verdrahtet - die ist seit April 2026 abgekaufen (EOL).
# Auf dem Server kam deshalb Node 20.20.2 statt der aktuellen LTS.
#
#   1. Die Zielversion wird NICHT fest verdrahtet, sondern ermittelt
#   2. Die Ermittlung liefert die aktuellste LTS aus der offiziellen Liste
#   3. Ein aelteres Node wird als veraltet erkannt und aktualisiert
#   4. Ein aktuelles Node wird nicht angefasst
#   5. NODEJS_MAJOR nagelt eine feste Major-Version fest
#   6. Der NodeSource-Alias "setup_lts.x" wird benutzt (nicht setup_20.x)
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

MODULES_DIR="$SANDBOX_DIR/modules"

# --- Die entscheidende Zeile im Modul: keine fest verdrahtete Version ---
section "1. Keine fest verdrahtete Node-Version"

module_src="$(cat "$MODULES_DIR/84-nodejs.sh")"

if printf '%s' "$module_src" | grep -qE 'setup_20\.x|node_20\.x|20\.x-LTS|20\.x-LTS-Reihe'; then
    fail "Im Modul steht noch eine fest verdrahtete Version (20.x)"
else
    pass "Keine fest verdrahtete 20.x-Version im Modul"
fi

if printf '%s' "$module_src" | grep -q 'setup_lts\.x'; then
    pass "Der NodeSource-Alias setup_lts.x wird benutzt"
else
    fail "Der NodeSource-Alias setup_lts.x fehlt"
fi

if printf '%s' "$module_src" | grep -q 'nodejs\.org/dist/index\.json'; then
    pass "Die LTS wird aus der offiziellen Liste ermittelt"
else
    fail "Die Ermittlung der LTS fehlt"
fi

# --- Die Ermittlungsfunktionen isoliert pruefen ---
section "2. Ermittlung der LTS-Version"

# Ein kleines Harness, das die echten Bibliotheken laedt. config_bool und
# module_switch_enabled kommen aus lib/ - ohne sie wuerde das Modul den
# Schalter als "nicht gesetzt" behandeln.
HARNESS="$SANDBOX_DIR/harness.sh"
cat > "$HARNESS" << 'HARNESS_EOF'
#!/bin/bash
# Laedt die Bibliotheken und das Node-Modul.
MODULES_DIR="$1"
. "$MODULES_DIR/../lib/core.sh" 2>/dev/null
. "$MODULES_DIR/../lib/config.sh" 2>/dev/null
. "$MODULES_DIR/../lib/modules.sh" 2>/dev/null
. "$MODULES_DIR/84-nodejs.sh" 2>/dev/null

case "$2" in
    target)   node_target_major ;;
    installed) node_installed_major ;;
    pinned)
        # node_target_major setzt das Flag - es muss aber zuerst laufen.
        node_target_major >/dev/null
        printf 'NODEJS_PINNED=%s\n' "$NODEJS_PINNED"
        ;;
    audit)    module_audit ;;
esac
HARNESS_EOF

# Testliste: die erste Zeile mit gesetztem "lts"-Feld ist die aktuellste LTS.
cat > "$SANDBOX_DIR/index.json" << 'JSON_EOF'
[
{"version":"v27.0.0-alpha.0","date":"2026-11-01","lts":false},
{"version":"v26.13.1","date":"2026-11-05","lts":"Lithium"},
{"version":"v26.13.0","date":"2026-10-28","lts":"Lithium"},
{"version":"v26.12.0","date":"2026-10-14","lts":false},
{"version":"v24.9.1","date":"2026-09-20","lts":"Krypton"}
]
JSON_EOF

# Fake-curl: liefert die Testliste statt der echten
FAKE_BIN="$SANDBOX_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" << 'CURL_EOF'
#!/bin/bash
# Gibt die Testliste fuer den Abruf der Verzeichnisse aus.
for arg in "$@"; do
    case "$arg" in
        https://nodejs.org/dist/index.json)
            cat "$CURL_INDEX_FILE"
            exit 0
            ;;
    esac
done
exit 1
CURL_EOF
chmod +x "$FAKE_BIN/curl"

export CURL_INDEX_FILE="$SANDBOX_DIR/index.json"

target="$(PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" target 2>/dev/null)"
assert_eq "26" "$target" "Die aktuellste LTS wird als Major-Version erkannt (26)"

# --- Erkennung eines veralteten Node ---
section "3. Vorhandenes Node.js wird bewertet"

# Fake-node mit einer bestimmten Version
make_fake_node() {
    local version="$1"
    cat > "$FAKE_BIN/node" << NODE_EOF
#!/bin/bash
echo "$version"
NODE_EOF
    chmod +x "$FAKE_BIN/node"
}

make_fake_node "v20.20.2"
installed="$(PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" installed 2>/dev/null)"
assert_eq "20" "$installed" "Die Major-Version des installierten Node wird erkannt (20)"

make_fake_node "v26.13.1"
installed="$(PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" installed 2>/dev/null)"
assert_eq "26" "$installed" "Die Major-Version des aktuellen Node wird erkannt (26)"

make_fake_node "v27.0.0"
installed="$(PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" installed 2>/dev/null)"
assert_eq "27" "$installed" "Ein neueres Node als die LTS wird erkannt (27)"

# --- NODEJS_MAJOR festnageln ---
section "4. NODEJS_MAJOR nagelt eine feste Version fest"

pinned_out="$(NODEJS_MAJOR=22 PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" target 2>/dev/null)"
assert_eq "22" "$pinned_out" "NODEJS_MAJOR=22 wird als Ziel verwendet"

pinned_flag="$(NODEJS_MAJOR=22 PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" pinned 2>/dev/null)"
assert_contains "$pinned_flag" "NODEJS_PINNED=1" "Eine festgenagelte Version wird als solche markiert"

# Ohne Festnagelung wird die aktuelle LTS genommen und nicht als "gepinnt" markiert.
auto_flag="$(PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" pinned 2>/dev/null)"
assert_contains "$auto_flag" "NODEJS_PINNED=0" "Ohne NODEJS_MAJOR wird nicht gepinnt"

# Ein ungueltiger Wert darf nicht als Major-Version durchgehen.
bad_out="$(NODEJS_MAJOR=abc PATH="$FAKE_BIN:$PATH" bash "$HARNESS" "$MODULES_DIR" target 2>/dev/null)"
assert_eq "26" "$bad_out" "Ein ungueltiges NODEJS_MAJOR faellt auf die aktuelle LTS zurueck"

# --- Die Modul-Audit-Ausgabe ---
section "5. Audit meldet ein veraltetes Node.js"

# Das Audit muss ein aelteres Node als Abweichung melden.
make_fake_node "v20.20.2"
audit_out="$(INSTALL_NODEJS=true PATH="$FAKE_BIN:$PATH" \
    bash "$HARNESS" "$MODULES_DIR" audit 2>/dev/null)"

if printf '%s' "$audit_out" | grep -q "abweichung"; then
    pass "Ein veraltetes Node wird als Abweichung gemeldet"
else
    fail "Ein veraltetes Node wird nicht als Abweichung gemeldet: $audit_out"
fi

# Und ein aktuelles Node als ok.
make_fake_node "v26.13.1"
audit_ok="$(INSTALL_NODEJS=true PATH="$FAKE_BIN:$PATH" \
    bash "$HARNESS" "$MODULES_DIR" audit 2>/dev/null)"

if printf '%s' "$audit_ok" | grep -q "^ok|"; then
    pass "Ein aktuelles Node wird als ok gemeldet"
else
    fail "Ein aktuelles Node wird nicht als ok gemeldet: $audit_ok"
fi

# Ohne gesetzten Schalter meldet das Audit "nicht angefordert".
audit_off="$(INSTALL_NODEJS=false PATH="$FAKE_BIN:$PATH" \
    bash "$HARNESS" "$MODULES_DIR" audit 2>/dev/null)"

if printf '%s' "$audit_off" | grep -q "^info|"; then
    pass "Ohne Schalter meldet das Audit 'nicht angefordert'"
else
    fail "Ohne Schalter meldet das Audit falsch: $audit_off"
fi

# --- Die Konfiguration kennt den Schalter ---
section "6. Der Schalter ist als Config-Schluessel bekannt"

if grep -q 'NODEJS_MAJOR' "$SANDBOX_DIR/lib/config.sh"; then
    pass "NODEJS_MAJOR steht in lib/config.sh"
else
    fail "NODEJS_MAJOR fehlt in lib/config.sh"
fi

if grep -q 'NODEJS_MAJOR' "$SANDBOX_DIR/config/setup.conf.example"; then
    pass "NODEJS_MAJOR steht in der Beispielkonfiguration"
else
    fail "NODEJS_MAJOR fehlt in der Beispielkonfiguration"
fi

test_summary
