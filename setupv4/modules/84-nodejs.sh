#!/bin/bash
# ==============================================================================
# Modul: nodejs
# ==============================================================================
# Installiert Node.js inklusive npm. Auf Debian/Ubuntu und RHEL-Derivaten kommt
# die aktuelle 20.x-LTS-Reihe von NodeSource, auf den übrigen Distributionen
# das distributionsübliche Paket.
#
# Ein vorhandenes Node.js wird nicht angefasst - die Module anderer Komponenten
# nutzen eine vorhandene Installation unabhängig von der Quelle.
#
# Config:
#   INSTALL_NODEJS - Node.js/npm installieren (Default false)
# ==============================================================================

MODULE_ID="nodejs"
MODULE_NAME="Node.js"
MODULE_DESC="Node.js und npm installieren (20.x LTS via NodeSource)"
MODULE_ORDER=84
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("software" "runtime")

node_install() {
    case "$OS_ID" in
        ubuntu|debian)
            info "Installiere Node.js 20.x LTS via NodeSource..."
            install_package "curl" || return 1
            run_eval "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -" || return 1
            install_package "nodejs" || return 1
            ;;
        centos|rhel|rocky|almalinux)
            info "Installiere Node.js 20.x LTS via NodeSource..."
            install_package "curl" || return 1
            run_eval "curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -" || return 1
            install_package "nodejs" || return 1
            ;;
        fedora)
            info "Installiere Node.js via dnf..."
            install_package "nodejs npm" || return 1
            ;;
        opensuse*|sles)
            info "Installiere Node.js via zypper..."
            install_package "nodejs20 npm20" 2>/dev/null || install_package "nodejs npm" || return 1
            ;;
        arch)
            info "Installiere Node.js via pacman..."
            install_package "nodejs npm" || return 1
            ;;
        *)
            warning "Kein spezielles Repo für $OS_ID. Versuche Standard-Paket."
            install_package "nodejs npm" || install_package "nodejs" || return 1
            ;;
    esac

    return 0
}

# node und npm koennen aus getrennten Quellen stammen, und ein vorhandenes
# Binary liefert nicht immer eine Versionszeile (z. B. ein Windows-Stub im
# PATH unter WSL). Deshalb wird nur die erste Zeile ausgewertet und auf das
# erwartete Muster geprueft - so bleibt die Statuszeile einzeilig.
node_version() {
    local version
    version="$(node --version 2>/dev/null | head -n1)"
    if [[ "$version" == v* ]]; then
        echo "$version"
    else
        echo "nicht abfragbar"
    fi
}

npm_version() {
    local version
    version="$(npm --version 2>/dev/null | head -n1)"
    if [[ "$version" =~ ^[0-9] ]]; then
        echo "$version"
    else
        echo "nicht abfragbar"
    fi
}

module_main() {
    if ! config_bool INSTALL_NODEJS; then
        skip "Node.js ist nicht aktiviert (INSTALL_NODEJS=false)."
        return 1
    fi

    info "Prüfe Node.js/npm Installation..."

    if command -v npm >/dev/null 2>&1; then
        success "Node.js/npm ist bereits installiert: $(node_version) / npm $(npm_version)"
        return 0
    fi

    info "Installiere Node.js und npm automatisch..."
    debug "Starte Node.js Installation"
    log_action "NODEJS" "Starting automatic Node.js/npm installation"

    node_install

    if command -v npm >/dev/null 2>&1; then
        success "✅ Node.js installiert: $(node_version)"
        success "✅ npm installiert: $(npm_version)"
        log_action "NODEJS" "Node.js/npm installed successfully"
        return 0
    fi

    error "Node.js/npm Installation fehlgeschlagen"
    log_action "NODEJS" "Installation failed"
    return 2
}

module_status() {
    if command -v npm >/dev/null 2>&1; then
        echo "node $(node_version) / npm $(npm_version)"
    else
        echo "nicht installiert"
    fi
}