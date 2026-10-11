#!/bin/bash
# ==============================================================================
# Modul: netbird
# ==============================================================================
# Installiert NetBird (WireGuard-basiertes Overlay-Netz) und bindet den Server
# an einen Management-Server an - NetBird Cloud oder einen eigenen.
#
# Enthält zusätzlich die Stilllegung eines alten Tailscale-Aufbaus. In v3 lief
# dieser Block bedingungslos innerhalb der optionalen Software. In v4 ist er an
# INSTALL_TAILSCALE gebunden: der Schalter steht für "Tailscale soll durch
# NetBird ersetzt werden". So bleibt ein Tailscale-Setup unangetastet, wenn das
# Modul nur wegen NetBird ausgewählt wurde.
#
# Die Menüstruktur für weitere Softwarepakete aus v3 ist hier bewusst NICHT
# enthalten - jedes dieser Pakete ist in v4 ein eigenes Modul.
#
# Config:
#   INSTALL_NETBIRD     - NetBird installieren (Default false)
#   INSTALL_TAILSCALE   - altes Tailscale stilllegen (Default false)
#   NETBIRD_CONFIGURE   - Verbindung nach der Installation einrichten (Default false)
#   NETBIRD_MGMT_URL    - Management-URL (leer = NetBird Cloud / Nachfrage)
#   NETBIRD_SETUP_KEY   - Setup-Key; Secret, besser über Umgebung oder --set
# ==============================================================================

MODULE_ID="netbird"
MODULE_NAME="NetBird"
MODULE_DESC="NetBird installieren und an einen Management-Server anbinden"
MODULE_ORDER=86
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("netzwerk" "vpn" "software")

# Liefert die IPv4-Adresse des NetBird-Interfaces wt0. Erst wird das Interface
# selbst abgefragt, danach wird der Status als Rückfalloption geparst.
# Nur die erste passende Zeile: netbird status liefert je nach Version
# unterschiedlich viele Zeilen, und die Statuszeile muss einzeilig bleiben.
netbird_ipv4() {
    local addr
    addr=$(ip -o -4 addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [ -z "$addr" ]; then
        addr=$(netbird status 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | cut -d/ -f1 | head -n1)
    fi
    echo "$addr"
}

# Liefert die IPv6-Adresse von wt0, leer wenn keine vorhanden ist.
netbird_ipv6() {
    ip -o -6 addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

netbird_connected() {
    netbird status 2>/dev/null | grep -iq "connected"
}

# Altes Tailscale stilllegen - nur wenn mit INSTALL_TAILSCALE ausdrücklich
# gewünscht. Begründung siehe Kopf dieser Datei.
netbird_disable_tailscale() {
    if ! config_bool INSTALL_TAILSCALE; then
        debug "INSTALL_TAILSCALE ist nicht gesetzt - Tailscale bleibt unverändert."
        return 0
    fi

    if ! command -v tailscale >/dev/null 2>&1; then
        debug "Tailscale ist nicht installiert - kein Cleanup nötig."
        return 0
    fi

    info "Deaktiviere altes Tailscale..."
    run_eval "systemctl stop tailscaled 2>/dev/null || true"
    run_eval "systemctl disable tailscaled 2>/dev/null || true"
    success "Tailscale wurde deaktiviert - NetBird übernimmt das Overlay-Netz."
    return 0
}

netbird_install() {
    info "Installiere NetBird automatisch..."
    debug "Starte NetBird Installation"
    log_action "NETBIRD" "Starting automatic NetBird installation"

    # Universelles offizielles NetBird-Installationsskript
    install_package "curl" || return 1

    if run_eval "curl -fsSL https://pkgs.netbird.io/install.sh | sh"; then
        success "✅ NetBird erfolgreich installiert"
        log_action "NETBIRD" "NetBird installed successfully"
        return 0
    fi

    error "NetBird Installation fehlgeschlagen"
    log_action "NETBIRD" "Installation failed"
    return 1
}

# Fragt Management-URL und Setup-Key ab - Config hat Vorrang.
netbird_ask_credentials() {
    # Management-URL
    if [ -z "$NB_MGMT_URL" ]; then
        # Enter ohne Eingabe = NetBird Cloud
        ask_value "NetBird Management-URL (Enter für NetBird Cloud)" "" NB_MGMT_URL || return 1
    fi

    if [ -n "$NB_MGMT_URL" ] && [[ ! "$NB_MGMT_URL" =~ ^https?:// ]]; then
        NB_MGMT_URL="https://$NB_MGMT_URL"
    fi

    # Setup-Key ist ein Secret - verdeckte Eingabe statt Klartext auf dem Terminal
    if [ -z "$NB_SETUP_KEY" ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            info "Kein Setup-Key gesetzt - Verbindung wird ohne Setup-Key versucht."
        else
            ask_secret "NetBird Setup-Key (optional, bleibt verborgen)" NB_SETUP_KEY || return 1
        fi
    fi

    return 0
}

netbird_build_up_command() {
    NB_CMD="netbird up --allow-server-ssh --enable-ssh-root"

    if [ -n "$NB_MGMT_URL" ]; then
        NB_CMD="$NB_CMD --management-url $NB_MGMT_URL"
        log_action "NETBIRD" "Management URL provided: $NB_MGMT_URL"
    fi

    if [ -n "$NB_SETUP_KEY" ]; then
        NB_CMD="$NB_CMD --setup-key $NB_SETUP_KEY"
        log_action "NETBIRD" "Setup-Key provided: $(mask_secret "$NB_SETUP_KEY")"
    fi
}

netbird_connect() {
    local nb_ipv4 nb_ipv6

    NB_MGMT_URL="$(config_get NETBIRD_MGMT_URL)"
    NB_SETUP_KEY="$(config_get NETBIRD_SETUP_KEY)"

    netbird_ask_credentials || return 1
    netbird_build_up_command

    info "Verbinde mit NetBird ($NB_CMD)..."
    if ! run_eval "$NB_CMD"; then
        error "NetBird-Verbindung fehlgeschlagen"
        log_action "NETBIRD" "Connection failed"
        return 1
    fi

    success "✅ NetBird erfolgreich verbunden/gestartet!"

    nb_ipv4="$(netbird_ipv4)"
    nb_ipv6="$(netbird_ipv6)"

    echo ""
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_GREEN}  NetBird Status${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}IP-Adressen:${C_RESET}"
    echo "  IPv4: ${nb_ipv4:-wird zugewiesen...}"
    [ -n "$nb_ipv6" ] && echo "  IPv6: $nb_ipv6"
    echo ""
    echo "  NetBird SSH: Aktiviert (--allow-server-ssh --enable-ssh-root)"
    [ -n "$NB_MGMT_URL" ] && echo "  Management Server: $NB_MGMT_URL"
    echo ""

    # UFW für NetBird (wt0 Interface)
    if [ "$FIREWALL_CMD" = "ufw" ]; then
        run_eval "ufw allow in on wt0 2>/dev/null || true"
    fi

    log_action "NETBIRD" "Successfully connected to NetBird"
    return 0
}

# Rückgabewerte von netbird_configure:
#   0  verbunden (neu oder bereits vorhanden)
#   1  nicht konfiguriert - übersprungen, kein Fehler
#   2  Verbindungsversuch fehlgeschlagen
netbird_configure() {
    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  NetBird Konfiguration${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""

    # Prüfen ob bereits verbunden
    if netbird_connected; then
        success "NetBird ist bereits verbunden."
        local known_ipv4
        known_ipv4="$(netbird_ipv4)"
        echo "  NetBird IPv4: ${known_ipv4:-nicht ermittelbar}"
        return 0
    fi

    echo -e "${C_YELLOW}NetBird ermöglicht VPN-Verbindungen (auch mit eigenen Management-Servern).${C_RESET}"
    echo ""

    if ! config_bool NETBIRD_CONFIGURE; then
        info "NetBird-Konfiguration übersprungen. Später mit 'netbird up' konfigurieren."
        return 1
    fi

    netbird_connect || return 2
    return 0
}

module_main() {
    if ! config_bool INSTALL_NETBIRD; then
        skip "NetBird ist nicht aktiviert (INSTALL_NETBIRD=false)."
        return 1
    fi

    # Tailscale-Cleanup zuerst - die Firewall-Regeln des alten Tunnels sollen
    # nicht länger im Weg stehen, bevor NetBird startet.
    netbird_disable_tailscale

    echo ""
    info "Prüfe NetBird Installation..."

    if command -v netbird >/dev/null 2>&1; then
        success "NetBird ist bereits installiert: $(netbird version 2>/dev/null || echo 'installiert')"
        info "Führe Konfiguration aus..."
    else
        netbird_install
        if [ $? -ne 0 ]; then
            return 2
        fi
    fi

    # NetBird Service aktivieren & starten (Distributionen nutzen unterschiedliche Namen)
    manage_service enable netbird 2>/dev/null || manage_service enable netbird-backend 2>/dev/null || true
    manage_service start netbird 2>/dev/null || manage_service start netbird-backend 2>/dev/null || true

    if ! command -v netbird >/dev/null 2>&1; then
        error "NetBird ist nach der Installation nicht verfügbar."
        return 2
    fi

    netbird_configure
    local rc=$?

    unset NB_SETUP_KEY NB_MGMT_URL NB_CMD
    return $rc
}

module_status() {
    local addr
    if ! command -v netbird >/dev/null 2>&1; then
        echo "nicht installiert"
    elif netbird_connected; then
        addr="$(netbird_ipv4)"
        echo "verbunden - IPv4 ${addr:-nicht ermittelbar}"
    else
        echo "installiert, aber nicht verbunden"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local addr

    if ! config_bool INSTALL_NETBIRD; then
        echo "info|NetBird nicht angefordert|INSTALL_NETBIRD ist nicht gesetzt"
        return 0
    fi

    if ! command -v netbird >/dev/null 2>&1; then
        echo "abweichung|INSTALL_NETBIRD ist gesetzt, das Binary liegt nicht im PATH|NetBird fehlt"
        return 0
    fi

    if ! netbird_connected; then
        echo "abweichung|INSTALL_NETBIRD ist gesetzt, 'netbird up' fehlt - kein Tunnel steht|installiert, nicht verbunden"
        return 0
    fi

    addr="$(netbird_ipv4)"
    if [ -z "$addr" ]; then
        echo "abweichung|NetBird laeuft, aber das Interface wt0 hat keine IPv4-Adresse|verbunden, wt0 ohne IPv4"
        return 0
    fi

    echo "ok|verbunden, wt0 = ${addr}"
    return 0
}