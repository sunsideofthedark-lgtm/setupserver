#!/bin/bash
# ==============================================================================
# Modul: nginx
# ==============================================================================
# Installiert den NGINX-Webserver und aktiviert ihn. Ist CrowdSec vorhanden,
# wird zusätzlich die passende NGINX-Collection eingerichtet.
#
# Hinweis: Die eigentliche Webserver-Konfiguration (vhosts, Zertifikate) ist
# nicht Teil dieses Moduls - hier wird nur die Basisinstallation gemacht.
#
# Config:
#   INSTALL_NGINX - NGINX installieren und starten (Default false)
# ==============================================================================

MODULE_ID="nginx"
MODULE_NAME="NGINX Webserver"
MODULE_DESC="Installiert und aktiviert den NGINX-Webserver"
MODULE_ORDER=89
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("web")

module_main() {
    if ! config_bool INSTALL_NGINX; then
        skip "INSTALL_NGINX ist nicht gesetzt - NGINX wird nicht angefasst."
        return 1
    fi

    echo ""
    info "Installiere NGINX Webserver..."

    if ! is_package_installed "nginx" "nginx"; then
        if ! install_package "nginx"; then
            return 2
        fi

        manage_service enable nginx
        manage_service start nginx
        success "NGINX installiert und gestartet."
    else
        warning "NGINX ist bereits installiert."
    fi

    # --- CrowdSec-Hooks: nur wenn auf dem Server auch CrowdSec läuft ---
    if command -v cscli >/dev/null 2>&1; then
        info "Füge CrowdSec Nginx-Collection hinzu..."
        if [ "$DRY_RUN" = "1" ]; then
            echo -e "${C_MAGENTA}[DRY-RUN] cscli collections install crowdsecurity/nginx${C_RESET}" >&2
        elif cscli collections install crowdsecurity/nginx 2>/dev/null; then
            debug "Collection installiert: crowdsecurity/nginx"
        else
            warning "Collection crowdsecurity/nginx konnte nicht installiert werden."
        fi
        manage_service reload crowdsec 2>/dev/null || true
    fi

    return 0
}

module_status() {
    if ! command -v nginx >/dev/null 2>&1; then
        echo "nicht installiert"
        return 0
    fi

    local version active="inaktiv"
    version="$(nginx -v 2>&1 | sed 's|.*nginx/||')"
    systemctl is-active --quiet nginx 2>/dev/null && active="aktiv"

    echo "Version ${version}, ${active}"
}