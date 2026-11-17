#!/bin/bash
# ==============================================================================
# setupv4/tests/test-zot-verify-fixes.sh - Regressionen aus dem Serverlauf
# ==============================================================================
# Aus einem echten Serverlauf kamen mehrere Befunde, die jetzt behoben sind.
# Dieser Test haelt die Korrekturen fest:
#
#   1. ask_secret: ein optionales Secret (drittes Argument "optional") darf
#      leer bleiben. Vorher fragte die Funktion endlos nach - ein optionales
#      Secret (NetBird-Setup-Key, Zot-API-Key) war so gar nicht ueberspringbar.
#      Ohne "optional" wird bei leerer Eingabe nachgefragt, bei EOF
#      (stdin geschlossen) wird abgebrochen.
#   2. Bereichsangaben wie "11-3" (Start groesser als Ende) werden abgewiesen
#      und es wird NICHTS umgeschaltet - im Software-Menue und in der
#      modularen Modulauswahl.
#   3. Das Verify-Modul nennt beim IPv6-Test auch IPv6 und trennt den
#      Image-Pull vom Netzwerktest: ein fehlgeschlagener Pull darf nicht als
#      "IPv4-Verbindung nach aussen ist fehlgeschlagen" gemeldet werden.
#   4. Das Zot-Modul prueft den Mirror mit einem echten Test-Pull. Schlaegt
#      der Pull fehl, werden die hosts.toml-Dateien zurueckgerollt (sonst
#      blockiert der defekte Mirror jeden weiteren Pull) und das Modul
#      endet mit Exit 2.
#   5. NETBIRD_CONFIGURE ist per Default leer: im interaktiven Lauf wird nach
#      den Zugangsdaten gefragt, ein explizites "false" ueberspringt die
#      Verbindung ohne Nachfrage.
#   6. Das Docker-Port-Audit (docker-firewall) laeuft nach dem Docker-Modul.
#
# Das Wirtssystem wird nicht veraendert: die Module laufen in der Sandbox,
# alle externen Befehle sind Fake-Binaries (PATH-Shadowing) und die
# Zot-Pfade (ZOT_CERTS_DIR) zeigen in die Sandbox. Es wird nie nach
# /etc/docker, /etc/sudoers.d oder /etc/default geschrieben.
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Ein sauberer Linux-PATH: unter WSL haengen sonst die Windows-Verzeichnisse
# an PATH - dort liegen Programme mit anderen Namen und Optionen (sort ...),
# die den Testlauf unberechenbar machen wuerden.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

# Der Basis-PATH bleibt erhalten - die Fake-Binaries werden davor gesetzt,
# damit kein echter Befehl ins System oder ins Netz greift.
BASE_PATH="$PATH"

FAKE_BIN="$SANDBOX_DIR/fakebin"
mkdir -p "$FAKE_BIN"

# --- Fake-Binaries -------------------------------------------------------
# Fake-docker: kein echter Registry-Zugriff, kein echter Daemon.
#   * "docker info" meldet den containerd Image Store
#   * "docker pull" schlaegt fehl, wenn FAKE_DOCKER_PULL_FAIL=1
#   * "docker image inspect" findet das Image nur bei
#     FAKE_DOCKER_IMAGE_PRESENT=1
#   * "docker run" schlaegt fehl, wenn FAKE_DOCKER_RUN_FAIL=1
cat > "$FAKE_BIN/docker" << 'FAKEDOCKER'
#!/bin/bash
case "$1" in
    info)
        echo "${FAKE_DOCKER_DRIVER_STATUS:-io.containerd.snapshotter.v1}"
        exit 0
        ;;
    pull)
        if [ "${FAKE_DOCKER_PULL_FAIL:-0}" = "1" ]; then
            echo "Error response from daemon: pull access denied" >&2
            exit 1
        fi
        echo "Status: Downloaded newer image for $2"
        exit 0
        ;;
    login)
        echo "Login Succeeded"
        exit 0
        ;;
    image)
        if [ "${FAKE_DOCKER_IMAGE_PRESENT:-0}" = "1" ]; then
            echo "[]"
            exit 0
        fi
        echo "Error: No such image: $3" >&2
        exit 1
        ;;
    run)
        if [ "${FAKE_DOCKER_RUN_FAIL:-0}" = "1" ]; then
            echo "Error response from daemon: network is unreachable" >&2
            exit 1
        fi
        exit 0
        ;;
    network)
        exit 0
        ;;
esac
exit 0
FAKEDOCKER
chmod +x "$FAKE_BIN/docker"

# Fake-netbird: meldet keinen verbundenen Agenten (sonst waere die
# Konfiguration schon "erledigt") und beendet "netbird up" erfolgreich.
cat > "$FAKE_BIN/netbird" << 'FAKENETBIRD'
#!/bin/bash
case "$1" in
    status)
        # Bewusst kein "connected" im Text.
        echo "NetBird CLI is not running"
        exit 1
        ;;
    version)
        echo "netbird 0.28.0"
        exit 0
        ;;
    up)
        echo "ok"
        exit 0
        ;;
esac
exit 0
FAKENETBIRD
chmod +x "$FAKE_BIN/netbird"

# Fake-ip: kein Interface wt0 - die IPv4-Ermittlung bleibt leer.
cat > "$FAKE_BIN/ip" << 'FAKEIP'
#!/bin/bash
exit 0
FAKEIP
chmod +x "$FAKE_BIN/ip"

# Weitere Stubs, damit kein echter Dienst und kein Netzwerk benutzt wird.
for tool in ping curl systemctl ufw sleep; do
    cat > "$FAKE_BIN/$tool" << 'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$FAKE_BIN/$tool"
done

# --- Eingabedateien ------------------------------------------------------
IN_DIR="$SANDBOX_DIR/input"
mkdir -p "$IN_DIR"

# Nur ein Enter: leere Eingabe (und danach EOF).
printf '\n' > "$IN_DIR/empty.txt"
# Leere Eingabe, danach ein Secret zweimal (Eingabe + Wiederholung).
printf '\ngeheim\ngeheim\n' > "$IN_DIR/secret.txt"
# Umgekehrter Bereich.
printf '11-3\n' > "$IN_DIR/range.txt"
# Gueltiger Bereich zum Gegenprobe.
printf '1-2\n' > "$IN_DIR/range-ok.txt"
# Enter fuer die Management-URL, Enter fuer den Setup-Key.
printf '\n\n' > "$IN_DIR/netbird.txt"

# --- Isoliertes Harness --------------------------------------------------
# Laedt die Bibliotheken, optional ein Modul und ruft danach einen Befehl
# auf. Der Aufruf erfolgt in einem eigenen Prozess, damit Exit-Code und
# Variablen sauber getrennt bleiben.
#
# Aufruf: harness.sh <setup-dir> "<kommando>" [KEY=WERT ...]
#
# Umgebung:
#   HARNESS_MODULE   - Moduldatei, die zusaetzlich geladen wird
#   HARNESS_STDIN    - Datei, die als stdin dient
#   HARNESS_STATES   - "1": Schalterzustand am Ende ausgeben
#   HARNESS_SELECTED - "1": Modulauswahl am Ende ausgeben
#   HARNESS_PRINT    - Komma-Liste von Variablen, die ausgegeben werden
cat > "$SANDBOX_DIR/harness.sh" << 'HARNESS'
#!/bin/bash
SETUP_DIR="$1"
CMD="$2"
shift 2

export SETUP_DIR
export LOGFILE="${LOGFILE:-${TMPDIR:-/tmp}/setupv4-zot-verify.log}"
export DRY_RUN="${DRY_RUN:-0}"

MODULES_DIR="$SETUP_DIR/modules"

# shellcheck disable=SC1090
. "$SETUP_DIR/lib/core.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/os.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/config.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/modules.sh"

config_set_defaults

# Die Module laden, damit AVAILABLE_MODULES gefuellt ist (Software-Menue
# und modulare Auswahl lesen daraus).
discover_modules

if [ -n "${HARNESS_MODULE:-}" ]; then
    # shellcheck disable=SC1090
    . "$HARNESS_MODULE"
fi

# Die uebergebenen Variablen zuletzt setzen - sie sollen die Defaults und
# die Modulvariablen (z. B. ZOT_CERTS_DIR) ueberschreiben.
for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    printf -v "$key" '%s' "$value"
done

rc=0
eval "$CMD" < "${HARNESS_STDIN:-/dev/null}" || rc=$?

printf 'RC=%s\n' "$rc"

if [ -n "${HARNESS_PRINT:-}" ]; then
    for v in ${HARNESS_PRINT//,/ }; do
        printf 'VAR %s=[%s]\n' "$v" "${!v:-}"
    done
fi

if [ "${HARNESS_STATES:-0}" = "1" ]; then
    echo "=== SCHALTER ==="
    for sw in INSTALL_DOCKER INSTALL_NODEJS INSTALL_NGINX INSTALL_FAIL2BAN \
              INSTALL_CROWDSEC INSTALL_NETBIRD INSTALL_KOMODO INSTALL_PANGOLIN \
              INSTALL_GIT_SSH INSTALL_CLAMAV INSTALL_OMNISIGHT INSTALL_ZFS_ARC \
              INSTALL_NODE_EXPORTER ZOT_MIRRORS; do
        printf 'STATE %s=%s\n' "$sw" "${!sw:-leer}"
    done
fi

if [ "${HARNESS_SELECTED:-0}" = "1" ]; then
    echo "=== AUSWAHL ==="
    printf 'SELECTED_COUNT %s\n' "${#SELECTED_MODULES[@]}"
    if [ "${#SELECTED_MODULES[@]}" -gt 0 ]; then
        for m in "${SELECTED_MODULES[@]}"; do
            printf 'SELECTED %s\n' "$m"
        done
    fi
fi

exit $rc
HARNESS

# Fuehrt das Harness aus und liefert die Ausgabe. Der Exit-Code des
# aufgerufenen Befehls steht in $?. timeout faengt eine Endlosschleife ab.
run_harness() {
    local cmd="$1"
    shift

    timeout 30 env \
        PATH="$FAKE_BIN:$BASE_PATH" \
        HARNESS_MODULE="${HARNESS_MODULE:-}" \
        HARNESS_STDIN="${HARNESS_STDIN:-/dev/null}" \
        HARNESS_STATES="${HARNESS_STATES:-0}" \
        HARNESS_SELECTED="${HARNESS_SELECTED:-0}" \
        HARNESS_PRINT="${HARNESS_PRINT:-}" \
        bash "$SANDBOX_DIR/harness.sh" "$SANDBOX_DIR" "$cmd" "$@" 2>&1
}

# Zaehlt, wie oft ein Text in der Ausgabe vorkommt.
count_occurrences() {
    printf '%s\n' "$1" | grep -c -- "$2" || true
}

# Liefert nur die STATE-Zeilen einer Ausgabe.
state_block() {
    printf '%s\n' "$1" | grep '^STATE ' || true
}

# ==============================================================================
section "1. ask_secret mit 'optional' akzeptiert eine leere Eingabe"
# ==============================================================================
# Vorher fragte ask_secret endlos nach - ein optionales Secret war damit
# nicht ueberspringbar.
HARNESS_STDIN="$IN_DIR/empty.txt"
HARNESS_PRINT="SECRET"
secret_out="$(run_harness 'ask_secret "Test-Geheim" SECRET optional')"
secret_rc=$?

assert_exit 0 "$secret_rc" "Leere Eingabe bei 'optional' endet mit Exit 0"
assert_contains "$secret_out" "RC=0" "Das Harness meldet den Erfolg"
assert_contains "$secret_out" "SECRET=[]" "Die Variable bleibt leer"
assert_not_contains "$secret_out" "Eingabe darf nicht leer sein." \
    "Ein optionales Secret fragt nicht nach einer Eingabe"
assert_eq "1" "$(count_occurrences "$secret_out" "Test-Geheim: ")" \
    "Die Abfrage wurde genau einmal gestellt (keine Endlosschleife)"

# ==============================================================================
section "2. ask_secret ohne 'optional' fragt nach und bricht bei EOF ab"
# ==============================================================================
# Leere Eingabe -> Warnung und eine weitere Frage (nicht sofort abbrechen).
HARNESS_STDIN="$IN_DIR/secret.txt"
HARNESS_PRINT="SECRET"
secret_out="$(run_harness 'ask_secret "Test-Geheim" SECRET')"
secret_rc=$?

assert_exit 0 "$secret_rc" "Nach der Wiederholung endet die Abfrage mit Exit 0"
assert_contains "$secret_out" "Eingabe darf nicht leer sein." \
    "Eine leere Eingabe erzeugt die Warnung"
assert_eq "2" "$(count_occurrences "$secret_out" "Test-Geheim: ")" \
    "Nach der Warnung wird erneut gefragt"
assert_contains "$secret_out" "SECRET=[geheim]" \
    "Der Wert wird nach der Wiederholung gesetzt"

# EOF (stdin geschlossen) -> Abbruch mit Exit 1.
HARNESS_STDIN="$IN_DIR/empty.txt"
HARNESS_PRINT="SECRET"
secret_out="$(run_harness 'ask_secret "Test-Geheim" SECRET')"
secret_rc=$?

assert_exit 1 "$secret_rc" "Bei EOF endet die Abfrage mit Exit 1"
assert_contains "$secret_out" "Keine Eingabe mehr verfügbar (EOF)" \
    "Der Abbruch bei EOF wird gemeldet"

# ==============================================================================
section "3. Ein umgekehrter Bereich (11-3) wird abgewiesen"
# ==============================================================================
# 3a: Software-Menue
HARNESS_STATES=1
HARNESS_STDIN="$IN_DIR/empty.txt"
before_out="$(run_harness 'select_software')"

HARNESS_STDIN="$IN_DIR/range.txt"
range_out="$(run_harness 'select_software')"

assert_contains "$range_out" "Ungültiger Bereich: 11-3" \
    "Das Software-Menue warnt vor dem umgekehrten Bereich"
assert_contains "$range_out" "der Start ist größer als das Ende" \
    "Die Warnung erklaert den Fehler"
assert_eq "$(state_block "$before_out")" "$(state_block "$range_out")" \
    "Im Software-Menue wird nichts umgeschaltet"

# 3b: modulare Modulauswahl
HARNESS_SELECTED=1
HARNESS_STDIN="$IN_DIR/range.txt"
range_out="$(run_harness 'select_modules_interactive')"

assert_contains "$range_out" "Ungültiger Bereich: 11-3" \
    "Die modulare Auswahl warnt vor dem umgekehrten Bereich"
assert_contains "$range_out" "SELECTED_COUNT 0" \
    "In der modularen Auswahl wird kein Modul gewaehlt"
assert_not_contains "$range_out" "SELECTED " \
    "In der modularen Auswahl wird kein Modul ausgefuehrt"

# Ein gueltiger Bereich schaltet dagegen sehr wohl um - sonst waere die
# Warnung der einzige Effekt der Bereichsangabe.
HARNESS_STDIN="$IN_DIR/range-ok.txt"
range_ok_out="$(run_harness 'select_modules_interactive')"

assert_not_contains "$range_ok_out" "Ungültiger Bereich" \
    "Ein gueltiger Bereich erzeugt keine Warnung"
assert_contains "$range_ok_out" "SELECTED_COUNT 2" \
    "Ein gueltiger Bereich waehlt zwei Module"

# ==============================================================================
section "4. Das Verify-Modul nennt das getestete Protokoll"
# ==============================================================================
VERIFY_MODULE="$SANDBOX_DIR/modules/99-verify.sh"

HARNESS_MODULE="$VERIFY_MODULE"
verify_out="$(run_harness \
    'echo "IMG=$VERIFY_IMAGE IPV4=$VERIFY_TEST_IPV4 IPV6=$VERIFY_TEST_IPV6 NET=$VERIFY_DOCKER_NETWORK"')"

assert_contains "$verify_out" "IMG=busybox" "VERIFY_IMAGE ist busybox"
assert_contains "$verify_out" "IPV4=8.8.8.8" "VERIFY_TEST_IPV4 ist 8.8.8.8"
assert_contains "$verify_out" "IPV6=ipv6.google.com" \
    "VERIFY_TEST_IPV6 ist ipv6.google.com"
assert_contains "$verify_out" "NET=newt_talk" \
    "VERIFY_DOCKER_NETWORK ist newt_talk"

# Erfolgreicher IPv6-Test
verify_out="$(run_harness \
    'verify_docker_ping "" "ipv6.google.com" "Default" "IPv6"')"

assert_contains "$verify_out" "IPv6-Verbindung nach außen ist erfolgreich" \
    "Der IPv6-Test meldet IPv6"
assert_not_contains "$verify_out" "IPv4-Verbindung nach außen" \
    "Der IPv6-Test meldet nicht IPv4"

# Fehlgeschlagener IPv6-Test
export FAKE_DOCKER_RUN_FAIL=1
verify_out="$(run_harness \
    'verify_docker_ping "" "ipv6.google.com" "Default" "IPv6"')"

assert_contains "$verify_out" "IPv6-Verbindung nach außen ist fehlgeschlagen" \
    "Der fehlgeschlagene IPv6-Test meldet IPv6"
assert_not_contains "$verify_out" "IPv4-Verbindung nach außen" \
    "Der fehlgeschlagene IPv6-Test meldet nicht IPv4"

# Ohne Protokoll-Argument bleibt es bei IPv4 (Vorgabe).
export FAKE_DOCKER_RUN_FAIL=0
verify_out="$(run_harness \
    'verify_docker_ping "" "$VERIFY_TEST_IPV4" "Default"')"

assert_contains "$verify_out" "IPv4-Verbindung nach außen ist erfolgreich" \
    "Ohne Protokoll-Argument wird IPv4 getestet"

# ==============================================================================
section "5. Ein fehlgeschlagener Image-Pull wird nicht als Netzwerkfehler gemeldet"
# ==============================================================================
# Das Test-Image ist nicht lokal vorhanden und der Pull schlaegt fehl.
export FAKE_DOCKER_IMAGE_PRESENT=0
export FAKE_DOCKER_PULL_FAIL=1
verify_out="$(run_harness 'verify_docker_network')"
verify_rc=$?

assert_exit 1 "$verify_rc" "Der Netzwerktest endet nach dem Pull-Fehler mit Exit 1"
assert_contains "$verify_out" "Test-Image busybox konnte nicht geladen werden" \
    "Der Pull-Fehler wird als Image-Problem gemeldet"
assert_contains "$verify_out" "NICHT beim Netzwerk" \
    "Die Meldung grenzt den Pull-Fehler vom Netzwerk ab"
assert_not_contains "$verify_out" "IPv4-Verbindung nach außen ist fehlgeschlagen" \
    "Ein Pull-Fehler wird nicht als Netzwerkfehler gemeldet"
assert_not_contains "$verify_out" "IPv4-Verbindung nach außen" \
    "Nach dem Pull-Fehler laeuft der Konnektivitaetstest nicht"

# ==============================================================================
section "6. Das Zot-Modul rollt einen defekten Mirror zurueck"
# ==============================================================================
ZOT_MODULE="$SANDBOX_DIR/modules/85-zot-mirrors.sh"
ZOT_CERTS_DIR="$SANDBOX_DIR/certs.d"
mkdir -p "$ZOT_CERTS_DIR"

# Der Pfad zeigt bewusst in die Sandbox: es wird nie nach /etc/docker
# geschrieben.
HARNESS_MODULE="$ZOT_MODULE"
export FAKE_DOCKER_PULL_FAIL=1
zot_out="$(run_harness 'module_main' \
    'ZOT_ENDPOINT=https://zot.example.invalid' \
    'ZOT_USERNAME=admin' \
    'ZOT_API_KEY=test-api-key' \
    'NON_INTERACTIVE=1' \
    "ZOT_CERTS_DIR=$ZOT_CERTS_DIR" \
    "ZOT_DAEMON_JSON=$SANDBOX_DIR/daemon.json")"
zot_rc=$?

assert_exit 2 "$zot_rc" "Ein fehlgeschlagener Test-Pull endet mit Exit 2"
assert_contains "$zot_out" "Test-Pull fehlgeschlagen" \
    "Der fehlgeschlagene Test-Pull wird gemeldet"
assert_contains "$zot_out" "Sync-Job" "Der Sync-Job wird als Ursache genannt"
assert_contains "$zot_out" "API-Key" "Der API-Key wird als Ursache genannt"
assert_contains "$zot_out" "Pfad-Prefix" "Der Pfad-Prefix wird als Ursache genannt"
assert_contains "$zot_out" "Mirror-Konfiguration wird zurueckgerollt" \
    "Das Zurueckrollen wird angekuendigt"

zot_files="$(find "$ZOT_CERTS_DIR" -name 'hosts.toml' -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$zot_files" \
    "Die hosts.toml-Dateien sind nach dem Fehlschlag entfernt"

# ==============================================================================
section "7. Ein erfolgreicher Test-Pull laesst die Mirror-Dateien stehen"
# ==============================================================================
rm -rf "$ZOT_CERTS_DIR"
mkdir -p "$ZOT_CERTS_DIR"

export FAKE_DOCKER_PULL_FAIL=0
zot_out="$(run_harness 'module_main' \
    'ZOT_ENDPOINT=https://zot.example.invalid' \
    'ZOT_USERNAME=admin' \
    'ZOT_API_KEY=test-api-key' \
    'NON_INTERACTIVE=1' \
    "ZOT_CERTS_DIR=$ZOT_CERTS_DIR" \
    "ZOT_DAEMON_JSON=$SANDBOX_DIR/daemon.json")"
zot_rc=$?

assert_exit 0 "$zot_rc" "Ein erfolgreicher Test-Pull endet mit Exit 0"
assert_contains "$zot_out" "Mirror funktioniert" \
    "Der erfolgreiche Test-Pull wird bestaetigt"

zot_files="$(find "$ZOT_CERTS_DIR" -name 'hosts.toml' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$zot_files" -ge 1 ]; then
    pass "Die hosts.toml-Dateien bleiben liegen ($zot_files Dateien)"
else
    fail "Die hosts.toml-Dateien wurden entfernt" "gefunden: $zot_files Dateien"
fi

# ==============================================================================
section "8. NETBIRD_CONFIGURE: leer verbindet, 'false' ueberspringt"
# ==============================================================================
NETBIRD_MODULE="$SANDBOX_DIR/modules/86-netbird.sh"

# Der Default aus lib/config.sh ist leer (kein "false").
default_out="$(bash -c '
    . "$1/lib/core.sh"
    . "$1/lib/config.sh"
    config_set_defaults
    echo "NETBIRD_CONFIGURE=[$NETBIRD_CONFIGURE]"
' _ "$SANDBOX_DIR" 2>/dev/null)"

assert_contains "$default_out" "NETBIRD_CONFIGURE=[]" \
    "NETBIRD_CONFIGURE ist per Default leer"

# Leerer Wert im interaktiven Lauf -> das Modul fragt nach den Zugangsdaten.
HARNESS_MODULE="$NETBIRD_MODULE"
HARNESS_STDIN="$IN_DIR/netbird.txt"
netbird_out="$(run_harness 'netbird_configure' \
    'NETBIRD_CONFIGURE=' \
    'NON_INTERACTIVE=0')"
netbird_rc=$?

assert_exit 0 "$netbird_rc" "Die Verbindung endet mit Exit 0"
assert_contains "$netbird_out" "NetBird Management-URL" \
    "Es wird nach der Management-URL gefragt"
assert_contains "$netbird_out" "NetBird Setup-Key" \
    "Es wird nach dem Setup-Key gefragt"
assert_contains "$netbird_out" "Verbinde mit NetBird" \
    "Das Modul verbindet sich mit dem Management-Server"

# Explizites "false" -> die Verbindung wird ohne Nachfrage uebersprungen.
netbird_out="$(run_harness 'netbird_configure' \
    'NETBIRD_CONFIGURE=false' \
    'NON_INTERACTIVE=0')"
netbird_rc=$?

assert_exit 1 "$netbird_rc" "Der uebersprungene Lauf endet mit Exit 1"
assert_contains "$netbird_out" "NetBird-Konfiguration übersprungen" \
    "Das Modul ueberspringt die Verbindung"
assert_not_contains "$netbird_out" "NetBird Management-URL" \
    "Ohne Verbindung wird nicht nach der Management-URL gefragt"
assert_not_contains "$netbird_out" "NetBird Setup-Key" \
    "Ohne Verbindung wird nicht nach dem Setup-Key gefragt"

# ==============================================================================
section "9. Das Docker-Port-Audit laeuft nach dem Docker-Modul"
# ==============================================================================
order_out="$(bash -c '
    . "$1/lib/core.sh"
    . "$1/lib/config.sh"
    . "$1/lib/modules.sh"
    MODULES_DIR="$1/modules"
    discover_modules
    for entry in "${AVAILABLE_MODULES[@]}"; do
        printf "%s\n" "$entry" | cut -d"|" -f2
    done
' _ "$SANDBOX_DIR" 2>/dev/null)"

docker_pos="$(printf '%s\n' "$order_out" | grep -n '^docker$' | cut -d: -f1)"
firewall_pos="$(printf '%s\n' "$order_out" | grep -n '^docker-firewall$' | cut -d: -f1)"

if [ -n "$docker_pos" ] && [ -n "$firewall_pos" ]; then
    pass "Beide Module sind in der Ausfuehrungsreihenfolge gelistet"
else
    fail "docker oder docker-firewall fehlt in der Modulliste" \
        "gefunden: $order_out"
fi

if [ -n "$docker_pos" ] && [ -n "$firewall_pos" ] && [ "$docker_pos" -lt "$firewall_pos" ]; then
    pass "docker (Position $docker_pos) laeuft vor docker-firewall (Position $firewall_pos)"
else
    fail "docker-firewall laeuft vor docker" \
        "docker: $docker_pos, docker-firewall: $firewall_pos"
fi

test_summary
