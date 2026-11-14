#!/bin/bash
# ==============================================================================
# setupv4/tests/test-module-switches.sh - Schalter-Semantik der Module
# ==============================================================================
# Prüft die einheitliche Semantik aus lib/modules.sh:
#
#   * Schalter gesetzt             -> das Modul läuft
#   * Modul gesondert benannt      -> das Modul läuft auch ohne Schalter
#   * Sammelauswahl ohne Schalter   -> das Modul wird übersprungen (kein Fehler)
#   * fehlende Voraussetzung       -> Skip statt Fehler
#
# Hintergrund: Bei einem "Komplettes Setup" ohne Config-Datei liefen die
# Module komodo, pangolin, clamav und omnisight trotz fehlender Schalter an
# und schlugen an fehlenden Voraussetzungen fehl (Docker, Pakete, 404).
#
# Das Wirtssystem wird nicht verändert: die vollständigen Läufe gehen über
# --dry-run, die isolierten Modulläufe über PATH-Shadowing mit Fake-Binaries
# in einem temporären Verzeichnis.
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

# Liefert die Zusammenfassungszeile eines Moduls aus der Setup-Ausgabe.
# Die Zeilen der Modulliste ("  • komodo - ...") beginnen mit dem Bullet und
# werden deshalb nicht mit erfasst.
module_line() {
    local output="$1" module_id="$2"
    printf '%s\n' "$output" | grep -E "^[[:space:]]{2}${module_id}[[:space:]]" | head -n1
}

# Führt setup.sh mit den Fake-Binaries im PATH aus. So greift kein echtes
# curl ins Netz und der Lauf bleibt unabhängig von der Erreichbarkeit der
# Omnisight-Instanz.
run_setup_faked() {
    local saved_path="$PATH"
    PATH="$FAKE_BIN:$PATH"
    run_setup "$@"
    PATH="$saved_path"
    return 0
}

# --- Fake-Binaries -------------------------------------------------------
# Verzeichnis mit Werkzeugen, die auf den Testfall zeigen. Docker fehlt
# hier bewusst - so lässt sich der Pfad "Voraussetzung fehlt" prüfen.
FAKE_BIN="$SANDBOX_DIR/fakebin"
mkdir -p "$FAKE_BIN"

for tool in date sleep hostname grep sed awk cut head tail cat ls mkdir chmod tr id uname; do
    real_path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$real_path" "$FAKE_BIN/$tool"
done

# Fake-curl: liefert je nach URL einen HTTP-Statuscode.
#   * "missing" im Pfad -> 404
#   * "unreachable" im Pfad -> 000 (keine Verbindung)
#   * sonst -> 200
# Im Download-Modus (ohne -w) wird ein harmloses Skript geliefert.
cat > "$FAKE_BIN/curl" << 'FAKECURL'
#!/bin/bash
has_write_out=0
url=""
for arg in "$@"; do
    case "$arg" in
        -w|--write-out) has_write_out=1 ;;
        http://*|https://*) url="$arg" ;;
    esac
done

if [ "$has_write_out" -eq 0 ]; then
    printf '#!/bin/bash\nexit 0\n'
    exit 0
fi

case "$url" in
    *missing*|*404*)    echo 404 ;;
    *unreachable*)      echo 000; exit 7 ;;
    *)                  echo 200 ;;
esac
exit 0
FAKECURL
chmod +x "$FAKE_BIN/curl"

# --- Isolierter Modulaufruf ----------------------------------------------
# Führt ein einzelnes Modul ohne den restlichen Setup-Lauf aus und liefert
# dessen Rückgabewert. PATH kommt über FAKE_PATH, damit nur die
# Fake-Binaries sichtbar sind.
cat > "$SANDBOX_DIR/run-module.sh" << 'RUNMODULE'
#!/bin/bash
# Aufruf: run-module.sh <setup-dir> <moduldatei> [KEY=WERT ...]
SETUP_DIR="$1"
MODULE_FILE="$2"
shift 2

export SETUP_DIR
export LOGFILE="${LOGFILE:-${TMPDIR:-/tmp}/setupv4-modultest.log}"

# Nur die Fake-Binaries sichtbar machen - dort liegt bewusst kein docker.
if [ -n "${FAKE_PATH:-}" ]; then
    export PATH="$FAKE_PATH"
fi

# Nicht-interaktiv: sonst würde eine Abfrage auf stdin blockieren.
export NON_INTERACTIVE="${NON_INTERACTIVE:-1}"

# shellcheck disable=SC1090
. "$SETUP_DIR/lib/core.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/os.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/config.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/modules.sh"
# shellcheck disable=SC1090
. "$MODULE_FILE"

config_set_defaults

for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf -v "$key" '%s' "$value"
done

module_main
RUNMODULE

run_module_isolated() {
    local module_file="$1"
    shift
    FAKE_PATH="$FAKE_BIN" bash "$SANDBOX_DIR/run-module.sh" \
        "$SANDBOX_DIR" "$module_file" "$@" 2>&1
}

# ==============================================================================
section "1. Sammelauswahl ohne gesetzte Schalter überspringt die Module"
# ==============================================================================
cat > "$SANDBOX_DIR/switch-off.conf" << 'EOF'
MODULES=(komodo pangolin clamav omnisight)
EOF

run_setup_faked --config switch-off.conf --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "Lauf ohne gesetzte Schalter endet mit Exit 0"

for id in komodo pangolin clamav omnisight; do
    line="$(module_line "$OUTPUT" "$id")"
    assert_contains "$line" "ÜBERSPRUNGEN" "$id wird bei einer Sammelauswahl ohne Schalter übersprungen"
done

# Die Skip-Meldung muss den Schalter nennen - nur so ist belegt, dass der
# Schalter und nicht eine fehlende Voraussetzung zum Überspringen führte.
assert_contains "$OUTPUT" "INSTALL_KOMODO ist nicht gesetzt - Komodo Periphery wird nicht eingerichtet." "Komodo nennt seinen Schalter in der Skip-Meldung"
assert_contains "$OUTPUT" "INSTALL_PANGOLIN ist nicht gesetzt - Pangolin SPK-Provisioning wird nicht eingerichtet." "Pangolin nennt seinen Schalter in der Skip-Meldung"
assert_contains "$OUTPUT" "INSTALL_CLAMAV ist nicht gesetzt - ClamAV wird nicht eingerichtet." "ClamAV nennt seinen Schalter in der Skip-Meldung"
assert_contains "$OUTPUT" "INSTALL_OMNISIGHT ist nicht gesetzt - Omnisight Agent wird nicht eingerichtet." "Omnisight nennt seinen Schalter in der Skip-Meldung"

assert_not_contains "$OUTPUT" "Fehlgeschlagene Module" "Kein Modul schlägt fehl"

section "1b. Ein gesetzter Schalter lässt das Modul laufen"
cat > "$SANDBOX_DIR/switch-on.conf" << 'EOF'
MODULES=(komodo pangolin clamav omnisight)
INSTALL_CLAMAV=true
EOF

run_setup_faked --config switch-on.conf --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "Lauf mit gesetztem Schalter endet mit Exit 0"

clamav_line="$(module_line "$OUTPUT" "clamav")"
assert_contains "$clamav_line" "OK" "ClamAV läuft, weil INSTALL_CLAMAV gesetzt ist"
assert_not_contains "$OUTPUT" "INSTALL_CLAMAV ist nicht gesetzt" "ClamAV läuft nicht trotz gesetztem Schalter"

for id in komodo pangolin omnisight; do
    line="$(module_line "$OUTPUT" "$id")"
    assert_contains "$line" "ÜBERSPRUNGEN" "$id bleibt ohne eigenen Schalter übersprungen"
done

# ==============================================================================
section "2. Gesondert benanntes Modul läuft auch ohne gesetzten Schalter"
# ==============================================================================
# 2a: die reine Funktion aus lib/modules.sh
fn_out=$(bash -c '
    . "$1/lib/core.sh"
    . "$1/lib/config.sh"
    . "$1/lib/modules.sh"
    MODULE_ID="clamav"
    INSTALL_CLAMAV=false
    EXPLICIT_MODULES=()
    module_switch_enabled INSTALL_CLAMAV; echo "sammel:$?"
    EXPLICIT_MODULES=("clamav")
    module_switch_enabled INSTALL_CLAMAV; echo "explizit:$?"
    INSTALL_CLAMAV=true
    EXPLICIT_MODULES=()
    module_switch_enabled INSTALL_CLAMAV; echo "schalter:$?"
' _ "$SANDBOX_DIR" 2>/dev/null)

assert_contains "$fn_out" "sammel:1" "Ohne Schalter und ohne Nennung läuft das Modul nicht"
assert_contains "$fn_out" "explizit:0" "Ein gesondert benanntes Modul läuft ohne Schalter"
assert_contains "$fn_out" "schalter:0" "Ein gesetzter Schalter lässt das Modul laufen"

# 2b: derselbe Fall über die Kommandozeile
run_setup_faked --modules clamav --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "Lauf mit --modules clamav endet mit Exit 0"

clamav_line="$(module_line "$OUTPUT" "clamav")"
assert_contains "$clamav_line" "OK" "Mit --modules benanntes Modul läuft ohne gesetzten Schalter"

# ==============================================================================
section "3. Fehlendes Docker führt zum Skip statt zum Fehler"
# ==============================================================================
komodo_out="$(run_module_isolated "$SANDBOX_DIR/modules/92-komodo.sh" "INSTALL_KOMODO=true")"
komodo_rc=$?
assert_exit 1 "$komodo_rc" "Komodo ohne Docker endet mit Skip (1)"
assert_ne 2 "$komodo_rc" "Komodo ohne Docker meldet keinen Fehler (2)"
assert_contains "$komodo_out" "Docker ist nicht installiert" "Komodo nennt die fehlende Voraussetzung im Klartext"
assert_not_contains "$komodo_out" "Docker ist für Komodo Periphery erforderlich" "Keine alte Fehlermeldung mehr"

pangolin_out="$(run_module_isolated "$SANDBOX_DIR/modules/93-pangolin.sh" "INSTALL_PANGOLIN=true")"
pangolin_rc=$?
assert_exit 1 "$pangolin_rc" "Pangolin ohne Docker endet mit Skip (1)"
assert_ne 2 "$pangolin_rc" "Pangolin ohne Docker meldet keinen Fehler (2)"
assert_contains "$pangolin_out" "Docker ist nicht installiert" "Pangolin nennt die fehlende Voraussetzung im Klartext"

# ==============================================================================
section "4. Omnisight prüft die Installations-URL"
# ==============================================================================
omni_out="$(run_module_isolated "$SANDBOX_DIR/modules/96-omnisight.sh" \
    "INSTALL_OMNISIGHT=true" \
    "OMNISIGHT_URL=https://omnisight.example.invalid" \
    "OMNISIGHT_INSTALL_URL=https://omnisight.example.invalid/agent/missing.sh" \
    "OMNISIGHT_TOKEN=test-token-0123456789" \
    "NON_INTERACTIVE=0")"
omni_rc=$?

assert_exit 1 "$omni_rc" "Nicht erreichbare Installations-URL endet mit Skip (1)"
assert_ne 2 "$omni_rc" "Nicht erreichbare Installations-URL meldet keinen Fehler (2)"
assert_contains "$omni_out" "https://omnisight.example.invalid/agent/missing.sh" "Die Meldung nennt die geprüfte URL"
assert_contains "$omni_out" "OMNISIGHT_INSTALL_URL" "Die Meldung verweist auf OMNISIGHT_INSTALL_URL"
assert_not_contains "$omni_out" "curl: (22)" "Keine nackte curl-Fehlermeldung mehr"
assert_contains "$omni_out" "Verwende Omnisight URL: https://omnisight.example.invalid" "Der gesetzte OMNISIGHT_URL bleibt erhalten"

# Ohne erreichbare URL wird nicht installiert - der Installer läuft nicht.
assert_not_contains "$omni_out" "Installiere Omnisight Agent" "Bei fehlerhafter URL wird nicht installiert"

test_summary
