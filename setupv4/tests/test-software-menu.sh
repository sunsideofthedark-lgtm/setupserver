#!/bin/bash
# ==============================================================================
# setupv4/tests/test-software-menu.sh - Software-Auswahl im Setup
# ==============================================================================
# Prueft das Auswahlmenue fuer die installierbare Software:
#
#   * das Menue erscheint im Ablauf "Komplettes Setup" und listet alle 15
#     Software-Pakete mit [x]/[ ]-Markierung
#   * Voreinstellung: Docker ist angehakt, alle anderen Pakete sind aus
#   * "keine" schaltet alles ab, "alle" schaltet alles an
#   * eine einzelne Nummer schaltet genau dieses Paket um
#   * Enter ohne Eingabe laesst die Auswahl unveraendert
#   * ohne geladene Config-Datei wird nichts gespeichert (Hinweis auf --init)
#   * mit geladener Config-Datei wird die Auswahl nach Rueckfrage in die
#     Datei geschrieben - vorhandene Zeile wird ersetzt, keine Dublette,
#     und die Originaldatei liegt als Sicherung (.bak) vor
#
# Das Menue braucht ein echtes Terminal: setup.sh bricht ohne TTY mit
# "kein Terminal fuer die interaktive Auswahl" ab, ein FIFO reicht nicht.
# Die Laeufe laufen deshalb unter einem Pseudo-Terminal, das "script"
# (util-linux) alloziert.
#
# Das Wirtssystem wird nicht veraendert: die vollstaendigen Laeufe gehen
# ueber --dry-run, SETUP_HOME und BACKUP_DIR liegen in der Sandbox, und
# Paketmanager, Dienstverwalter und Netzwerkwerkzeuge sind gestubbt.
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Ein sauberer Linux-PATH: unter WSL haengen sonst die Windows-Verzeichnisse an
# PATH - dort liegen Programme mit anderen Namen und Optionen (find, sort ...),
# die den Testlauf unberechenbar machen wuerden.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

# --- Voraussetzung: Pseudo-Terminal ------------------------------------------
if ! command -v script >/dev/null 2>&1; then
    echo "FEHLER: 'script' (util-linux) wird fuer den PTY-Test benoetigt." >&2
    exit 1
fi

FAKE_BIN="$SANDBOX_DIR/fakebin"
SANDBOX_BACKUPS="$SANDBOX_DIR/backups"
mkdir -p "$FAKE_BIN" "$SANDBOX_BACKUPS" "$SANDBOX_DIR/logs"

# Fake-Binaries: Paketmanager, Dienstverwalter und Netzwerkwerkzeuge werden
# gestubbt - so greift im Test kein echter Befehl ins System oder ins Netz.
for tool in curl wget systemctl service docker apt apt-get dpkg yum dnf apk \
            useradd usermod groupadd deluser passwd chpasswd visudo ufw \
            iptables ip6tables chattr zfs npm node pip pip3 \
            fail2ban-client crowdsec cscli clamscan freshclam netbird \
            nginx git ssh-keygen timedatectl update-alternatives crontab; do
    cat > "$FAKE_BIN/$tool" << 'STUB'
#!/bin/bash
# Stub: meldet Erfolg und liefert bei -w einen HTTP-Status.
case " $* " in
    *" -w "*|*" --write-out "*) echo 200 ;;
esac
exit 0
STUB
    chmod +x "$FAKE_BIN/$tool"
done

# --- PTY-Hilfen --------------------------------------------------------------
PTY_OUTPUT=""
PTY_EXIT=0
PTY_FIFO_COUNT=0

# Fuehrt ein Kommando unter einem Pseudo-Terminal aus und legt die bereinigte
# Ausgabe in $PTY_OUTPUT ab. $1 ist die Eingabe (Zeilen durch \n getrennt),
# der Rest ist das Kommando.
run_pty() {
    local input="$1"
    shift
    local fifo

    PTY_FIFO_COUNT=$((PTY_FIFO_COUNT + 1))
    fifo="$SANDBOX_DIR/pty-$PTY_FIFO_COUNT.fifo"
    rm -f "$fifo"
    mkfifo "$fifo" || return 1

    ( printf '%s' "$input" > "$fifo" & ) 2>/dev/null
    # Der PATH wird als Environment gesetzt und nicht in das Kommando
    # geschrieben - sonst zerlegt die Shell des Pseudo-Terminals einen Pfad
    # mit Leerzeichen (unter WSL der Windows-PATH) in mehrere Woerter.
    PTY_OUTPUT=$(PATH="$FAKE_BIN:$PATH" timeout "$PTY_TIMEOUT" script -qec "$*" /dev/null < "$fifo" 2>&1)
    PTY_EXIT=$?
    rm -f "$fifo"

    # ANSI-Sequenzen und Wagenrueckschrieb entfernen
    PTY_OUTPUT=$(printf '%s\n' "$PTY_OUTPUT" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g')
    return 0
}

# Liefert die Checklisten-Zeile zur angegebenen Nummer aus der Ausgabe.
menu_line() {
    printf '%s\n' "$1" | grep -E "^[[:space:]]*$2\) \[" | head -n1
}

# Prueft, dass ein Software-Paket in der Checkliste mit der erwarteten
# Markierung und ID auftaucht.
assert_menu_package() {
    local output="$1" number="$2" mark="$3" name="$4" id="$5"
    local line

    line="$(menu_line "$output" "$number")"
    if [ -z "$line" ]; then
        fail "Paket $number ($name) fehlt in der Checkliste"
        return
    fi
    if printf '%s' "$line" | grep -qF "[$mark] $name" && printf '%s' "$line" | grep -qF "$id"; then
        pass "Paket $number ($name) ist mit [$mark] markiert (ID $id)"
    else
        fail "Paket $number ($name) ist nicht wie erwartet markiert" \
            "erwartet: [$mark] $name / $id | gefunden: $line"
    fi
}

# Prueft einen Software-Schalter im Zustandsausdruck des Harness.
assert_state() {
    local output="$1" key="$2" expected="$3"
    local line

    line="$(printf '%s\n' "$output" | grep -E "^STATE ${key}=" | head -n1)"
    if [ "$line" = "STATE ${key}=${expected}" ]; then
        pass "$key ist $expected"
    else
        fail "$key ist nicht $expected" \
            "erwartet: STATE ${key}=${expected} | erhalten: ${line:-<fehlt>}"
    fi
}

# Die 15 Software-Pakete in Ausfuehrungsreihenfolge: Nummer|Name|ID
SOFTWARE_PACKAGES=(
    "1|Docker|docker"
    "2|ZFS ARC-Cache|zfs-arc"
    "3|Node.js|nodejs"
    "4|Zot-Registry-Mirrors|zot-mirrors"
    "5|NetBird|netbird"
    "6|Fail2Ban|fail2ban"
    "7|CrowdSec|crowdsec"
    "8|NGINX Webserver|nginx"
    "9|Prometheus Node Exporter|node-exporter"
    "10|Monitoring- und Alltagswerkzeuge|monitoring-tools"
    "11|Komodo Periphery Agent|komodo"
    "12|Pangolin SPK Provisioning|pangolin"
    "13|Git SSH-Keys|git-ssh"
    "14|ClamAV Antivirus|clamav"
    "15|Omnisight Agent|omnisight"
)

# --- Isoliertes Harness ------------------------------------------------------
# Fuehrt nur die Software-Auswahl aus - ohne den kompletten Setup-Lauf.
# Aufruf: harness.sh <setup-dir> [config-datei]
cat > "$SANDBOX_DIR/harness.sh" << 'HARNESS'
#!/bin/bash
# Isoliertes Harness fuer die Software-Auswahl (siehe test-software-menu.sh).
SETUP_DIR="$1"
export SETUP_DIR
export LOGFILE="${LOGFILE:-/tmp/setupv4-software-menu.log}"

# shellcheck disable=SC1090
. "$SETUP_DIR/lib/core.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/os.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/config.sh"
# shellcheck disable=SC1090
. "$SETUP_DIR/lib/modules.sh"

MODULES_DIR="$SETUP_DIR/modules"

config_set_defaults

if [ -n "${2:-}" ]; then
    config_load "$2" || exit 1
fi

discover_modules

select_software
config_save_software_selection

# Endzustand aller Software-Schalter ausgeben - so kann der Test sie pruefen.
echo "=== SCHALTER ==="
for sw in INSTALL_DOCKER INSTALL_NODEJS INSTALL_NGINX INSTALL_FAIL2BAN \
          INSTALL_CROWDSEC INSTALL_NETBIRD INSTALL_KOMODO INSTALL_PANGOLIN \
          INSTALL_GIT_SSH INSTALL_CLAMAV INSTALL_OMNISIGHT INSTALL_ZFS_ARC \
          INSTALL_NODE_EXPORTER ZOT_MIRRORS INSTALL_HTOP INSTALL_IOTOP \
          INSTALL_NETHOGS INSTALL_NCUDU INSTALL_TMUX INSTALL_DB_CLIENTS \
          INSTALL_GIT INSTALL_ZIP; do
    printf 'STATE %s=%s\n' "$sw" "${!sw:-leer}"
done
HARNESS

# Aufruf des Harness unter einem PTY. $1 = Eingabe, $2 = Config-Datei
# (leer = keine Config), $3 = Backup-Verzeichnis (leer = Standard).
run_harness() {
    local input="$1" config_file="${2:-}" backup_dir="${3:-$SANDBOX_BACKUPS}"

    run_pty "$input" \
        "SETUP_HOME=$SANDBOX_HOME BACKUP_DIR=$backup_dir LOGFILE=$SANDBOX_DIR/logs/harness.log \
         bash $SANDBOX_DIR/harness.sh $SANDBOX_DIR $config_file"
}

# ==============================================================================
section "1. Das Menue erscheint im Ablauf 'Komplettes Setup'"
# ==============================================================================
# "1" = Komplettes Setup, "keine" = alles abwaehlen. Der Lauf endet nach dem
# Modulplan; die Module danach sind fuer diesen Test uninteressant - der
# Timeout schneidet sie deshalb ab.
PTY_TIMEOUT=20
run_pty $'1\nkeine\n' \
    "cd $SANDBOX_DIR && SETUP_HOME=$SANDBOX_HOME BACKUP_DIR=$SANDBOX_DIR/backups-e2e \
     bash ./setup.sh --dry-run --no-relocate --no-profile"

assert_contains "$PTY_OUTPUT" "Software-Auswahl" "Das Software-Menue wird gezeigt"
assert_contains "$PTY_OUTPUT" "Welche Software soll eingerichtet werden?" \
    "Das Menue fragt nach der Software"

# Alle 15 Pakete stehen in der Checkliste. Docker ist vorangehakt, alle
# anderen sind aus - das ist die Voreinstellung aus der Konfiguration.
entry=""
for entry in "${SOFTWARE_PACKAGES[@]}"; do
    number="${entry%%|*}"
    rest="${entry#*|}"
    name="${rest%%|*}"
    id="${rest##*|}"
    if [ "$number" = "1" ]; then
        assert_menu_package "$PTY_OUTPUT" "$number" "x" "$name" "$id"
    else
        assert_menu_package "$PTY_OUTPUT" "$number" " " "$name" "$id"
    fi
done

# Nach "keine" ist im Auswahl-Ueberblick alles abgewahlt.
assert_contains "$PTY_OUTPUT" "  Auswahl:" "Die Auswahl wird zusammengefasst"
assert_contains "$PTY_OUTPUT" "   [ ] Docker" "Docker ist nach 'keine' abgewahlt"
assert_not_contains "$PTY_OUTPUT" "   [x] Docker" "Docker ist nach 'keine' nicht mehr angehakt"

# Nicht ausgewaehlte Software-Module stehen im Modulplan als uebersprungen.
assert_contains "$PTY_OUTPUT" "docker - Docker  (nicht ausgewählt - wird übersprungen)" \
    "Nicht ausgewaehlte Software wird im Modulplan als uebersprungen markiert"

# ==============================================================================
section "2. Voreinstellung: Docker angehakt, alle anderen aus"
# ==============================================================================
PTY_TIMEOUT=15
run_harness $'\n'

assert_contains "$PTY_OUTPUT" "  Auswahl unveraendert." \
    "Enter ohne Eingabe laesst die Auswahl unveraendert"
assert_state "$PTY_OUTPUT" "INSTALL_DOCKER" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NODEJS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NGINX" "false"
assert_state "$PTY_OUTPUT" "INSTALL_FAIL2BAN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CROWDSEC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NETBIRD" "false"
assert_state "$PTY_OUTPUT" "INSTALL_KOMODO" "false"
assert_state "$PTY_OUTPUT" "INSTALL_PANGOLIN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_GIT_SSH" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CLAMAV" "false"
assert_state "$PTY_OUTPUT" "INSTALL_OMNISIGHT" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZFS_ARC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NODE_EXPORTER" "false"
assert_state "$PTY_OUTPUT" "ZOT_MIRRORS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_HTOP" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZIP" "false"

# ==============================================================================
section "3. 'keine' schaltet alles ab"
# ==============================================================================
run_harness $'keine\n'

assert_state "$PTY_OUTPUT" "INSTALL_DOCKER" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NODEJS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NGINX" "false"
assert_state "$PTY_OUTPUT" "INSTALL_FAIL2BAN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CROWDSEC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NETBIRD" "false"
assert_state "$PTY_OUTPUT" "INSTALL_KOMODO" "false"
assert_state "$PTY_OUTPUT" "INSTALL_PANGOLIN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_GIT_SSH" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CLAMAV" "false"
assert_state "$PTY_OUTPUT" "INSTALL_OMNISIGHT" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZFS_ARC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NODE_EXPORTER" "false"
assert_state "$PTY_OUTPUT" "ZOT_MIRRORS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_HTOP" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZIP" "false"

# ==============================================================================
section "4. 'alle' schaltet alles an"
# ==============================================================================
run_harness $'alle\n'

assert_state "$PTY_OUTPUT" "INSTALL_DOCKER" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NODEJS" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NGINX" "true"
assert_state "$PTY_OUTPUT" "INSTALL_FAIL2BAN" "true"
assert_state "$PTY_OUTPUT" "INSTALL_CROWDSEC" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NETBIRD" "true"
assert_state "$PTY_OUTPUT" "INSTALL_KOMODO" "true"
assert_state "$PTY_OUTPUT" "INSTALL_PANGOLIN" "true"
assert_state "$PTY_OUTPUT" "INSTALL_GIT_SSH" "true"
assert_state "$PTY_OUTPUT" "INSTALL_CLAMAV" "true"
assert_state "$PTY_OUTPUT" "INSTALL_OMNISIGHT" "true"
assert_state "$PTY_OUTPUT" "INSTALL_ZFS_ARC" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NODE_EXPORTER" "true"
assert_state "$PTY_OUTPUT" "ZOT_MIRRORS" "true"
# Die Werkzeuggruppe besteht aus acht Schaltern - alle werden gesetzt.
assert_state "$PTY_OUTPUT" "INSTALL_HTOP" "true"
assert_state "$PTY_OUTPUT" "INSTALL_IOTOP" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NETHOGS" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NCUDU" "true"
assert_state "$PTY_OUTPUT" "INSTALL_TMUX" "true"
assert_state "$PTY_OUTPUT" "INSTALL_DB_CLIENTS" "true"
assert_state "$PTY_OUTPUT" "INSTALL_GIT" "true"
assert_state "$PTY_OUTPUT" "INSTALL_ZIP" "true"

# ==============================================================================
section "5. Eine einzelne Nummer schaltet genau ein Paket um"
# ==============================================================================
# Nummer 3 ist Node.js (siehe SOFTWARE_PACKAGES).
run_harness $'3\n'

assert_state "$PTY_OUTPUT" "INSTALL_NODEJS" "true"
assert_state "$PTY_OUTPUT" "INSTALL_DOCKER" "true"
assert_state "$PTY_OUTPUT" "INSTALL_NGINX" "false"
assert_state "$PTY_OUTPUT" "INSTALL_FAIL2BAN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CROWDSEC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NETBIRD" "false"
assert_state "$PTY_OUTPUT" "INSTALL_KOMODO" "false"
assert_state "$PTY_OUTPUT" "INSTALL_PANGOLIN" "false"
assert_state "$PTY_OUTPUT" "INSTALL_GIT_SSH" "false"
assert_state "$PTY_OUTPUT" "INSTALL_CLAMAV" "false"
assert_state "$PTY_OUTPUT" "INSTALL_OMNISIGHT" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZFS_ARC" "false"
assert_state "$PTY_OUTPUT" "INSTALL_NODE_EXPORTER" "false"
assert_state "$PTY_OUTPUT" "ZOT_MIRRORS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_HTOP" "false"
assert_state "$PTY_OUTPUT" "INSTALL_ZIP" "false"

# Die Nummer schaltet um: zweimal dieselbe Nummer hebt die Aenderung wieder auf.
run_harness $'3,3\n'
assert_state "$PTY_OUTPUT" "INSTALL_NODEJS" "false"
assert_state "$PTY_OUTPUT" "INSTALL_DOCKER" "true"

# ==============================================================================
section "6. Ohne Config-Datei wird nichts gespeichert"
# ==============================================================================
# Eigenes Backup-Verzeichnis: nur so laesst sich eindeutig belegen, dass
# das Setup ohne Config-Datei keine Sicherung der Auswahl anlegt.
mkdir -p "$SANDBOX_DIR/backups-noconfig"
run_harness $'keine\n' "" "$SANDBOX_DIR/backups-noconfig"

assert_contains "$PTY_OUTPUT" "Keine Konfigurationsdatei geladen" \
    "Ohne Config-Datei wird nichts gespeichert"
assert_contains "$PTY_OUTPUT" "--init" \
    "Ohne Config-Datei wird auf --init verwiesen"
assert_eq "0" "$(find "$SANDBOX_DIR/backups-noconfig" -name '*.bak' 2>/dev/null | wc -l | tr -d ' ')" \
    "Ohne Config-Datei entsteht keine Sicherung"

# ==============================================================================
section "7. Mit Config-Datei wird die Auswahl in die Datei geschrieben"
# ==============================================================================
cat > "$SANDBOX_DIR/software.conf" << 'EOF'
# Testkonfiguration fuer die Software-Auswahl
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SSH_PORT=2222
INSTALL_NODEJS=false
EOF

# "3" = Node.js einschalten, "y" = Auswahl in die Datei speichern.
mkdir -p "$SANDBOX_DIR/backups-config"
run_harness $'3\ny\n' "$SANDBOX_DIR/software.conf" "$SANDBOX_DIR/backups-config"

assert_contains "$PTY_OUTPUT" "Auswahl in $SANDBOX_DIR/software.conf speichern?" \
    "Nach der Auswahl wird nach dem Speichern gefragt"
assert_contains "$PTY_OUTPUT" "Software-Auswahl in $SANDBOX_DIR/software.conf gespeichert." \
    "Das Speichern wird bestaetigt"

# Die vorhandene Zeile wird ersetzt - keine Dublette am Dateiende.
nodejs_lines="$(grep -c '^INSTALL_NODEJS=' "$SANDBOX_DIR/software.conf")"
assert_eq "1" "$nodejs_lines" "INSTALL_NODEJS steht genau einmal in der Datei"
assert_contains "$(cat "$SANDBOX_DIR/software.conf")" "INSTALL_NODEJS=true" \
    "INSTALL_NODEJS wurde auf true gesetzt"
assert_not_contains "$(cat "$SANDBOX_DIR/software.conf")" "INSTALL_NODEJS=false" \
    "Die alte Zeile INSTALL_NODEJS=false ist ersetzt"

# Die Originaldatei liegt als Sicherung vor.
bak_file="$(find "$SANDBOX_DIR/backups-config" -name '*software.conf*.bak' 2>/dev/null | head -n1)"
if [ -n "$bak_file" ]; then
    pass "Die Originaldatei wurde als .bak gesichert"
else
    fail "Es liegt keine .bak-Sicherung der Originaldatei vor" \
        "erwartet: eine Datei '*software.conf*.bak' in $SANDBOX_DIR/backups-config"
fi
if [ -n "$bak_file" ] && grep -q "INSTALL_NODEJS=false" "$bak_file"; then
    pass "Die Sicherung enthaelt den urspruenglichen Stand (INSTALL_NODEJS=false)"
else
    fail "Die Sicherung enthaelt nicht den urspruenglichen Stand" "Sicherung: ${bak_file:-<fehlt>}"
fi

# ==============================================================================
section "8. Der komplette Setup-Lauf schreibt die Auswahl in die Config"
# ==============================================================================
# Gleicher Weg wie im echten Ablauf: setup.sh laedt die Config, zeigt das
# Menue und schreibt die Auswahl zurueck.
cat > "$SANDBOX_DIR/software-run.conf" << 'EOF'
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SSH_PORT=2222
INSTALL_NODEJS=false
EOF

PTY_TIMEOUT=20
run_pty $'1\n3\ny\n' \
    "cd $SANDBOX_DIR && SETUP_HOME=$SANDBOX_HOME BACKUP_DIR=$SANDBOX_DIR/backups-e2e-config \
     bash ./setup.sh --dry-run --no-relocate --no-profile \
     --config $SANDBOX_DIR/software-run.conf"

assert_contains "$PTY_OUTPUT" "Software-Auswahl" "Das Menue erscheint auch mit Config"
assert_contains "$PTY_OUTPUT" "Auswahl in $SANDBOX_DIR/software-run.conf speichern?" \
    "Das Setup fragt nach dem Speichern der Auswahl"
assert_contains "$PTY_OUTPUT" "Software-Auswahl in $SANDBOX_DIR/software-run.conf gespeichert." \
    "Das Setup bestaetigt das Speichern"

run_lines="$(grep -c '^INSTALL_NODEJS=' "$SANDBOX_DIR/software-run.conf")"
assert_eq "1" "$run_lines" "INSTALL_NODEJS steht nach dem Lauf genau einmal in der Datei"
assert_contains "$(cat "$SANDBOX_DIR/software-run.conf")" "INSTALL_NODEJS=true" \
    "Die Auswahl steht als INSTALL_NODEJS=true in der Datei"
assert_not_contains "$(cat "$SANDBOX_DIR/software-run.conf")" "INSTALL_NODEJS=false" \
    "Kein alter Stand INSTALL_NODEJS=false in der Datei"

# Auch im echten Lauf liegt die Originaldatei als Sicherung vor.
run_bak="$(find "$SANDBOX_DIR/backups-e2e-config" -name '*software-run.conf*.bak' 2>/dev/null | head -n1)"
if [ -n "$run_bak" ] && grep -q "INSTALL_NODEJS=false" "$run_bak"; then
    pass "Im Setup-Lauf wurde die Originaldatei als .bak gesichert"
else
    fail "Im Setup-Lauf fehlt die .bak-Sicherung der Originaldatei" \
        "erwartet: eine Datei '*software-run.conf*.bak' mit INSTALL_NODEJS=false"
fi

test_summary
