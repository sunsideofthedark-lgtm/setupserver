#!/bin/bash
# ==============================================================================
# setupv4 - Modulares Server-Setup (Hauptscript)
# ==============================================================================
# Aufbau:
#   setup.sh              dieses Script (Ablaufsteuerung, CLI)
#   lib/core.sh           Ausgabe, Logging, Eingaben, Validierung
#   lib/os.sh             Betriebssystem, Paketmanager, Services
#   lib/config.sh         Config laden, mergen, validieren
#   lib/modules.sh        Module finden, auswählen, ausführen
#   modules/*.sh          ein Modul pro Datei
#   config/               Beispielkonfiguration und Server-Profile
#
# Das Script arbeitet unabhängig davon, von wo es gestartet wurde: Es kopiert
# sich beim ersten Start nach $SETUP_HOME (Standard /opt/serversetup) und
# läuft von dort weiter. Script, Bibliotheken und Logs liegen danach immer
# an derselben Stelle.
#
# Beispiele:
#   sudo bash setup.sh                                  # interaktiv
#   sudo bash setup.sh --init                           # setup.conf erzeugen
#   sudo bash setup.sh --config config/setup.conf       # nicht-interaktiv
#   sudo bash setup.sh --config config/setup.conf --dry-run
#   sudo bash setup.sh --list                           # verfügbare Module
#   sudo /opt/serversetup/setup.sh --status --modules users,firewall
#   ZOT_API_KEY=... sudo -E bash setup.sh -c config/su-001.conf
# ==============================================================================

set -o pipefail

SETUP_VERSION="4.0.0"

# Zielverzeichnis für Script, Bibliotheken, Module und Logs.
# Unabhängig vom Startpfad liegt nach dem ersten Lauf alles hier.
SETUP_HOME="${SETUP_HOME:-/opt/serversetup}"
ORIGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_RESET='\033[0m'
C_RED='\033[31m'

usage() {
    cat << EOF
setupv4 $SETUP_VERSION - Modulares Server-Setup

Verwendung: sudo bash setup.sh [Optionen]

Optionen:
  -c, --config <datei>   Konfigurationsdatei laden (Shell-.conf)
      --modules <liste>  Nur diese Module ausführen (z. B. users,firewall)
      --set KEY=WERT     Einzelne Config-Variable überschreiben (mehrfach)
  -n, --dry-run          Nichts ändern, nur anzeigen
  -y, --yes              Rückfragen automatisch mit "Ja" beantworten
      --non-interactive  Keine Rückfragen - fehlende Werte führen zum Abbruch
      --list             Verfügbare Module auflisten und beenden
      --status           Status der gewählten Module prüfen
      --audit            Ist-Zustand gegen die Zielkonfiguration prüfen
      --check-reboot     Prüfen, ob ein Neustart nötig ist
      --init             Beispielkonfiguration erzeugen
      --no-profile       Server-Profil config/servers/<hostname>.conf ignorieren
      --no-relocate      Nicht nach $SETUP_HOME umziehen, direkt hier laufen
  -h, --help             Diese Hilfe anzeigen

Umgebungsvariablen:
  SETUP_HOME=/opt/serversetup   Zielverzeichnis für Script und Logs
  DEBUG=1                       Ausführliche Debug-Ausgabe
  ZOT_API_KEY=...               Secrets können über die Umgebung gesetzt werden

Beispiele:
  sudo bash setup.sh --init
  sudo bash setup.sh --config config/setup.conf
  sudo bash setup.sh --config config/servers/su-001.conf --dry-run
EOF
}

# ==============================================================================
# Verlagerung nach $SETUP_HOME
# ==============================================================================
# Ziel: egal von wo gestartet wird, arbeiten Script und Logs ab sofort an
# einer festen Stelle. Das ist wichtig für spätere Läufe und Backups.
relocate_to_setup_home() {
    local reloc_flag="SETUPV4_RELOCATED"

    # Bereits am Zielort oder Relokation abgeschaltet
    if [ "$ORIGIN_DIR" = "$SETUP_HOME" ]; then
        return 0
    fi
    if [ "${!reloc_flag:-0}" = "1" ]; then
        return 0
    fi

    # Sicherheitsprüfung: weiter unten wird "rm -rf $SETUP_HOME/lib" ausgeführt.
    # Ein leeres oder "/" als Ziel würde damit Systemverzeichnisse löschen.
    case "$SETUP_HOME" in
        ""|"/"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/home"|"/root")
            echo -e "${C_RED}[ERROR] Ungültiges SETUP_HOME: '$SETUP_HOME'${C_RESET}" >&2
            echo "        Das Ziel darf weder leer noch ein Systemverzeichnis sein." >&2
            echo "        Mit --no-relocate direkt am aktuellen Ort laufen." >&2
            return 1
            ;;
    esac

    mkdir -p "$SETUP_HOME/lib" "$SETUP_HOME/modules" \
             "$SETUP_HOME/config" "$SETUP_HOME/logs" 2>/dev/null || {
        echo -e "${C_RED}[ERROR] $SETUP_HOME konnte nicht angelegt werden.${C_RESET}" >&2
        echo "        Mit --no-relocate direkt am aktuellen Ort laufen." >&2
        return 1
    }

    # Programmcode wird immer aktualisiert, damit keine alten Module
    # zurückbleiben, die es in der neuen Version nicht mehr gibt.
    cp -f "$ORIGIN_DIR/setup.sh" "$SETUP_HOME/setup.sh" 2>/dev/null
    if [ -d "$ORIGIN_DIR/lib" ]; then
        rm -rf "$SETUP_HOME/lib" 2>/dev/null
        cp -r "$ORIGIN_DIR/lib" "$SETUP_HOME/lib" 2>/dev/null
    fi
    if [ -d "$ORIGIN_DIR/modules" ]; then
        rm -rf "$SETUP_HOME/modules" 2>/dev/null
        cp -r "$ORIGIN_DIR/modules" "$SETUP_HOME/modules" 2>/dev/null
    fi

    # Konfiguration wird nur ergänzt, nie überschrieben - sie kann
    # Server-spezifische Profile enthalten, die sonst verloren gingen.
    if [ -d "$ORIGIN_DIR/config" ]; then
        cp -rn "$ORIGIN_DIR/config/." "$SETUP_HOME/config/" 2>/dev/null
    fi

    # Der Aufruf wird mit unveränderten Argumenten dort wiederholt
    printf "Installiere nach %s und führe dort fort...\n" "$SETUP_HOME"
    export SETUPV4_RELOCATED=1
    exec bash "$SETUP_HOME/setup.sh" "$@"
}

# --- Argumentauswertung ---
DO_INIT=""
SHOW_LIST=""
SHOW_STATUS=""
SHOW_AUDIT=""
CHECK_REBOOT=""
USE_PROFILE=1
DO_RELOCATE=1

# Argumente vormerken: die Parse-Schleife unten arbeitet mit shift und würde
# "$@" danach leeren. Für die Verlagerung brauchen wir aber genau die
# ursprüngliche Aufrufzeile.
ORIGINAL_ARGS=("$@")

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)        CLI_CONFIG="$2"; shift 2 ;;
        --modules)          CLI_MODULES="$2"; shift 2 ;;
        --set)              CLI_SET+=("$2"); shift 2 ;;
        -n|--dry-run)       DRY_RUN=1; shift ;;
        -y|--yes)           ASSUME_YES=1; shift ;;
        --non-interactive)  NON_INTERACTIVE=1; shift ;;
        --no-profile)       USE_PROFILE=0; shift ;;
        --no-relocate)      DO_RELOCATE=0; shift ;;
        --list)             SHOW_LIST=1; shift ;;
        --status)           SHOW_STATUS=1; shift ;;
      --audit)            SHOW_AUDIT=1; shift ;;
        --check-reboot)     CHECK_REBOOT=1; shift ;;
        --init)             DO_INIT=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ "$DO_RELOCATE" = "1" ]; then
    relocate_to_setup_home "${ORIGINAL_ARGS[@]}"
else
    # Ohne Verlagerung bleibt alles am Aufrufort - sonst würden die
    # Bibliotheken weiterhin unter $SETUP_HOME gesucht und nicht gefunden.
    SETUP_HOME="$ORIGIN_DIR"
fi

# Ab hier ist der Pfad fest
SETUP_DIR="$SETUP_HOME"
MODULES_DIR="$SETUP_DIR/modules"
LIB_DIR="$SETUP_DIR/lib"
CONFIG_DIR="$SETUP_DIR/config"
SERVERS_CONFIG_DIR="$CONFIG_DIR/servers"
LOGFILE="$SETUP_DIR/logs/setup.log"

# Logfile anlegen, BEVOR die Bibliotheken geladen sind: die debug()-Aufrufe
# beim Konfig-Laden schreiben bereits ins Log, und bis setup_logging läuft,
# würde die Datei sonst mit zu weiten Rechten entstehen.
mkdir -p "$SETUP_DIR/logs" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true
chmod 600 "$LOGFILE" 2>/dev/null || true

# --- Bibliotheken laden ---
# Reihenfolge ist bedeutsam: core definiert die Ausgabe-Funktionen, auf die
# sich die anderen beiden beim Laden beziehen.
for lib in core os config modules; do
    if [ ! -f "$LIB_DIR/$lib.sh" ]; then
        echo "[ERROR] Bibliothek fehlt: $LIB_DIR/$lib.sh" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$LIB_DIR/$lib.sh" || {
        echo "[ERROR] Bibliothek konnte nicht geladen werden: $lib.sh" >&2
        exit 1
    }
done

# --- Root-Prüfung ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${C_RED}[ERROR] Dieses Script muss als Root ausgeführt werden.${C_RESET}" >&2
    echo "Verwende: sudo bash $0 $*" >&2
    exit 1
fi

# --- Reboot-Prüfung ---
# Braucht keine Konfiguration und läuft deshalb vor allem anderen.
# Exit-Code 1 = Neustart nötig, 0 = nicht nötig. So direkt in eine Prüf-Pipeline
# einbindbar.
if [ -n "$CHECK_REBOOT" ]; then
    echo ""
    # reboot_required gibt 0 zurück, wenn KEIN Neustart nötig ist
    if reboot_required; then
        echo -e "${C_GREEN}[REBOOT] Kein Neustart erforderlich${C_RESET}"
        echo "  Laufender Kernel: $(uname -r)"
        exit 0
    fi
    echo -e "${C_YELLOW}[REBOOT] Neustart erforderlich${C_RESET}"
    echo "  Grund:         ${REBOOT_REASONS:-unbekannt}"
    echo "  Erkannt über:  ${REBOOT_SOURCE:-unbekannt}"
    exit 1
fi

# --- Beispielkonfiguration erzeugen ---
# Kommt nach der Modul-Discovery, damit die erzeugte Config auch wirklich
# alle vorhandenen Module auflistet.
config_set_defaults

[ -d "$MODULES_DIR" ] || fatal "Modulverzeichnis nicht gefunden: $MODULES_DIR"
discover_modules

if [ ${#AVAILABLE_MODULES[@]} -eq 0 ]; then
    fatal "Keine Module gefunden in $MODULES_DIR"
fi

if [ -n "$DO_INIT" ]; then
    config_write_example "$CONFIG_DIR/setup.conf.example"
    exit 0
fi

# --- Config laden ---
if [ -n "$CLI_CONFIG" ]; then
    if [ ! -f "$CLI_CONFIG" ]; then
        error "Config-Datei nicht gefunden: $CLI_CONFIG"
        exit 1
    fi
    config_load "$CLI_CONFIG" || exit 1
else
    if [ -f "$CONFIG_DIR/setup.conf" ]; then
        info "Keine Config angegeben - verwende $CONFIG_DIR/setup.conf"
        config_load "$CONFIG_DIR/setup.conf" || exit 1
    fi
fi

# Server-Profil (config/servers/<hostname>.conf) überschreibt die Basis-Config
if [ "$USE_PROFILE" = "1" ] && [ -n "$CONFIG_FILE" ]; then
    config_load_host_profile "$SERVERS_CONFIG_DIR"
fi

# --set hat die höchste Priorität
if [ ${#CLI_SET[@]} -gt 0 ]; then
    for pair in "${CLI_SET[@]}"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        if [ "$key" = "$pair" ]; then
            error "--set erwartet KEY=WERT, erhalten: '$pair'"
            exit 1
        fi
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            error "--set: ungültiger Variablenname '$key'"
            exit 1
        fi
        printf -v "$key" '%s' "$value"
        debug "Config-Override: $key gesetzt"
    done
fi

# --- Auslisten ---
if [ -n "$SHOW_LIST" ]; then
    echo ""
    info "Verfügbare Module:"
    show_module_list
    echo ""
    exit 0
fi

# --- Modulauswahl bestimmen ---
resolve_module_selection "$CLI_MODULES"
selection_rc=$?

if [ $selection_rc -eq 1 ]; then
    # Ungültige Auswahl - niemals stillschweigend auf etwas anderes ausweichen
    fatal "Die gewünschte Modulauswahl ist ungültig."
fi

if [ $selection_rc -eq 2 ]; then
    # Keine Auswahlquelle - nur hier ist eine interaktive Frage sinnvoll.
    # Ohne TTY (cron, ansible, CI) würde der read-Aufruf hängen bleiben,
    # deshalb wird in dem Fall klar abgebrochen.
    if [ "$NON_INTERACTIVE" = "1" ]; then
        fatal "Keine Module angegeben und nicht-interaktiver Modus aktiv.
  Bitte --modules <liste> oder --config <datei> verwenden."
    fi

    if [ ! -t 0 ]; then
        fatal "Keine Module angegeben und kein Terminal für die interaktive Auswahl.
  Bitte --modules <liste> oder --config <datei> verwenden.
  Für Automatisierung zusätzlich --non-interactive setzen."
    fi

    echo ""
    info "Verfügbare Module:"
    show_module_list
    select_modules_interactive
fi

[ ${#SELECTED_MODULES[@]} -eq 0 ] && fatal "Keine Module zum Ausführen ausgewählt."

# --- Konfiguration prüfen ---
if ! config_validate; then
    fatal "Konfiguration enthält Fehler - bitte korrigieren und erneut starten."
fi

# --- Status ---
if [ -n "$SHOW_STATUS" ]; then
    show_module_status
    exit 0
fi

# --- Audit: Ist-Zustand gegen Ziel aus der Konfiguration ---
if [ -n "$SHOW_AUDIT" ]; then
    detect_os
    show_audit
    exit $?
fi

# --- Zusammenfassung ---
echo ""
info "setupv4 $SETUP_VERSION"
if [ "$DRY_RUN" = "1" ]; then
    warning "TROCKENLAUF - es werden keine Änderungen am System vorgenommen."
fi
if [ "$NON_INTERACTIVE" = "1" ]; then
    info "Nicht-interaktiver Modus - fehlende Werte führen zum Abbruch."
fi
echo "     Arbeitsverzeichnis: $SETUP_DIR"
echo "     Logdatei:           $LOGFILE"
config_summary
echo ""
info "Geplante Module:"
for m in "${SELECTED_MODULES[@]}"; do
    echo "  • $m - $(module_name_for "$m")"
done

# --- Sicherheitsabfrage ---
if [ "$DRY_RUN" != "1" ]; then
    echo ""
    if ! ask_yes_no "Setup jetzt ausführen?" "y"; then
        skip "Abgebrochene Ausführung"
        exit 0
    fi
fi

# --- Betriebssystem erkennen ---
echo ""
detect_os

# --- Ausführung ---
init_logging

FAILED_MODULES=()
for m in "${SELECTED_MODULES[@]}"; do
    if ! run_module "$m"; then
        FAILED_MODULES+=("$m")
        warning "Modul '$m' hatte einen Fehler - fahre mit den restlichen fort."
    fi
done

# --- Abschluss ---
show_run_summary

if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    echo ""
    error "Fehlgeschlagene Module: ${FAILED_MODULES[*]}"
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    success "Trockenlauf abgeschlossen - es wurde nichts am System geändert."
    exit 0
fi

# --- Neustart ---
# Ein Neustart kann auch dann nötig sein, wenn REBOOT_AT_END=false ist:
# unattended-upgrades installiert im Hintergrund neue Kernel, die erst nach
# einem Neustart aktiv werden. Genau diese Falle wird hier aufgedeckt.
if reboot_required; then
    REBOOT_NEEDED=0
else
    REBOOT_NEEDED=1
    echo ""
    warning "Ein Neustart wäre erforderlich: $REBOOT_REASONS"
    echo "        Erkannt über: $REBOOT_SOURCE"
    if config_bool REBOOT_AT_END; then
        echo "        REBOOT_AT_END ist gesetzt - siehe unten."
    else
        echo "        Neustart später manuell: sudo systemctl reboot"
        echo "        jederzeit nachprüfbar mit: sudo bash setup.sh --check-reboot"
    fi
fi

if [ "$REBOOT_NEEDED" = "1" ] && config_bool REBOOT_AT_END; then
    echo ""
    if ask_yes_no "Server jetzt neu starten?" "y"; then
        info "Server wird neu gestartet..."
        run_cmd reboot
    else
        skip "Neustart übersprungen"
    fi
elif config_bool REBOOT_AT_END; then
    echo ""
    skip "REBOOT_AT_END ist gesetzt, aber es ist kein Neustart erforderlich"
fi

echo ""
success "Setup abgeschlossen."
exit 0