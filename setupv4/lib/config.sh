#!/bin/bash
# ==============================================================================
# setupv4/lib/config.sh - Konfiguration laden, mergen, validieren
# ==============================================================================
# Die Konfiguration ist eine Shell-.conf, die gesourct wird. Damit können
# Bedingungen, Listen und Schleifen verwendet werden, z. B.:
#
#   if [[ "$ROLE" == "web" ]]; then
#       NGINX=true
#   fi
#
# Ladereihenfolge (spätere Definition gewinnt):
#   1. Defaults aus dieser Datei
#   2. Umgebungsvariablen (z. B. ZOT_API_KEY) - überschreiben nur die Defaults
#   3. config/setup.conf
#   4. config/servers/<hostname>.conf  (Server-Profil, falls vorhanden)
#   5. --set KEY=WERT Argumente der Kommandozeile
# ==============================================================================

CONFIG_FILE=""
CONFIG_LOADED=false
CONFIG_FILES_LOADED=()

# Alle Schlüssel, die eine Konfiguration setzen darf. Wird gegen die tatsächlich
# in der Datei vorkommenden Zuweisungen geprüft, damit Tippfehler wie
# "INSAL_DOCKER=true" nicht stillschweigend ins Leere laufen.
# Der Test tests/test-modules.sh gleicht diese Liste mit den Defaults aus
# config_set_defaults() ab - neue Defaults müssen hier ergänzt werden.
CONFIG_KNOWN_KEYS=(
    MODULES
    SETUP_ROLE SERVER_ROLE SERVER_HOSTNAME TIMEZONE ADMIN_USER BACKUP_DIR
    DISABLE_ROOT_LOGIN REBOOT_AT_END
    SYSTEM_UPDATE AUTO_UPDATES SET_HOSTNAME SET_TIMEZONE
    SSH_PORT SSH_ALLOWED_USERS SSH_KEY_TYPE
    CREATE_BACKUP_USER DB_BACKUP_USER CREATE_SHARED_DIR SHARED_DIR SHARED_GROUP
    SFTP_SUDOERS
    FIREWALL_OPEN_WEB_PORTS FIREWALL_HOSTS_PANGOLIN FIREWALL_HOSTS_KOMODO
    FIREWALL_EXTRA_PORTS
    INSTALL_DOCKER INSTALL_NODEJS INSTALL_TAILSCALE INSTALL_ZFS_ARC
    INSTALL_NGINX INSTALL_FAIL2BAN INSTALL_CROWDSEC INSTALL_NODE_EXPORTER
    INSTALL_NCUDU INSTALL_HTOP INSTALL_IOTOP INSTALL_NETHOGS INSTALL_TMUX
    INSTALL_GIT INSTALL_ZIP INSTALL_DB_CLIENTS INSTALL_CLAMAV INSTALL_NETBIRD
    NETBIRD_MGMT_URL NETBIRD_SETUP_KEY NETBIRD_CONFIGURE
    INSTALL_KOMODO KOMODO_PASSKEY KOMODO_ENDPOINT
    INSTALL_PANGOLIN PANGOLIN_SPK
    INSTALL_GITHUB_SSH GITHUB_USERNAME GITHUB_EMAIL GITHUB_USE_CLI
    ZOT_MIRRORS ZOT_ENDPOINT ZOT_USERNAME ZOT_API_KEY ZOT_DOCKER_LOGIN
    MAINTENANCE_DAILY_BACKUP MAINTENANCE_DISK_MONITOR MAINTENANCE_LOGROTATE
    TUNING_SYSCTL TUNING_SWAP TUNING_SWAP_SIZE TUNING_JOURNALD TUNING_JOURNALD_MAXUSE
)

# --- Defaults ---
# Das Muster "${VAR:-wert}" sorgt dafür, dass Werte aus der Umgebung
# (z. B. ZOT_API_KEY=... sudo -E bash setup.sh) die Defaults überschreiben,
# aber nicht von der Config-Datei wieder gelöscht werden.
config_set_defaults() {
    # --- Allgemein ---
    SETUP_ROLE="${SETUP_ROLE:-standard}"
    ADMIN_USER="${ADMIN_USER:-}"
    SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
    TIMEZONE="${TIMEZONE:-}"
    SERVER_ROLE="${SERVER_ROLE:-}"
    BACKUP_DIR="${BACKUP_DIR:-/var/backups/serversetup}"
    DISABLE_ROOT_LOGIN="${DISABLE_ROOT_LOGIN:-true}"
    REBOOT_AT_END="${REBOOT_AT_END:-false}"

    # --- Modulschalter: Basissystem ---
    SYSTEM_UPDATE="${SYSTEM_UPDATE:-true}"
    AUTO_UPDATES="${AUTO_UPDATES:-true}"
    SET_HOSTNAME="${SET_HOSTNAME:-true}"
    SET_TIMEZONE="${SET_TIMEZONE:-true}"

    # --- SSH ---
    SSH_PORT="${SSH_PORT:-}"
    SSH_ALLOWED_USERS="${SSH_ALLOWED_USERS:-}"
    SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"

    # --- Benutzerverwaltung ---
    CREATE_BACKUP_USER="${CREATE_BACKUP_USER:-false}"
    DB_BACKUP_USER="${DB_BACKUP_USER:-dbbackup}"
    CREATE_SHARED_DIR="${CREATE_SHARED_DIR:-false}"
    SHARED_DIR="${SHARED_DIR:-/opt}"
    SHARED_GROUP="${SHARED_GROUP:-opt-admins}"
    SFTP_SUDOERS="${SFTP_SUDOERS:-false}"

    # --- Firewall ---
    FIREWALL_OPEN_WEB_PORTS="${FIREWALL_OPEN_WEB_PORTS:-true}"
    FIREWALL_HOSTS_PANGOLIN="${FIREWALL_HOSTS_PANGOLIN:-false}"
    FIREWALL_HOSTS_KOMODO="${FIREWALL_HOSTS_KOMODO:-false}"
    FIREWALL_EXTRA_PORTS="${FIREWALL_EXTRA_PORTS:-}"

    # --- Software ---
    INSTALL_DOCKER="${INSTALL_DOCKER:-false}"
    INSTALL_NODEJS="${INSTALL_NODEJS:-false}"
    INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-false}"
    INSTALL_ZFS_ARC="${INSTALL_ZFS_ARC:-false}"
    INSTALL_NGINX="${INSTALL_NGINX:-false}"
    INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-false}"
    INSTALL_CROWDSEC="${INSTALL_CROWDSEC:-false}"
    INSTALL_NODE_EXPORTER="${INSTALL_NODE_EXPORTER:-false}"
    INSTALL_NCUDU="${INSTALL_NCUDU:-false}"
    INSTALL_HTOP="${INSTALL_HTOP:-false}"
    INSTALL_IOTOP="${INSTALL_IOTOP:-false}"
    INSTALL_NETHOGS="${INSTALL_NETHOGS:-false}"
    INSTALL_TMUX="${INSTALL_TMUX:-false}"
    INSTALL_GIT="${INSTALL_GIT:-false}"
    INSTALL_ZIP="${INSTALL_ZIP:-false}"
    INSTALL_DB_CLIENTS="${INSTALL_DB_CLIENTS:-false}"
    INSTALL_CLAMAV="${INSTALL_CLAMAV:-false}"
    INSTALL_NETBIRD="${INSTALL_NETBIRD:-false}"
    NETBIRD_MGMT_URL="${NETBIRD_MGMT_URL:-}"
    NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"
    NETBIRD_CONFIGURE="${NETBIRD_CONFIGURE:-false}"
    INSTALL_KOMODO="${INSTALL_KOMODO:-false}"
    KOMODO_PASSKEY="${KOMODO_PASSKEY:-}"
    KOMODO_ENDPOINT="${KOMODO_ENDPOINT:-}"
    INSTALL_PANGOLIN="${INSTALL_PANGOLIN:-false}"
    PANGOLIN_SPK="${PANGOLIN_SPK:-}"
    INSTALL_GITHUB_SSH="${INSTALL_GITHUB_SSH:-false}"
    GITHUB_USERNAME="${GITHUB_USERNAME:-}"
    GITHUB_EMAIL="${GITHUB_EMAIL:-}"
    GITHUB_USE_CLI="${GITHUB_USE_CLI:-true}"

    # --- Zot-Mirrors ---
    ZOT_MIRRORS="${ZOT_MIRRORS:-false}"
    ZOT_ENDPOINT="${ZOT_ENDPOINT:-https://zot.sunriseing.dev}"
    ZOT_USERNAME="${ZOT_USERNAME:-admin}"
    ZOT_API_KEY="${ZOT_API_KEY:-}"
    ZOT_DOCKER_LOGIN="${ZOT_DOCKER_LOGIN:-true}"

    # --- Wartung ---
    MAINTENANCE_DAILY_BACKUP="${MAINTENANCE_DAILY_BACKUP:-false}"
    MAINTENANCE_DISK_MONITOR="${MAINTENANCE_DISK_MONITOR:-true}"
    MAINTENANCE_LOGROTATE="${MAINTENANCE_LOGROTATE:-true}"

    # --- System-Tuning (Modul tuning) ---
    TUNING_SYSCTL="${TUNING_SYSCTL:-true}"
    TUNING_SWAP="${TUNING_SWAP:-true}"
    TUNING_SWAP_SIZE="${TUNING_SWAP_SIZE:-2G}"
    TUNING_JOURNALD="${TUNING_JOURNALD:-true}"
    TUNING_JOURNALD_MAXUSE="${TUNING_JOURNALD_MAXUSE:-200M}"

    # MODULES darf aus der Umgebung kommen, sonst leer
    if [ -z "${MODULES+x}" ]; then
        MODULES=()
    fi
}

# --- Laden ---
config_load() {
    local file="$1"

    if [ ! -f "$file" ]; then
        error "Config-Datei nicht gefunden: $file"
        return 1
    fi

    # Eine nicht von root besessene Config könnte beliebigen Code einschleusen
    if [ "$(stat -c '%U' "$file" 2>/dev/null)" != "root" ] && [ -w "$file" ]; then
        warning "Config '$file' ist nicht im Besitz von root - bitte Rechte prüfen."
    fi

    debug "Lade Config: $file"
    # shellcheck disable=SC1090
    . "$file" || {
        error "Config '$file' konnte nicht gelesen werden (Syntaxfehler?)."
        return 1
    }

    CONFIG_FILE="$file"
    CONFIG_LOADED=true
    CONFIG_FILES_LOADED+=("$file")
    success "Config geladen: $file"

    config_check_unknown_keys "$file"
}

# Prüft die in der Datei vorkommenden Zuweisungen gegen CONFIG_KNOWN_KEYS.
# Unbekannte Namen sind fast immer Tippfehler - ein stillschweigend
# wirkungsloser Schalter wäre bei einer Config für mehrere Server die
# ungünstigste Eigenschaft des ganzen Systems.
config_check_unknown_keys() {
    local file="$1"
    local assignments key

    assignments=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$file" 2>/dev/null \
        | sed -E 's/^[[:space:]]*//; s/^export[[:space:]]+//; s/=$//' \
        | sort -u)

    [ -z "$assignments" ] && return 0

    for key in $assignments; do
        if ! config_is_known_key "$key"; then
            warning "Unbekannter Config-Schlüssel in $file: '$key'"
            echo "     Der Schalter wird ignoriert. Prüfe die Schreibweise."
        fi
    done

    return 0
}

config_is_known_key() {
    local wanted="$1"
    local key
    for key in "${CONFIG_KNOWN_KEYS[@]}"; do
        [ "$key" = "$wanted" ] && return 0
    done
    return 1
}

# Lädt zusätzlich ein Server-Profil config/servers/<hostname>.conf
config_load_host_profile() {
    local servers_dir="$1"
    local hostname_short profile
    hostname_short=$(hostname -s 2>/dev/null || hostname)
    profile="$servers_dir/${hostname_short}.conf"

    if [ -f "$profile" ]; then
        info "Server-Profil gefunden: $profile"
        config_load "$profile"
    else
        debug "Kein Server-Profil für '$hostname_short' (erwartet: $profile)"
    fi
}

# --- Zugriff ---
config_get() {
    local key="$1"
    local default_value="${2:-}"
    local value="${!key:-}"

    if [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

# Gibt 0 zurück, wenn eine Boolesche Config true/1/yes/on ist
config_bool() {
    local key="$1"
    local default_value="${2:-false}"
    local value="${!key:-$default_value}"

    case "$(echo "$value" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on|y) return 0 ;;
        *) return 1 ;;
    esac
}

# Ist das Modul mit der angegebenen ID aktiviert?
config_module_enabled() {
    local module_id="$1"
    local key="MODULE_${module_id//-/_}"
    local value="${!key:-}"

    if [ -n "$value" ]; then
        config_bool "$key"
        return $?
    fi

    local m
    [ ${#MODULES[@]} -gt 0 ] || return 1
    for m in "${MODULES[@]}"; do
        [ "$m" = "$module_id" ] && return 0
    done

    return 1
}

# --- Validierung ---
config_validate() {
    local errors=0

    if [ -n "$SERVER_HOSTNAME" ] && ! validate_hostname "$SERVER_HOSTNAME"; then
        error "SERVER_HOSTNAME ist ungültig: '$SERVER_HOSTNAME' (erlaubt: Buchstaben, Ziffern, Bindestrich, max. 63 Zeichen)"
        errors=$((errors + 1))
    fi

    if [ -n "$SSH_PORT" ] && ! validate_port "$SSH_PORT"; then
        error "SSH_PORT ist ungültig: '$SSH_PORT' (erlaubt: 1-65535)"
        errors=$((errors + 1))
    fi

    if [ -n "$ADMIN_USER" ] && ! validate_username "$ADMIN_USER"; then
        error "ADMIN_USER ist ungültig: '$ADMIN_USER'"
        errors=$((errors + 1))
    fi

    if [ -n "$TIMEZONE" ]; then
        if [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ] && [ ! -f "/etc/zoneinfo/$TIMEZONE" ]; then
            error "TIMEZONE ist unbekannt: '$TIMEZONE' (z. B. Europe/Vienna)"
            errors=$((errors + 1))
        fi
    fi

    if [ -n "$FIREWALL_EXTRA_PORTS" ]; then
        local port portnum
        for port in ${FIREWALL_EXTRA_PORTS//,/ }; do
            portnum="${port%%/*}"
            if ! validate_port "$portnum"; then
                error "FIREWALL_EXTRA_PORTS enthält einen ungültigen Port: '$port'"
                errors=$((errors + 1))
            fi
        done
    fi

    return $errors
}

# --- Ausgabe ---
config_summary() {
    info "Wirksame Konfiguration:"
    if [ ${#CONFIG_FILES_LOADED[@]} -gt 0 ]; then
        local f
        for f in "${CONFIG_FILES_LOADED[@]}"; do
            echo "     Quelle: $f"
        done
    else
        echo "     Quelle: nur Defaults (keine Config-Datei geladen)"
    fi

    local key value
    for key in SETUP_ROLE SERVER_ROLE SERVER_HOSTNAME TIMEZONE ADMIN_USER SSH_PORT \
               DISABLE_ROOT_LOGIN INSTALL_DOCKER INSTALL_NODEJS INSTALL_NGINX \
               INSTALL_FAIL2BAN INSTALL_CROWDSEC INSTALL_NETBIRD INSTALL_TAILSCALE \
               INSTALL_KOMODO INSTALL_PANGOLIN INSTALL_GITHUB_SSH INSTALL_CLAMAV \
               CREATE_BACKUP_USER CREATE_SHARED_DIR SFTP_SUDOERS ZOT_MIRRORS \
               ZOT_ENDPOINT MAINTENANCE_DISK_MONITOR REBOOT_AT_END; do
        value="${!key:-}"
        [ -z "$value" ] && continue
        echo "     ${key}=${value}"
    done

    if [ -n "$ZOT_API_KEY" ]; then
        echo "     ZOT_API_KEY=$(mask_secret "$ZOT_API_KEY") (gesetzt)"
    fi
}

# --- Beispielkonfiguration erzeugen ---
config_write_example() {
    local target="$1"

    if [ -f "$target" ]; then
        warning "Datei existiert bereits, wird nicht überschrieben: $target"
        info "Zum Neuerzeugen zuerst entfernen: rm $target"
        return 1
    fi

    mkdir -p "$(dirname "$target")" 2>/dev/null || true

    # Modulliste dynamisch aus der Discovery holen
    local module_list=""
    if [ ${#AVAILABLE_MODULES[@]} -gt 0 ]; then
        module_list=$(printf '%s\n' "${AVAILABLE_MODULES[@]}" | cut -d'|' -f2 | sed 's/^/    /')
    fi
    [ -z "$module_list" ] && module_list="    # keine Module gefunden"

    cat > "$target" << CONFEOF
# ==============================================================================
# setupv4 - Beispielkonfiguration
# ==============================================================================
# Diese Datei ist normales Bash und wird gesourct - Bedingungen, Schleifen und
# Variablen sind erlaubt. Einfach kopieren und anpassen:
#
#   cp config/setup.conf.example config/setup.conf
#
# Pro Server lässt sich zusätzlich config/servers/<hostname>.conf anlegen,
# die nach dieser Datei geladen wird und deren Werte gewinnen.
# ==============================================================================

# Welche Module laufen sollen (Reihenfolge = Ausführungsreihenfolge).
# Entfernen = Modul überspringen.
MODULES=(
$module_list
)

# --- Allgemein ---
SETUP_ROLE="standard"
SERVER_HOSTNAME=""            # leer = aktuellen Hostnamen behalten
TIMEZONE="Europe/Vienna"
DISABLE_ROOT_LOGIN=true
REBOOT_AT_END=false

# --- SSH ---
SSH_PORT=2222
SSH_ALLOWED_USERS=""          # z. B. "sugo,deploy"

# --- Benutzerverwaltung ---
CREATE_BACKUP_USER=false
DB_BACKUP_USER="dbbackup"
CREATE_SHARED_DIR=false
# NOPASSWD-Regel fuer den sftp-server. Beachten: wer den SSH-Key haelt, kann
# dann alle Dateien per SFTP als root lesen/schreiben/loeschen. Nur setzen,
# wenn das eingesetzte Backup-Tool die sudo-Variante wirklich braucht.
SFTP_SUDOERS=false

# --- Firewall ---
FIREWALL_OPEN_WEB_PORTS=true
FIREWALL_HOSTS_PANGOLIN=false
FIREWALL_HOSTS_KOMODO=false
FIREWALL_EXTRA_PORTS=""       # z. B. "51820/udp,21820/udp"

# --- Software ---
INSTALL_DOCKER=true
INSTALL_NODEJS=false
INSTALL_NGINX=false
INSTALL_FAIL2BAN=true
INSTALL_CROWDSEC=false
INSTALL_NETBIRD=false
INSTALL_TAILSCALE=false
INSTALL_KOMODO=false
INSTALL_PANGOLIN=false
INSTALL_GITHUB_SSH=false
INSTALL_CLAMAV=false

# --- Zot-Mirrors ---
ZOT_MIRRORS=false
ZOT_ENDPOINT="https://zot.sunriseing.dev"
ZOT_USERNAME="admin"
# API-Key NICHT hier zuweisen - eine leere Zuweisung wuerde den Wert aus der
# Umgebung wieder ueberschreiben. Stattdessen zur Laufzeit uebergeben:
#   ZOT_API_KEY=... sudo -E bash setup.sh --config config/setup.conf
# oder via --set ZOT_API_KEY=...
#ZOT_API_KEY=""

# --- Beispiel:bedingte Konfiguration ---
# if [[ "\$SETUP_ROLE" == "web" ]]; then
#     INSTALL_NGINX=true
#     FIREWALL_OPEN_WEB_PORTS=true
# fi
# if [[ "\$SETUP_ROLE" == "pangolin" ]]; then
#     FIREWALL_EXTRA_PORTS="51820/udp,21820/udp"
# fi
CONFEOF

    success "Beispielkonfiguration erstellt: $target"
    info "Vor dem ersten Lauf anpassen, dann:"
    info "  sudo bash setup.sh --config $target"
}