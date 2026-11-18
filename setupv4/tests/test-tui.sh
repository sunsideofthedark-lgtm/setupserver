#!/bin/bash
# ==============================================================================
# setupv4/tests/test-tui.sh - Terminal-Oberflaeche (TUI) des Setup
# ==============================================================================
# Prueft die Vollbild-Oberflaeche aus lib/tui.sh:
#
#   * die Checkliste der Software erscheint, wenn ein Terminal vorhanden ist
#   * die Leertaste schaltet ein Paket um (Docker ist vorangehakt)
#   * Enter bestaetigt die Auswahl und startet das Setup als Kindprozess -
#     das Dashboard und am Ende die Ergebniskarte erscheinen
#   * "q" bricht ab, ohne dass ein Setup ausgefuehrt wird
#   * ohne Terminal (Pipe statt TTY) laeuft der klassische Textpfad
#   * --no-tui erzwingt den Textpfad auch mit Terminal
#   * das Wirtssystem bleibt unangetastet: alle Laeufe sind Trockenlaeufe
#     mit eigenem SETUP_HOME und BACKUP_DIR in der Sandbox
#
# Die Oberflaeche braucht ein echtes Terminal: ohne TTY laeuft der
# klassische Textpfad. Die Laeufe finden deshalb unter einem
# Pseudo-Terminal statt, das "script" (util-linux) alloziert - das Muster
# stammt aus test-software-menu.sh.
#
# Zwei Feinheiten des Pseudo-Terminals:
#   * TERM muss gesetzt sein - sonst erkennt tui_available() kein Terminal.
#   * Die Fenstergroesse muss passen: ohne "stty" meldet tput 0 Zeilen,
#     und die Oberflaeche zeichnet dann nur einen Teil der Pakete.
#     "stty rows 40 cols 120" zeigt alle 15.
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

# Ohne TERM gilt fuer tui_available() "kein Terminal".
export TERM="xterm-256color"

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

# Zustand der systemweiten Zielverzeichnisse vor dem Test. Existieren sie
# schon, kann der Test nur pruefen, dass sie unveraendert bleiben - dann
# wird ihr Inhalt als Vergleichsbild gesichert. Existieren sie nicht,
# prueft der Test, dass sie nicht entstehen.
SYS_SETUP_HOME_EXISTED=0
[ -d /opt/serversetup ] && SYS_SETUP_HOME_EXISTED=1
SYS_BACKUP_EXISTED=0
[ -d /var/backups/serversetup ] && SYS_BACKUP_EXISTED=1

SYS_SETUP_LOG_STAMP="-"
if [ "$SYS_SETUP_HOME_EXISTED" = "1" ] && [ -f /opt/serversetup/logs/setup.log ]; then
    SYS_SETUP_LOG_STAMP="$(wc -c < /opt/serversetup/logs/setup.log | tr -d ' ')"
fi

SYS_BACKUP_COUNT="-"
if [ "$SYS_BACKUP_EXISTED" = "1" ]; then
    SYS_BACKUP_COUNT="$(find /var/backups/serversetup -type f 2>/dev/null | wc -l | tr -d ' ')"
fi

# --- Auswertungs-Hilfen ------------------------------------------------------

# Die Oberflaeche schreibt ihre Farben als literalen Text ("\033[0m"), weil
# printf '%s' keine Escapesequenzen auswertet. Beide Formen - die echten
# ANSI-Sequenzen und der literale Text - werden hier entfernt, damit die
# Ausgabe lesbar bleibt und die Zeilen am Stueck bleiben.
clean_output() {
    printf '%s\n' "$1" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\\033\[[0-9;]*m//g' -e 's/\r//g'
}

# Die Oberflaeche nutzt auf einer UTF-8-Konsole andere Zeichen als auf einer
# Nicht-UTF-8-Konsole - der Test rechnet das nach.
TUI_MARK_OK="✓"
case "$(locale charmap 2>/dev/null)" in
    UTF-8|utf8|utf-8) ;;
    *) TUI_MARK_OK="+" ;;
esac

# Liefert alle Checklisten-Zeilen eines Pakets (Nummer und Name). Die
# Oberflaeche zeichnet die Liste nach jedem Tastendruck neu - deshalb
# kommen mehrere Zeilen zurueck.
checklist_entries() {
    printf '%s\n' "$1" | grep -oE "[^0-9]$2\) \[[^]]*\] $3" || true
}

# Zaehlt die verschiedenen Pakete in der Checkliste.
checklist_count() {
    printf '%s\n' "$1" \
        | grep -oE "[0-9]+\) \[" \
        | sed -E 's/\) \[//' \
        | sort -un \
        | wc -l \
        | tr -d ' '
}

# --- PTY-Hilfen --------------------------------------------------------------
PTY_OUTPUT=""
PTY_EXIT=0
PTY_FIFO_COUNT=0
NO_PTY_OUTPUT=""
NO_PTY_EXIT=0
PTY_TIMEOUT=30

# Fuehrt ein Kommando unter einem Pseudo-Terminal aus und legt die bereinigte
# Ausgabe in $PTY_OUTPUT ab. $1 ist die Eingabe (Tasten fuer die Oberflaeche),
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
    PTY_OUTPUT=$(PATH="$FAKE_BIN:$PATH" SETUP_HOME="$SANDBOX_HOME" \
        BACKUP_DIR="$SANDBOX_BACKUPS" TERM="$TERM" \
        timeout "$PTY_TIMEOUT" script -qec "$*" /dev/null < "$fifo" 2>&1)
    PTY_EXIT=$?
    rm -f "$fifo"

    PTY_OUTPUT="$(clean_output "$PTY_OUTPUT")"
    return 0
}

# Fuehrt ein Kommando OHNE Terminal aus: stdin und stdout sind Pipes, damit
# die Oberflaeche gar nicht erst starten kann.
run_nopty() {
    NO_PTY_OUTPUT=$(cd "$SANDBOX_DIR" && PATH="$FAKE_BIN:$PATH" \
        SETUP_HOME="$SANDBOX_HOME" BACKUP_DIR="$SANDBOX_BACKUPS" TERM="$TERM" \
        bash -c "$*" 2>&1)
    NO_PTY_EXIT=$?
    NO_PTY_OUTPUT="$(clean_output "$NO_PTY_OUTPUT")"
    return 0
}

# ==============================================================================
section "1. Die Oberflaeche startet, wenn ein Terminal vorhanden ist"
# ==============================================================================
# "q" beendet die Checkliste wieder - der Lauf soll ja nur den Aufbau
# zeigen. Ohne Eingabe wuerde die Oberflaeche endlos neu zeichnen.
run_pty "q" "cd $SANDBOX_DIR && stty rows 40 cols 120; bash ./setup.sh --dry-run --no-profile"

assert_contains "$PTY_OUTPUT" "setupv4 · Software-Auswahl" \
    "Der Vollbild-Rahmen zeigt die Software-Auswahl"
assert_contains "$PTY_OUTPUT" "Software-Auswahl" \
    "Die Software-Auswahl wird genannt"
assert_contains "$PTY_OUTPUT" "Welche Software soll eingerichtet werden?" \
    "Die Oberflaeche fragt nach der Software"

# Die Pakete stehen in der Checkliste - mit Nummer und Markierung.
assert_contains "$(checklist_entries "$PTY_OUTPUT" 1 "Docker" | head -n1)" \
    "[$TUI_MARK_OK] Docker" "Docker steht als erstes Paket in der Checkliste"
assert_contains "$(checklist_entries "$PTY_OUTPUT" 3 "Node.js" | head -n1)" \
    "Node.js" "Node.js steht in der Checkliste"
assert_contains "$(checklist_entries "$PTY_OUTPUT" 14 "ClamAV" | head -n1)" \
    "ClamAV" "ClamAV steht in der Checkliste"

# Alle 15 Pakete sind sichtbar - das Fenster ist gross genug.
assert_eq "15" "$(checklist_count "$PTY_OUTPUT")" \
    "Die Checkliste zeigt alle 15 Pakete"

# Die Statuszeile nennt, wie viele Pakete ausgewaehlt sind.
assert_contains "$PTY_OUTPUT" "von 15 Paketen ausgewählt" \
    "Die Statuszeile nennt die Anzahl der Pakete"

# ==============================================================================
section "2. Die Leertaste schaltet ein Paket um"
# ==============================================================================
# Eingabe: Leertaste (schaltet Docker ab) und danach "q" (Abbruch).
run_pty " q" "cd $SANDBOX_DIR && stty rows 40 cols 120; bash ./setup.sh --dry-run --no-profile"

erster_docker="$(checklist_entries "$PTY_OUTPUT" 1 "Docker" | head -n1)"
letzter_docker="$(checklist_entries "$PTY_OUTPUT" 1 "Docker" | tail -n1)"

assert_contains "$erster_docker" "[$TUI_MARK_OK] Docker" \
    "Docker ist vor dem Tastendruck angehakt"
assert_contains "$letzter_docker" "[ ] Docker" \
    "Docker ist nach der Leertaste abgewahlt"

# Die Statuszeile zaehlt die Auswahl mit.
assert_contains "$PTY_OUTPUT" "1 von 15 Paketen ausgewählt" \
    "Vor der Leertaste ist ein Paket ausgewaehlt"
assert_contains "$PTY_OUTPUT" "0 von 15 Paketen ausgewählt" \
    "Nach der Leertaste ist kein Paket ausgewaehlt"

# ==============================================================================
section "3. Enter bestaetigt - das Setup laeuft als Kindprozess"
# ==============================================================================
# --non-interactive: das Kind liest seine Rueckfragen vom Terminal. Ohne
# Eingabe wuerde es dort blockieren, bis der Test abbricht. So antwortet es
# mit den Vorgaben und der Lauf endet von selbst.
PTY_TIMEOUT=180
run_pty $'\n' \
    "cd $SANDBOX_DIR && stty rows 40 cols 120; bash ./setup.sh --dry-run --no-profile --non-interactive"

assert_contains "$PTY_OUTPUT" "setupv4 · Ausführung" \
    "Das Dashboard der Ausfuehrung erscheint"
assert_contains "$PTY_OUTPUT" "setupv4 · Ergebnis" \
    "Die Ergebniskarte erscheint am Ende"
assert_contains "$PTY_OUTPUT" "Module" \
    "Das Dashboard zeigt die Module"

# Der Kindprozess hat seinen Plan gemeldet und seine Ereignisse geschrieben.
TUI_PROGRESS_FILE="$SANDBOX_HOME/logs/tui-progress.log"
TUI_STREAM_FILE="$SANDBOX_HOME/logs/tui-stream.log"

plan_zeilen="$(grep -c '^plan|' "$TUI_PROGRESS_FILE" 2>/dev/null || echo 0)"
assert_ne "0" "$plan_zeilen" "Das Kind hat seinen Modulplan gemeldet"

ende_ereignisse="$(grep -c '^end|' "$TUI_PROGRESS_FILE" 2>/dev/null || echo 0)"
assert_ne "0" "$ende_ereignisse" "Das Kind hat Fortschrittsereignisse geschrieben"

if [ -s "$TUI_STREAM_FILE" ]; then
    pass "Das Log des Kindprozesses ist nicht leer"
else
    fail "Das Log des Kindprozesses ist leer oder fehlt" "erwartet: $TUI_STREAM_FILE"
fi

# Den Inhalt des Kind-Logs fuer Abschnitt 7 sichern.
TUI_STREAM_INHALT=""
[ -f "$TUI_STREAM_FILE" ] && TUI_STREAM_INHALT="$(cat "$TUI_STREAM_FILE")"
TUI_LAUF_OUTPUT="$PTY_OUTPUT"

# ==============================================================================
section "4. 'q' bricht ab - es wird kein Setup ausgefuehrt"
# ==============================================================================
# Die Logdateien des Kindprozesses werden vorher entfernt: nur so belegt
# ihre Abwesenheit, dass in diesem Lauf kein Setup gestartet wurde.
rm -f "$SANDBOX_HOME/logs/tui-stream.log" "$SANDBOX_HOME/logs/tui-progress.log"

run_pty "q" "cd $SANDBOX_DIR && stty rows 40 cols 120; bash ./setup.sh --dry-run --no-profile"

assert_not_contains "$PTY_OUTPUT" "setupv4 · Ausführung" \
    "Es startet kein Dashboard"
assert_not_contains "$PTY_OUTPUT" "setupv4 · Ergebnis" \
    "Es erscheint keine Ergebniskarte"
assert_contains "$PTY_OUTPUT" "Abgebrochen" \
    "Der Abbruch wird gemeldet"
assert_exit "0" "$PTY_EXIT" "Der Abbruch endet ohne Fehler"

if [ ! -f "$SANDBOX_HOME/logs/tui-stream.log" ]; then
    pass "Es wurde kein Kindprozess gestartet (kein Log des Kindes)"
else
    fail "Es wurde doch ein Kindprozess gestartet" \
        "unerwartet: $SANDBOX_HOME/logs/tui-stream.log"
fi

# ==============================================================================
section "5. Ohne Terminal startet die Oberflaeche nicht"
# ==============================================================================
# Gleicher Aufruf wie in Abschnitt 1 - nur ohne Pseudo-Terminal: stdin und
# stdout sind Pipes, damit kann die Oberflaeche nicht starten.
run_nopty "bash ./setup.sh --dry-run --no-profile --modules hostname"

assert_not_contains "$NO_PTY_OUTPUT" "Software-Auswahl" \
    "Der Textpfad zeigt keine Software-Auswahl"
assert_not_contains "$NO_PTY_OUTPUT" "Welche Software soll eingerichtet werden?" \
    "Es wird nicht nach der Software gefragt"
assert_not_contains "$NO_PTY_OUTPUT" "setupv4 · Ausführung" \
    "Es startet kein Dashboard"
assert_contains "$NO_PTY_OUTPUT" "Geplante Module:" \
    "Der klassische Textpfad laeuft (Modulplan)"
assert_contains "$NO_PTY_OUTPUT" "TROCKENLAUF" \
    "Der klassische Textpfad meldet den Trockenlauf"

# ==============================================================================
section "6. --no-tui erzwingt den Textpfad auch mit Terminal"
# ==============================================================================
# "4" = Beenden im klassischen Hauptmenue.
run_pty $'4\n' \
    "cd $SANDBOX_DIR && stty rows 40 cols 120; bash ./setup.sh --dry-run --no-profile --no-tui"

assert_not_contains "$PTY_OUTPUT" "setupv4 · Software-Auswahl" \
    "Die Vollbild-Oberflaeche startet nicht"
assert_not_contains "$PTY_OUTPUT" "Welche Software soll eingerichtet werden?" \
    "Es wird nicht nach der Software gefragt"
assert_contains "$PTY_OUTPUT" "Ihre Wahl" \
    "Das klassische Hauptmenue erscheint"
assert_contains "$PTY_OUTPUT" "Abgebrochen" \
    "Der klassische Abbruch wird gemeldet"
assert_exit "0" "$PTY_EXIT" "Der klassische Abbruch endet ohne Fehler"

# ==============================================================================
section "7. Das Wirtssystem bleibt unangetastet"
# ==============================================================================
# Der Lauf aus Abschnitt 3 war ein Trockenlauf: im Log des Kindes steht
# jeder Befehl als "[DRY-RUN]" - es wurde also nichts ausgefuehrt.
assert_contains "$TUI_STREAM_INHALT" "[DRY-RUN]" \
    "Im Log steht jeder Befehl als DRY-RUN"
assert_contains "$TUI_STREAM_INHALT" "TROCKENLAUF" \
    "Der Lauf wurde als Trockenlauf gefuehrt"

# Das Setup lief im eigenen SETUP_HOME der Sandbox, nicht unter /opt.
assert_contains "$TUI_LAUF_OUTPUT" "Installiere nach $SANDBOX_HOME" \
    "Das Setup laeuft im eigenen SETUP_HOME"

# Die Sicherungen landen im Backup-Verzeichnis der Sandbox.
if [ -d "$SANDBOX_BACKUPS" ]; then
    pass "Das Backup-Verzeichnis liegt in der Sandbox"
else
    fail "Das Backup-Verzeichnis liegt nicht in der Sandbox" "erwartet: $SANDBOX_BACKUPS"
fi

# Die systemweiten Zielverzeichnisse wurden nicht veraendert.
if [ "$SYS_SETUP_HOME_EXISTED" = "1" ]; then
    aktueller_stamp="-"
    if [ -f /opt/serversetup/logs/setup.log ]; then
        aktueller_stamp="$(wc -c < /opt/serversetup/logs/setup.log | tr -d ' ')"
    fi
    assert_eq "$SYS_SETUP_LOG_STAMP" "$aktueller_stamp" \
        "Das Log unter /opt/serversetup ist unveraendert"
else
    if [ -d /opt/serversetup ]; then
        fail "Unter /opt/serversetup wurde etwas angelegt" "unerwartet: /opt/serversetup"
    else
        pass "Unter /opt/serversetup wurde nichts angelegt"
    fi
fi

if [ "$SYS_BACKUP_EXISTED" = "1" ]; then
    aktuelle_anzahl="$(find /var/backups/serversetup -type f 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$SYS_BACKUP_COUNT" "$aktuelle_anzahl" \
        "Im systemweiten Backup-Verzeichnis wurde nichts abgelegt"
else
    if [ -d /var/backups/serversetup ]; then
        fail "Das systemweite Backup-Verzeichnis wurde angelegt" \
            "unerwartet: /var/backups/serversetup"
    else
        pass "Das systemweite Backup-Verzeichnis wurde nicht angelegt"
    fi
fi

test_summary
