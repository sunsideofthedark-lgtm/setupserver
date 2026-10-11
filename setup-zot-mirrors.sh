#!/usr/bin/env bash
# ==============================================================================
# Zot-Registry-Mirrors für Docker einrichten (Version 1.0.0)
# ==============================================================================
# Dieses Skript konfiguriert den containerd Image Store von Docker so, dass
# Pulls von externen Registries zuerst über die eigene Zot-Instanz laufen und
# bei deren Ausfall automatisch auf das jeweilige Original-Registry zurückfallen.
#
# WICHTIG - Voraussetzung:
# Docker wertet die hosts.toml-Dateien NUR aus, wenn der containerd Image Store
# aktiv ist (daemon.json -> "features": {"containerd-snapshotter": true}).
# Bei Docker Engine 29.0+ ist das bei Neuinstallationen bereits der Fall; bei
# von älteren Versionen aktualisierten Daemons läuft es weiterhin der klassische
# Image Store. Das Skript prüft das und bietet die Aktivierung an.
#
# Ausführung:  sudo bash ./setup-zot-mirrors.sh
# Debug-Modus: DEBUG=1 sudo bash ./setup-zot-mirrors.sh
# Trockenlauf:  sudo bash ./setup-zot-mirrors.sh --dry-run
#
# Hinweis: Der API-Key wird ausschliesslich interaktiv und verdeckt abgefragt.
# Er wird weder in die History noch in das Logfile geschrieben.
# ==============================================================================

set -euo pipefail

# --- Standardwerte (interaktiv überschreibbar) ---
DEFAULT_ZOT_ENDPOINT="https://zot.sunriseing.dev"
DEFAULT_ZOT_USER="admin"
BASE_DIR="/etc/docker/certs.d"
DAEMON_JSON="/etc/docker/daemon.json"

# Registry-Mappings: domain|upstream-server|zot-prefix
#   domain     - Name, wie er im Image-Pfad steht (z. B. ghcr.io/linuxserver/nginx)
#   upstream   - Echter Endpunkt im Internet (Fallback, falls Zot nicht antwortet)
#   prefix     - Ziel-Praefix unter dem Zot die Images ablegt (sync-Sektion config.json)
declare -a REGISTRIES=(
  "docker.io|https://registry-1.docker.io|docker-images"
  "ghcr.io|https://ghcr.io|ghcr"
  "quay.io|https://quay.io|quay"
  "mcr.microsoft.com|https://mcr.microsoft.com|mcr"
  "registry.k8s.io|https://registry.k8s.io|k8s"
  "gcr.io|https://gcr.io|gcr"
  "public.ecr.aws|https://public.ecr.aws|ecr"
)

DRY_RUN=0

# --- Farben für die Ausgabe ---
C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_CYAN='\033[36m'

DEBUG=${DEBUG:-0}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOGFILE="$SCRIPT_DIR/zot-mirrors.log"

# --- Ausgabe- und Logging-Funktionen ---

log_action() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOGFILE" 2>/dev/null || true
}

debug() {
    local message="[DEBUG $(date '+%H:%M:%S')] $1"
    if [ "$DEBUG" = "1" ]; then
        echo -e "${C_CYAN}$message${C_RESET}" >&2
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

# Bestätigungsfunktion
confirm() {
    while true; do
        echo -e "${C_CYAN}$1 [y/N]: ${C_RESET}" >&2
        local yn
        read -r yn || return 1
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* | "" ) return 1;;
            * ) warning "Bitte 'y' oder 'n' eingeben.";;
        esac
    done
}

# Maskiert sensible Daten für Logs (zeigt nur erste/letzte 4 Zeichen)
mask_secret() {
    local secret="$1"
    local len=${#secret}
    if [ $len -le 8 ]; then
        echo "****"
    else
        echo "${secret:0:4}****${secret: -4}"
    fi
}

# --- Hilfsfunktionen ---

# Entfernt führende/abschließende Schrägstriche. Das http(s)://-Schema bleibt
# erhalten, da es in der hosts.toml zwingend benötigt wird.
normalize_endpoint() {
    local url="$1"
    url="${url#/}"
    url="${url%/}"
    echo "$url"
}

# Entfernt das http(s):// für Aufrufe, die nur den Hostnamen erwarten
# (z. B. 'docker login')
strip_scheme() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    echo "$url"
}

# Validiert eine Registry-URL (Scheme + Hostname mit mindestens einer Domain)
validate_endpoint() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]] || return 1
    local host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
    return 0
}

# Validiert einen Registry-Domainnamen (z. B. ghcr.io)
validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
    return 0
}

# --- Root-Prüfung ---
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${C_RED}[ERROR] Dieses Skript muss als Root ausgeführt werden.${C_RESET}" >&2
    echo "Verwende: sudo bash $0" >&2
    exit 1
fi

# --- Argumentauswertung ---
usage() {
    cat << EOF
Zot-Registry-Mirrors für Docker einrichten

Verwendung: sudo bash $0 [Optionen]

Optionen:
  --dry-run    Nur anzeigen, was gemacht würde - keine Änderungen am System
  --help       Diese Hilfe anzeigen

Das Skript fragt Zot-Endpoint, Benutzername und API-Key interaktiv ab.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift;;
        --help|-h) usage; exit 0;;
        *) echo "Unbekannte Option: $1" >&2; usage; exit 1;;
    esac
done

touch "$LOGFILE" 2>/dev/null || true
chmod 600 "$LOGFILE" 2>/dev/null || true
echo "=== Zot-Mirror-Setup gestartet am $(date) ===" >> "$LOGFILE"
echo "Script: $0 | User: $(whoami) | OS: $(uname -a)" >> "$LOGFILE"
echo "===================================================" >> "$LOGFILE"

echo ""
info "Zot-Registry-Mirrors für Docker einrichten (Version 1.0.0)"
[[ "$DRY_RUN" == "1" ]] && warning "TROCKENLAUF - es werden keine Änderungen am System vorgenommen."
echo ""

# --- Docker-Prüfung ---
if ! command -v docker >/dev/null; then
    error "Docker ist nicht installiert. Bitte zuerst Docker installieren."
    exit 1
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unbekannt")
success "Docker gefunden (Version: $DOCKER_VERSION)"

# ==============================================================================
# Schritt 1: Interaktive Konfiguration
# ==============================================================================
echo ""
info "Schritt 1: Zot-Konfiguration"

ZOT_ENDPOINT="$DEFAULT_ZOT_ENDPOINT"
while true; do
    echo -e "${C_CYAN}Zot-Endpoint [${C_RESET}${DEFAULT_ZOT_ENDPOINT}${C_CYAN}]:${C_RESET}" >&2
    read -r input || input=""
    [ -z "$input" ] && input="$DEFAULT_ZOT_ENDPOINT"
    if validate_endpoint "$input"; then
        ZOT_ENDPOINT=$(normalize_endpoint "$input")
        break
    fi
    warning "Ungültige URL - erwartet wird z. B. https://zot.sunriseing.dev"
done
success "Zot-Endpoint: $ZOT_ENDPOINT"

# Hostname-Form fuer docker login (dort wird kein Schema erwartet)
ZOT_HOST="$(strip_scheme "$ZOT_ENDPOINT")"

ZOT_USER="$DEFAULT_ZOT_USER"
echo -e "${C_CYAN}Zot-Benutzername [${C_RESET}${DEFAULT_ZOT_USER}${C_CYAN}]:${C_RESET}" >&2
read -r input || input=""
[ -z "$input" ] && input="$DEFAULT_ZOT_USER"
ZOT_USER="$input"
success "Zot-Benutzername: $ZOT_USER"

# API-Key verdeckt abfragen (nie in History, nie im Log)
ZOT_API_KEY=""
while true; do
    echo -e "${C_CYAN}Zot-API-Key (Eingabe bleibt verborgen): ${C_RESET}" >&2
    read -rs ZOT_API_KEY || ZOT_API_KEY=""
    echo "" >&2
    if [ -z "$ZOT_API_KEY" ]; then
        warning "Der API-Key darf nicht leer sein."
        continue
    fi
    echo -e "${C_CYAN}Zot-API-Key wiederholen: ${C_RESET}" >&2
    confirm_key=""
    read -rs confirm_key || confirm_key=""
    echo "" >&2
    if [ "$ZOT_API_KEY" != "$confirm_key" ]; then
        warning "Die Eingaben stimmen nicht überein. Bitte erneut versuchen."
        continue
    fi
    break
done
unset confirm_key
debug "API-Key empfangen: $(mask_secret "$ZOT_API_KEY")"

if confirm "Mit 'docker login' bei $ZOT_HOST anmelden?"; then
    DO_LOGIN=1
else
    DO_LOGIN=0
    warning "docker login wird übersprungen - die Anmeldung muss später manuell erfolgen."
fi

# ==============================================================================
# Schritt 2: containerd Image Store prüfen
# ==============================================================================
echo ""
info "Schritt 2: containerd Image Store prüfen"

# NUR mit dem containerd Image Store wertet Docker die hosts.toml-Dateien aus.
CONTAINERD_STORE=0
DRIVER_STATUS=$(docker info -f '{{ .DriverStatus }}' 2>/dev/null || true)
debug "DriverStatus: $DRIVER_STATUS"
if [[ "$DRIVER_STATUS" == *"io.containerd.snapshotter.v1"* ]]; then
    CONTAINERD_STORE=1
    success "containerd Image Store ist aktiv - hosts.toml wird ausgewertet."
else
    warning "containerd Image Store ist NICHT aktiv."
    warning "Ohne ihn ignoriert Docker die hosts.toml-Dateien komplett."
fi

if [[ "$CONTAINERD_STORE" == "0" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        info "Trockenlauf: würde in '$DAEMON_JSON' ergänzen:"
        echo '  "features": { "containerd-snapshotter": true }'
    elif confirm "Containerd Image Store jetzt aktivieren? (erfordert Docker-Neustart)"; then
        if ! command -v python3 &>/dev/null; then
            warning "python3 ist nicht installiert - '$DAEMON_JSON' wird nicht automatisch geändert."
            echo "  Bitte von Hand in '$DAEMON_JSON' ergänzen:"
            echo '  { "features": { "containerd-snapshotter": true } }'
            echo "  Danach: systemctl restart docker"
            exit 1
        fi

        info "Aktiviere containerd Image Store in '$DAEMON_JSON' ..."
        # Bestehende Einstellungen werden dabei erhalten (kein Überschreiben!)
        if python3 - "$DAEMON_JSON" << 'PYEOF'
import json, os, shutil, sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    print(f"FEHLER: {path} enthaelt kein gueltiges JSON: {e}")
    sys.exit(1)

if not isinstance(data, dict):
    print("FEHLER: unerwarteter Aufbau in daemon.json")
    sys.exit(1)

features = data.get("features")
if not isinstance(features, dict):
    features = {}
features["containerd-snapshotter"] = True
data["features"] = features

tmp = path + ".zot-tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
shutil.move(tmp, path)
print("OK")
PYEOF
        then
            success "daemon.json aktualisiert (bestehende Einstellungen erhalten)."
            warning "Docker muss neu gestartet werden - laufende Container werden dabei unterbrochen."
            if confirm "Docker jetzt neu starten?"; then
                systemctl restart docker
                sleep 3
                DRIVER_STATUS=$(docker info -f '{{ .DriverStatus }}' 2>/dev/null || true)
                if [[ "$DRIVER_STATUS" == *"io.containerd.snapshotter.v1"* ]]; then
                    CONTAINERD_STORE=1
                    success "containerd Image Store ist jetzt aktiv."
                else
                    error "Aktivierung nicht wirksam. Bitte 'docker info' prüfen."
                fi
            else
                warning "Docker wurde nicht neu gestartet."
                echo "  Ohne Neustart bleiben die hosts.toml-Dateien ohne Wirkung."
                echo "  Später ausführen: sudo systemctl restart docker"
            fi
        else
            error "Aktualisierung von '$DAEMON_JSON' fehlgeschlagen."
        fi
    else
        warning "Übersprungen - die Mirror-Konfiguration bleibt ohne Wirkung."
    fi
fi

if [[ "$CONTAINERD_STORE" == "0" ]]; then
    error "Abbruch: Ohne containerd Image Store ist die Mirror-Konfiguration wirkungslos."
    exit 1
fi

# ==============================================================================
# Schritt 3: hosts.toml-Dateien schreiben
# ==============================================================================
echo ""
info "Schritt 3: hosts.toml-Konfiguration für ${#REGISTRIES[@]} Registries schreiben"

for item in "${REGISTRIES[@]}"; do
    IFS="|" read -r DOMAIN UPSTREAM_SERVER PREFIX <<< "$item"

    if ! validate_domain "$DOMAIN"; then
        error "Ungültiger Registry-Domain: '$DOMAIN' - wird übersprungen."
        continue
    fi
    if [[ -z "$UPSTREAM_SERVER" ]] || [[ -z "$PREFIX" ]]; then
        error "Unvollständiger Registry-Eintrag: '$item' - wird übersprungen."
        continue
    fi

    TARGET_DIR="${BASE_DIR}/${DOMAIN}"
    TARGET_FILE="${TARGET_DIR}/hosts.toml"

    if [[ "$DRY_RUN" == "1" ]]; then
        info "würde schreiben: $TARGET_FILE"
        continue
    fi

    mkdir -p "$TARGET_DIR"
    cat > "$TARGET_FILE" << EOF
server = "${UPSTREAM_SERVER}"

[host."${ZOT_ENDPOINT}/v2/${PREFIX}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOF
    chmod 644 "$TARGET_FILE"
    debug "hosts.toml geschrieben: $TARGET_FILE"
    success "  $DOMAIN → ${ZOT_ENDPOINT}/v2/${PREFIX} (Fallback: ${UPSTREAM_SERVER})"
done

# ==============================================================================
# Schritt 4: docker login
# ==============================================================================
echo ""
info "Schritt 4: bei Zot anmelden"

if [[ "$DO_LOGIN" != "1" ]]; then
    warning "docker login wurde übersprungen."
elif [[ "$DRY_RUN" == "1" ]]; then
    info "Trockenlauf: würde 'docker login $ZOT_HOST -u $ZOT_USER --password-stdin' ausführen."
else
    # Docker kann keine Browser-Weiterleitung fuer OpenID Connect. Zot akzeptiert
    # deshalb API-Tokens direkt via HTTP Basic Authentication. --password-stdin
    # haelt den Key aus Bash-History und Prozessliste heraus.
    info "Melde '$ZOT_HOST' als '$ZOT_USER' an ..."
    if printf '%s' "$ZOT_API_KEY" | docker login "$ZOT_HOST" -u "$ZOT_USER" --password-stdin; then
        success "docker login erfolgreich."
    else
        error "docker login fehlgeschlagen - pruefe Benutzername und API-Key."
    fi
fi

# Key aus dem Speicher freigeben
unset ZOT_API_KEY

# ==============================================================================
# Zusammenfassung
# ==============================================================================
echo ""
info "Fertig!"

if [[ "$DRY_RUN" == "1" ]]; then
    warning "Trockenlauf - es wurde nichts am System geaendert."
else
    echo ""
    echo -e "${C_GREEN}Konfigurierte Registries:${C_RESET}"
    for item in "${REGISTRIES[@]}"; do
        IFS="|" read -r DOMAIN UPSTREAM_SERVER PREFIX <<< "$item"
        echo "  • ${DOMAIN} → ${ZOT_ENDPOINT}/v2/${PREFIX}"
    done
    echo ""
    success "Kein Docker-Neustart erforderlich - containerd liest hosts.toml bei jedem Pull neu."
fi

echo ""
info "Verifikation"
echo "  1. Aktiven Image Store prüfen:"
echo "     docker info -f '{{ .DriverStatus }}'"
echo "  2. Konfiguration ansehen:"
echo "     cat ${BASE_DIR}/ghcr.io/hosts.toml"
echo "  3. Funktionstest (Zugangsdaten werden benötigt):"
echo "     docker pull ghcr.io/linuxserver/nginx:latest"
echo "     docker images | grep -i zot"
echo ""
info "Logdatei: $LOGFILE"
echo ""