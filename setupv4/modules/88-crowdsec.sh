#!/bin/bash
# ==============================================================================
# Modul: crowdsec
# ==============================================================================
# Installiert die CrowdSec Security Engine samt Firewall-Bouncer und richtet die
# Collections ein, die auf diesem Server Sinn ergeben (Docker, NGINX).
#
# Hinweis: Der Firewall-Bouncer ist distributionabhängig. Der Paketname
# "crowdsec-firewall-bouncer-iptables" existiert auf Debian/Ubuntu; auf
# RPM-Distributionen muss der Bouncer über das CrowdSec-Repository bezogen
# werden. Ein Fehlschlag wird deshalb wie im Original nur gemeldet und nicht
# zum Abbruch des Moduls geführt.
#
# Config:
#   INSTALL_CROWDSEC - CrowdSec installieren/konfigurieren (Default false)
# ==============================================================================

MODULE_ID="crowdsec"
MODULE_NAME="CrowdSec"
MODULE_DESC="Installiert CrowdSec Security Engine mit Firewall-Bouncer und Collections"
MODULE_ORDER=88
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit")

CROWDSEC_INSTALL_URL="https://install.crowdsec.net"

# Installiert eine Collection - ein Fehlschlag ist nicht kritisch, die Engine
# läuft auch ohne sie. Deshalb wird das Ergebnis nur protokolliert.
crowdsec_install_collection() {
    local collection="$1"

    if ! command -v cscli >/dev/null 2>&1; then
        debug "cscli nicht vorhanden - Collection ${collection} wird übersprungen."
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] cscli collections install ${collection}${C_RESET}" >&2
        return 0
    fi

    if cscli collections install "$collection" 2>/dev/null; then
        debug "Collection installiert: ${collection}"
        return 0
    fi

    warning "Collection konnte nicht installiert werden: ${collection}"
    return 1
}

module_main() {
    local docker_collection=0

    if ! config_bool INSTALL_CROWDSEC; then
        skip "INSTALL_CROWDSEC ist nicht gesetzt - CrowdSec wird nicht angefasst."
        return 1
    fi

    echo ""
    info "Installiere CrowdSec Security Engine..."
    log_action "CROWDSEC" "Starting CrowdSec installation"

    if ! is_package_installed "crowdsec" "crowdsec"; then
        # --- Neuinstallation ---
        info "Füge CrowdSec Repository hinzu..."

        if ! install_package "curl"; then
            return 2
        fi

        if [ "$DRY_RUN" = "1" ]; then
            echo -e "${C_MAGENTA}[DRY-RUN] curl -s ${CROWDSEC_INSTALL_URL} | sh${C_RESET}" >&2
        elif ! run_eval "curl -s '${CROWDSEC_INSTALL_URL}' | sh"; then
            error "Installation über ${CROWDSEC_INSTALL_URL} fehlgeschlagen."
            log_action "CROWDSEC" "Repository installation failed"
            return 2
        fi

        run_eval "$PKG_UPDATE" || true

        info "Installiere CrowdSec Security Engine und Firewall-Bouncer..."
        if ! install_package "crowdsec"; then
            log_action "CROWDSEC" "Installation of crowdsec failed"
            return 2
        fi

        # Fehlschlag ist nicht fatal - die Engine läuft auch ohne Bouncer
        install_package "crowdsec-firewall-bouncer-iptables" || \
            warning "Firewall-Bouncer konnte nicht als Paket installiert werden (RPM-Distribution?)."

        manage_service enable crowdsec 2>/dev/null || true
        manage_service start crowdsec 2>/dev/null || true

        # --- Collections installieren ---
        if command -v cscli >/dev/null 2>&1; then
            info "Installiere CrowdSec Collections..."
            if command -v docker >/dev/null 2>&1; then
                info "Installiere crowdsecurity/docker Collection..."
                crowdsec_install_collection "crowdsecurity/docker"
                docker_collection=1
            fi
            if is_package_installed "nginx" "nginx"; then
                info "Installiere crowdsecurity/nginx Collection..."
                crowdsec_install_collection "crowdsecurity/nginx"
            fi
            manage_service reload crowdsec 2>/dev/null || true
        fi

        success "✅ CrowdSec und Firewall-Bouncer erfolgreich installiert und konfiguriert."
        log_action "CROWDSEC" "CrowdSec installed successfully"
    else
        # --- CrowdSec ist bereits vorhanden ---
        warning "CrowdSec ist bereits installiert."

        if command -v cscli >/dev/null 2>&1; then
            if command -v docker >/dev/null 2>&1; then
                crowdsec_install_collection "crowdsecurity/docker"
                docker_collection=1
            fi
            manage_service reload crowdsec 2>/dev/null || true
        fi
    fi

    if [ "$docker_collection" = "1" ]; then
        debug "Docker-Collection eingerichtet"
    fi

    return 0
}

module_status() {
    if ! command -v cscli >/dev/null 2>&1; then
        echo "nicht installiert"
        return 0
    fi

    local collections="-"
    collections="$(cscli collections list -o raw 2>/dev/null | grep -c '^crowdsecurity/')"
    [ -z "$collections" ] && collections="0"

    echo "installiert, ${collections} CrowdSec-Collections"
}