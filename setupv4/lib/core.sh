#!/bin/bash
# ==============================================================================
# setupv4/lib/core.sh - Kern: Ausgabe, Logging, Eingaben, Validierung
# ==============================================================================
# Diese Datei wird vom Hauptscript geladen und stellt die Basisfunktionen für
# alle Module bereit. Sie enthält bewusst KEINE Logik aus einzelnen Modulen.
# ==============================================================================

# --- Farben ---
C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_MAGENTA='\033[35m'
C_CYAN='\033[36m'

# --- Laufzeitflags (vom Hauptscript gesetzt) ---
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# --- Logging ---
setup_logging() {
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

    # Log-Rotation: das Logfile wächst sonst über viele Läufe unbegrenzt.
    # Eine Vorgabe Generation genügt - der alte Inhalt wird überschrieben.
    if [ -f "$LOGFILE" ]; then
        local size_kb
        size_kb=$(du -k "$LOGFILE" 2>/dev/null | cut -f1)
        if [ -n "$size_kb" ] && [ "$size_kb" -gt "${LOG_MAX_KB:-2048}" ]; then
            mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
            debug "Logfile rotiert: $LOGFILE -> $LOGFILE.1"
        fi
    fi

    if [ ! -f "$LOGFILE" ]; then
        touch "$LOGFILE" 2>/dev/null || true
    fi

    # Rechte bei JEDEM Lauf erzwingen, nicht nur beim Anlegen: die Datei kann
    # durch einen Kopiervorgang oder von einem anderen Nutzer mit zu weiten
    # Rechten übernommen worden sein.
    chmod 600 "$LOGFILE" 2>/dev/null || true

    {
        echo "=== Setup gestartet: $(date) ==="
        echo "Script: $0"
        echo "Arbeitsverzeichnis: ${SETUP_DIR:-unbekannt}"
        echo "Benutzer: $(whoami)"
        echo "OS: $(uname -a)"
        if [ -n "${CONFIG_FILE:-}" ]; then
            echo "Config: $CONFIG_FILE"
        fi
        echo "Modules: ${SELECTED_MODULES[*]:-n/a}"
        echo "==================================================="
    } >> "$LOGFILE" 2>/dev/null || true
}

init_logging() {
    setup_logging
}

log_action() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOGFILE" 2>/dev/null || true
}

debug() {
    local message="[DEBUG $(date '+%H:%M:%S')] $1"
    if [ "$DEBUG" = "1" ]; then
        echo -e "${C_MAGENTA}$message${C_RESET}" >&2
    fi
    echo "$message" >> "$LOGFILE" 2>/dev/null || true
}

info() {
    echo -e "${C_BLUE}[INFO] $1${C_RESET}"
    log_action "INFO" "$1"
}

success() {
    echo -e "${C_GREEN}[SUCCESS] $1${C_RESET}"
    log_action "SUCCESS" "$1"
}

warning() {
    echo -e "${C_YELLOW}[WARNING] $1${C_RESET}"
    log_action "WARNING" "$1"
}

error() {
    echo -e "${C_RED}[ERROR] $1${C_RESET}" >&2
    log_action "ERROR" "$1"
}

# Bricht das Setup kontrolliert ab
fatal() {
    error "$1"
    log_action "FATAL" "Setup abgebrochen"
    exit 1
}

# Hinweis + Skip eines Moduls
skip() {
    info "⏭️  $1"
    log_action "SKIP" "$1"
}

error_with_debug() {
    local exit_code=$?
    local line_no="$1"
    local command="$2"
    echo -e "${C_RED}[FEHLER] Zeile $line_no (Exit $exit_code): $command${C_RESET}" >&2
    if [ "$DEBUG" = "1" ]; then
        echo -e "${C_MAGENTA}[DEBUG] OS_ID=${OS_ID:-?} PKG_MANAGER=${PKG_MANAGER:-?} SSH_PORT=${SSH_PORT:-?}${C_RESET}" >&2
    fi
    return $exit_code
}

# --- Eingaben ---

# Ja/Nein-Abfrage mit Vorgabe. Verwendet stderr, damit die Ausgabe auch bei
# umgeleiteter stdout-Umgebung sichtbar bleibt.
ask_yes_no() {
    local prompt="$1"
    local default_answer="$2"   # "y" oder "n"
    local answer

    # Im nicht-interaktiven Modus gibt es keine Rückfrage-Möglichkeit
    if [ "$NON_INTERACTIVE" = "1" ]; then
        [ "$default_answer" = "y" ] && return 0
        return 1
    fi

    while true; do
        case "$default_answer" in
            y) echo -e "${C_CYAN}${prompt} [J/n]: ${C_RESET}" >&2 ;;
            n) echo -e "${C_CYAN}${prompt} [j/N]: ${C_RESET}" >&2 ;;
            *) echo -e "${C_CYAN}${prompt} [j/n]: ${C_RESET}" >&2 ;;
        esac
        read -r answer || answer=""
        answer="${answer:-$default_answer}"
        case $answer in
            [Yy]*|[Jj]*) return 0 ;;
            [Nn]*|"")    return 1 ;;
            *)           warning "Bitte 'y' oder 'n' eingeben." ;;
        esac
    done
}

# Wie ask_yes_no, überschreibt aber eine vorhandene Antwort nur mit --yes
confirm() {
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    ask_yes_no "$1" "${2:-n}"
}

# Fragt einen Wert ab, übernimmt bei leerer Eingabe den Standard
ask_value() {
    local prompt="$1"
    local default_value="$2"
    local varname="$3"
    local input=""

    if [ -n "$default_value" ]; then
        echo -e "${C_CYAN}${prompt} [${C_RESET}${default_value}${C_CYAN}]: ${C_RESET}" >&2
    else
        echo -e "${C_CYAN}${prompt}: ${C_RESET}" >&2
    fi

    read -r input || input=""
    [ -z "$input" ] && input="$default_value"

    if [ -z "$input" ]; then
        error "Kein Wert für '${varname}' - Eingabe erforderlich."
        return 1
    fi

    printf -v "$varname" '%s' "$input"
    return 0
}

# Fragt ein Secret verdeckt ab (nie in History, nie im Log)
ask_secret() {
    local prompt="$1"
    local varname="$2"
    local input="" confirm_input=""

    while true; do
        echo -e "${C_CYAN}${prompt}: ${C_RESET}" >&2
        read -rs input || input=""
        echo "" >&2
        if [ -z "$input" ]; then
            warning "Eingabe darf nicht leer sein."
            continue
        fi
        echo -e "${C_CYAN}${prompt} (wiederholen): ${C_RESET}" >&2
        read -rs confirm_input || confirm_input=""
        echo "" >&2
        if [ "$input" != "$confirm_input" ]; then
            warning "Die Eingaben stimmen nicht überein."
            continue
        fi
        break
    done

    printf -v "$varname" '%s' "$input"
    unset confirm_input
    return 0
}

# --- Secrets ---
mask_secret() {
    local secret="$1"
    local len=${#secret}
    if [ $len -le 8 ]; then
        echo "****"
    else
        echo "${secret:0:4}****${secret: -4}"
    fi
}

# --- Validierung ---

validate_hostname() {
    local hostname="$1"
    # RFC 1123: Labels aus Buchstaben, Ziffern und Bindestrich, max. 63 Zeichen
    if [[ ${#hostname} -gt 63 ]]; then
        return 1
    fi
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        return 1
    fi
    return 0
}

validate_username() {
    local username="$1"
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

validate_cidr() {
    local cidr="$1"

    if [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip="${cidr%/*}"
        local prefix="${cidr#*/}"

        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [ "$octet" -gt 255 ] && return 1
        done

        if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
            return 1
        fi
        return 0
    fi
    return 1
}

validate_tags() {
    local tags="$1"
    local IFS=','
    for tag in $tags; do
        tag=$(echo "$tag" | xargs)
        if [[ ! "$tag" =~ ^tag:[a-zA-Z0-9_-]+$ ]]; then
            return 1
        fi
    done
    return 0
}

validate_passkey() {
    local passkey="$1"
    local min_length=20

    if [ ${#passkey} -lt $min_length ]; then
        return 1
    fi
    return 0
}

# --- Backups ---
# Legt vor jeder Änderung an Systemdateien eine Sicherung an
create_backup() {
    local file="$1"
    local backup_dir="${BACKUP_DIR:-/var/backups/serversetup}"

    if [ ! -f "$file" ]; then
        debug "Kein Backup nötig, '$file' existiert nicht"
        return 0
    fi

    mkdir -p "$backup_dir" 2>/dev/null || true
    local backup_file="$backup_dir/$(echo "$file" | tr '/' '_').$(date +%Y%m%d_%H%M%S).bak"

    if cp -p "$file" "$backup_file" 2>/dev/null; then
        debug "Backup erstellt: $backup_file"
        return 0
    fi

    warning "Backup von '$file' fehlgeschlagen"
    return 1
}