#!/bin/bash
# ==============================================================================
# Modul: firewall
# ==============================================================================
# Konfiguriert und aktiviert die Firewall des Systems (ufw oder firewalld) und
# öffnet nur die_ports, die für die gewählte Rolle wirklich nötig sind.
#
# Der SSH-Port wird zuerst freigegeben und danach - falls er nicht 22 ist - der
# Standard-Port 22 ausdrücklich blockiert.
#
# Config:
#   FIREWALL_OPEN_WEB_PORTS  - 80/tcp und 443/tcp öffnen (Default true)
#   FIREWALL_HOSTS_PANGOLIN  - 51820/udp und 21820/udp öffnen (Default false)
#   FIREWALL_HOSTS_KOMODO    - 8120/tcp öffnen (Default false)
#   FIREWALL_EXTRA_PORTS     - weitere Ports, z. B. "51820/udp,21820/udp"
#   SSH_PORT                 - freizugebender SSH-Port (leer = aus sshd ermitteln)
# ==============================================================================

MODULE_ID="firewall"
MODULE_NAME="Firewall"
MODULE_DESC="Firewall (ufw/firewalld) konfigurieren und aktivieren"
MODULE_ORDER=70
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "netzwerk")

# Ermittelt den freizugebenden SSH-Port.
# Reihenfolge: Config -> laufende sshd-Konfiguration -> 22.
# In v3 kam der Port aus dem vorhergehenden SSH-Schritt; in v4 ist er eine
# eigene Config-Variable und muss deshalb hier selbst ermittelt werden.
# Achtung: Aufrufer hängen den Rückgabewert per $(...) ein - deshalb darf hier
# nichts ausgegeben werden, was nicht der Port ist.
fw_ssh_port() {
    local port=""

    port="$(config_get SSH_PORT)"

    if [ -z "$port" ] && [ -f "${SSH_CONFIG:-/etc/ssh/sshd_config}" ]; then
        port=$(grep -E "^Port[[:space:]]+" "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | tail -n1)
    fi

    if [ -z "$port" ]; then
        port=22
    fi

    echo "$port"
}

# Wandelt "51820/udp,21820/udp" in eine Liste von Port/Proto-Paaren.
# Ohne Angabe des Protokolls wird tcp angenommen.
fw_extra_ports_list() {
    local spec entry

    spec="$(config_get FIREWALL_EXTRA_PORTS)"
    [ -n "$spec" ] || return 0

    for entry in ${spec//,/ }; do
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        case "$entry" in
            */*) echo "$entry" ;;
            *)   echo "${entry}/tcp" ;;
        esac
    done
}

fw_configure_ufw() {
    local ssh_port="$1"
    local entry

    if ! command -v ufw >/dev/null 2>&1; then
        info "Installiere 'ufw' Paket..."
        install_package "ufw" || return 1
    fi

    info "Konfiguriere UFW-Firewall"

    # IPv6-Unterstützung in UFW aktivieren
    if [ -f /etc/default/ufw ]; then
        create_backup /etc/default/ufw
        run_eval "sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw"
        info "IPv6-Unterstützung in UFW aktiviert."
    fi

    run_eval "ufw default deny incoming"
    run_eval "ufw default allow outgoing"
    run_eval "ufw allow ${ssh_port}/tcp"
    if [ "$ssh_port" != "22" ]; then
        # Standard-SSH explizit blockieren, falls der SSH-Port nicht 22 ist
        run_eval "ufw deny 22/tcp"
    fi

    # Konditionale Regeln
    if config_bool FIREWALL_OPEN_WEB_PORTS; then
        run_eval "ufw allow 80/tcp"
        run_eval "ufw allow 443/tcp"
        info "Firewall: HTTP (80) und HTTPS (443) freigegeben."
    fi

    if config_bool FIREWALL_HOSTS_PANGOLIN; then
        run_eval "ufw allow 51820/udp"   # Pangolin VPN
        run_eval "ufw allow 21820/udp"   # Pangolin zusätzlich
        info "Firewall: Pangolin (51820/udp, 21820/udp) freigegeben."
    fi

    if config_bool FIREWALL_HOSTS_KOMODO; then
        run_eval "ufw allow 8120/tcp"    # Komodo
        info "Firewall: Komodo (8120/tcp) freigegeben."
    fi

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        run_eval "ufw allow ${entry}"
    done < <(fw_extra_ports_list)
    if [ -n "$(config_get FIREWALL_EXTRA_PORTS)" ]; then
        info "Firewall: Zusatzports freigegeben ($(config_get FIREWALL_EXTRA_PORTS))."
    fi

    run_eval "ufw --force enable"
    return 0
}

fw_configure_firewalld() {
    local ssh_port="$1"
    local entry

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        info "Installiere 'firewalld' Paket..."
        install_package "firewalld" || return 1
    fi

    info "Konfiguriere firewalld (Regeln gelten für IPv4 & IPv6)"

    manage_service enable firewalld
    manage_service start firewalld

    run_eval "firewall-cmd --permanent --remove-service=ssh"  # Standard SSH entfernen
    run_eval "firewall-cmd --permanent --add-port=${ssh_port}/tcp"

    # Konditionale Regeln
    if config_bool FIREWALL_OPEN_WEB_PORTS; then
        run_eval "firewall-cmd --permanent --add-service=http"
        run_eval "firewall-cmd --permanent --add-service=https"
        info "Firewall: HTTP und HTTPS (Services) freigegeben."
    fi

    if config_bool FIREWALL_HOSTS_PANGOLIN; then
        run_eval "firewall-cmd --permanent --add-port=51820/udp"  # Pangolin VPN
        run_eval "firewall-cmd --permanent --add-port=21820/udp"  # Pangolin zusätzlich
        info "Firewall: Pangolin (51820/udp, 21820/udp) freigegeben."
    fi

    if config_bool FIREWALL_HOSTS_KOMODO; then
        run_eval "firewall-cmd --permanent --add-port=8120/tcp"   # Komodo
        info "Firewall: Komodo (8120/tcp) freigegeben."
    fi

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        run_eval "firewall-cmd --permanent --add-port=${entry}"
    done < <(fw_extra_ports_list)
    if [ -n "$(config_get FIREWALL_EXTRA_PORTS)" ]; then
        info "Firewall: Zusatzports freigegeben ($(config_get FIREWALL_EXTRA_PORTS))."
    fi

    run_eval "firewall-cmd --reload"
    return 0
}

# Firewall-Funktionen je nach System (Port aus v3)
fw_configure() {
    local ssh_port="$1"

    info "Konfiguration der Firewall-Regeln..."

    case "$FIREWALL_CMD" in
        ufw)
            fw_configure_ufw "$ssh_port" || return 1
            ;;
        firewall-cmd)
            fw_configure_firewalld "$ssh_port" || return 1
            ;;
        *)
            warning "Unbekannte Firewall: $FIREWALL_CMD"
            return 1
            ;;
    esac

    return 0
}

module_main() {
    local ssh_port

    # In v3 wurde die Firewall nur innerhalb des Modul-Schalters konfiguriert.
    # In v4 entspricht die Modulauswahl dieser Entscheidung - die Rückfrage
    # "Soll die Firewall konfiguriert werden?" wäre damit doppelt.
    ssh_port="$(fw_ssh_port)"
    if [ -z "$(config_get SSH_PORT)" ]; then
        debug "SSH_PORT war nicht gesetzt - Wert $ssh_port wird verwendet"
    fi
    debug "Konfiguriere Firewall mit $FIREWALL_CMD, SSH-Port $ssh_port"

    if ! fw_configure "$ssh_port"; then
        error "Firewall-Konfiguration fehlgeschlagen"
        return 2
    fi

    success "Firewall ist aktiv und konfiguriert."

    echo ""
    info "Aktueller Firewall-Status:"
    case "$FIREWALL_CMD" in
        ufw)
            run_cmd ufw status verbose
            ;;
        firewall-cmd)
            run_cmd firewall-cmd --list-all
            ;;
    esac

    return 0
}

module_status() {
    local ssh_port
    ssh_port="$(fw_ssh_port)"

    case "$FIREWALL_CMD" in
        ufw)
            if ! command -v ufw >/dev/null 2>&1; then
                echo "ufw nicht installiert"
            elif ufw status 2>/dev/null | head -n1 | grep -qi "inactive"; then
                echo "ufw installiert, aber inaktiv (SSH-Port $ssh_port)"
            else
                echo "ufw aktiv (SSH-Port $ssh_port)"
            fi
            ;;
        firewall-cmd)
            if ! command -v firewall-cmd >/dev/null 2>&1; then
                echo "firewalld nicht installiert"
            elif firewall-cmd --state >/dev/null 2>&1; then
                echo "firewalld aktiv (SSH-Port $ssh_port)"
            else
                echo "firewalld gestoppt (SSH-Port $ssh_port)"
            fi
            ;;
        *)
            echo "unbekanntes Firewall-Backend: ${FIREWALL_CMD:-nicht ermittelt}"
            ;;
    esac
}