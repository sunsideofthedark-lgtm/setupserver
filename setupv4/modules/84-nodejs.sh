#!/bin/bash
# ==============================================================================
# Modul: nodejs
# ==============================================================================
# Installiert Node.js inklusive npm - auf Debian/Ubuntu und RHEL-Derivaten aus
# dem NodeSource-Repo, auf den uebrigen Distributionen das distributionsuebliche
# Paket.
#
# Wichtig: Es ist KEINE Version fest verdrahtet. Das Modul ermittelt die
# aktuellste LTS-Reihe und installiert genau die. Fest verdrahtet war
# 20.x - die ist seit April 2026 abgekaufen (EOL). NodeSource stellt dafuer
# den Alias "setup_lts.x" bereit, der serverseitig immer auf die aktuelle LTS
# zeigt. Als Kontrolle wird die LTS-Reihe aus nodejs.org/dist/index.json
# ermittelt - das ist die autoritative Liste.
#
# Ist bereits ein Node installiert, wird es angefasst, wenn es aelter als die
# aktuelle LTS ist (im interaktiven Lauf nach Rueckfrage). Mit NODEJS_MAJOR
# laesst sich eine bestimmte Reihe festnageln - etwa fuer Anwendungen, die
# auf einer aelteren LTS bleiben muessen.
#
# Config:
#   INSTALL_NODEJS - Node.js/npm installieren (Default false)
#   NODEJS_MAJOR   - Major-Version festnageln (z. B. "22"). Leer = aktuellste
#                    LTS (Default)
# ==============================================================================

MODULE_ID="nodejs"
MODULE_NAME="Node.js"
MODULE_DESC="Node.js und npm installieren (aktuellste LTS via NodeSource)"
MODULE_ORDER=84
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("software" "runtime")

# "base" gehoert zum System und laeuft immer mit, "software" ist
# installierbare Software und im Auswahlmenue waehlbar.
MODULE_CATEGORY="software"
MODULE_SWITCH="INSTALL_NODEJS"

# Ist die Zielversion festgenagelt? Dann wird auch ohne Rueckfrage aktualisiert.
NODEJS_PINNED=0

# Die Major-Version des installierten Node.js (leer = kein Node vorhanden).
node_installed_major() {
    local version major

    command -v node >/dev/null 2>&1 || return 0

    version="$(node --version 2>/dev/null | head -n1)"
    version="${version#v}"

    case "$version" in
        ''|*[!0-9.]*) return 0 ;;
    esac

    major="${version%%.*}"
    [ -n "$major" ] && printf '%s' "$major"
    return 0
}

# Die Ziel-Major-Version: entweder festgenagelt (NODEJS_MAJOR) oder die
# aktuellste LTS aus der offiziellen Liste.
#
# Liefert die Liste nichts (kein Netz, unerwartetes Format), bleibt die
# Version leer - dann loest der NodeSource-Alias "setup_lts.x" die Auswahl
# serverseitig auf.
node_target_major() {
    local pinned="${NODEJS_MAJOR:-}"
    local json major

    if [ -n "$pinned" ]; then
        if [[ "$pinned" =~ ^[0-9]+$ ]]; then
            NODEJS_PINNED=1
            printf '%s' "$pinned"
            return 0
        fi
        warning "NODEJS_MAJOR ist ungültig: '$pinned' - es wird die aktuelle LTS verwendet."
    fi

    NODEJS_PINNED=0

    json="$(curl -fsSL --max-time 20 https://nodejs.org/dist/index.json 2>/dev/null)" || json=""
    [ -n "$json" ] || return 0

    # Der erste Eintrag mit gesetztem "lts"-Feld ist die aktuellste LTS.
    major="$(printf '%s' "$json" | tr '{' '\n' \
        | grep -m1 '"lts":"' \
        | sed -E 's/.*"version":"v([0-9]+)\..*/\1/')"

    case "$major" in
        ''|*[!0-9]*) return 0 ;;
    esac

    printf '%s' "$major"
    return 0
}

node_install() {
    local major="$1"   # leer = ueber den NodeSource-Alias
    local script_url rpm_script_url

    if [ -n "$major" ]; then
        script_url="https://deb.nodesource.com/setup_${major}.x"
        rpm_script_url="https://rpm.nodesource.com/setup_${major}.x"
    else
        # Der Alias zeigt immer auf die aktuellste LTS.
        script_url="https://deb.nodesource.com/setup_lts.x"
        rpm_script_url="https://rpm.nodesource.com/setup_lts.x"
    fi

    case "$OS_ID" in
        ubuntu|debian)
            if [ -n "$major" ]; then
                info "Installiere Node.js ${major}.x LTS via NodeSource..."
            else
                info "Installiere die aktuellste Node.js LTS via NodeSource..."
            fi
            install_package "curl" || return 1
            run_eval "curl -fsSL ${script_url} | bash -" || return 1
            install_package "nodejs" || return 1
            ;;
        centos|rhel|rocky|almalinux)
            if [ -n "$major" ]; then
                info "Installiere Node.js ${major}.x LTS via NodeSource..."
            else
                info "Installiere die aktuellste Node.js LTS via NodeSource..."
            fi
            install_package "curl" || return 1
            run_eval "curl -fsSL ${rpm_script_url} | bash -" || return 1
            install_package "nodejs" || return 1
            ;;
        fedora)
            info "Installiere Node.js via dnf..."
            install_package "nodejs npm" || return 1
            ;;
        opensuse*|sles)
            if [ -n "$major" ]; then
                info "Installiere Node.js ${major}.x via zypper..."
                install_package "node${major} npm${major}" 2>/dev/null \
                    || install_package "nodejs npm" || return 1
            else
                info "Installiere Node.js via zypper..."
                install_package "nodejs npm" || return 1
            fi
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
    local installed_major="" target_major=""

    if ! module_switch_enabled INSTALL_NODEJS; then
        skip "Node.js ist nicht aktiviert (INSTALL_NODEJS=false)."
        return 1
    fi

    info "Prüfe Node.js/npm Installation..."

    installed_major="$(node_installed_major)"

    # Die Zielversion ermitteln. Ohne curl geht es nicht - dann bleibt die
    # Zahl leer und der NodeSource-Alias entscheidet.
    if command -v curl >/dev/null 2>&1; then
        target_major="$(node_target_major)"
    fi

    if [ -n "$installed_major" ]; then
        if [ -z "$target_major" ] || [ "$installed_major" -ge "$target_major" ]; then
            success "Node.js ist bereits installiert: $(node_version) / npm $(npm_version)"
            if [ -n "$target_major" ]; then
                info "Die aktuelle LTS ist ${target_major}.x - die vorhandene Version ist aktuell."
            fi
            return 0
        fi

        # Aelter als die aktuelle LTS.
        warning "Node.js $(node_version) ist installiert, die aktuelle LTS ist ${target_major}.x."
        if [ "$NODEJS_PINNED" = "0" ] && [ "$NON_INTERACTIVE" = "1" ]; then
            info "Nicht-interaktiver Modus - es wird nicht automatisch aktualisiert."
            echo "     Gezielt aktualisieren: --set NODEJS_MAJOR=${target_major}"
            return 1
        fi
        if [ "$NODEJS_PINNED" = "0" ]; then
            if ! ask_yes_no "Auf die aktuelle LTS (${target_major}.x) aktualisieren?" "y"; then
                skip "Node.js bleibt auf $(node_version)."
                return 0
            fi
        else
            info "NODEJS_MAJOR=${target_major} ist festgelegt - es wird aktualisiert."
        fi
    fi

    if [ -n "$target_major" ]; then
        info "Installiere Node.js ${target_major}.x (aktuelle LTS) und npm..."
    else
        info "Installiere die aktuellste Node.js LTS und npm..."
    fi
    debug "Starte Node.js Installation"
    log_action "NODEJS" "Starting automatic Node.js/npm installation"

    node_install "$target_major"

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

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local installed_major="" target_major=""

    if ! module_switch_enabled INSTALL_NODEJS; then
        echo "info|Node.js nicht angefordert|INSTALL_NODEJS ist nicht gesetzt"
        return 0
    fi

    installed_major="$(node_installed_major)"

    if [ -n "$installed_major" ] && command -v curl >/dev/null 2>&1; then
        target_major="$(node_target_major)"
    fi

    if [ -z "$installed_major" ]; then
        echo "abweichung|INSTALL_NODEJS ist gesetzt, keine Installation vorhanden|node und npm fehlen"
        return 0
    fi

    if command -v npm >/dev/null 2>&1; then
        if [ -n "$target_major" ] && [ "$installed_major" -lt "$target_major" ]; then
            echo "abweichung|node $(node_version), aktuelle LTS ist ${target_major}.x|node veraltet"
            return 0
        fi
        echo "ok|node $(node_version) / npm $(npm_version)"
        return 0
    fi

    echo "abweichung|node $(node_version) ist da, npm nicht im PATH - INSTALL_NODEJS ist gesetzt|npm fehlt"
    return 0
}
