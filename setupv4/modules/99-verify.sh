#!/bin/bash
# ==============================================================================
# Modul: verify
# ==============================================================================
# Abschlussprüfung: Netzwerk-Konnektivität, Docker-Netzwerk-Tests und die
# Ausgabe der nächsten Schritte.
#
# Zum Thema Neustart: Das Original-Script (setupv3.sh) hat hier am Ende
# reboot ausgeführt. Das ist in v4 NICHT mehr der Fall - das Hauptscript wertet
# REBOOT_AT_END bereits selbst aus und fragt nach dem letzten Modul nach dem
# Neustart. Dieses Modul gibt deshalb nur noch eine Empfehlung aus und löst
# selbst keinen Neustart aus.
#
# Config:
#   (kein eigener Schalter - dieses Modul ist immer aktiv)
# ==============================================================================

MODULE_ID="verify"
MODULE_NAME="Abschlussprüfung"
MODULE_DESC="Prüft Netzwerk-Konnektivität, testet Docker-Netzwerke und zeigt die nächsten Schritte"
MODULE_ORDER=99
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("verify")

VERIFY_TEST_IPV4="8.8.8.8"
VERIFY_TEST_IPV6="ipv6.google.com"
VERIFY_DOCKER_NETWORK="newt_talk"
VERIFY_IMAGE="busybox"

# Netzwerk-Konnektivität prüfen
verify_check_network() {
    debug "Prüfe Netzwerk-Konnektivität"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] ping -c 1 ${VERIFY_TEST_IPV4}${C_RESET}" >&2
        return 0
    fi

    if ! ping -c 1 "$VERIFY_TEST_IPV4" >/dev/null 2>&1; then
        warning "Keine Internet-Verbindung erkannt. Einige Features könnten nicht funktionieren."
        return 1
    fi

    return 0
}

# Wurde IPv6 in der Docker-Daemon-Konfiguration aktiviert? Ohne diese
# Einstellung schlagen IPv6-Pings in Containern zwangsläufig fehl und der
# Test wäre bedeutungslos.
verify_docker_ipv6_enabled() {
    local daemon_json="/etc/docker/daemon.json"

    if [ -f "$daemon_json" ] && grep -qE '"ipv6"[[:space:]]*:[[:space:]]*true' "$daemon_json" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Ping-Test in einem Container. $1 = Netzwerk (leer = Default), $2 = Ziel
verify_docker_ping() {
    local network="$1"
    local target="$2"
    local label="$3"
    local -a docker_args=()

    [ -n "$network" ] && docker_args=(--network "$network")

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] docker run --rm ${docker_args[*]} ${VERIFY_IMAGE} ping -c 3 ${target}${C_RESET}" >&2
        return 0
    fi

    if docker run --rm "${docker_args[@]}" "$VERIFY_IMAGE" ping -c 3 "$target" >/dev/null 2>&1; then
        success "  -> [${label}] IPv4-Verbindung nach außen ist erfolgreich!"
        return 0
    fi

    error "  -> [${label}] IPv4-Verbindung nach außen ist fehlgeschlagen!"
    return 1
}

# Docker-Netzwerk-Konnektivitätstest
verify_docker_network() {
    local ipv6=0

    if verify_docker_ipv6_enabled; then
        ipv6=1
    fi

    # --- Default Bridge ---
    info "Teste IPv4-Konnektivität (Default Bridge)..."
    verify_docker_ping "" "$VERIFY_TEST_IPV4" "Default"

    if [ "$ipv6" = "1" ]; then
        info "Teste IPv6-Konnektivität (Default Bridge)..."
        verify_docker_ping "" "$VERIFY_TEST_IPV6" "Default"
    else
        info "⏭️  Überspringe IPv6-Test (in daemon.json deaktiviert)"
    fi

    # --- newt_talk ---
    if [ "$DRY_RUN" = "1" ] || docker network inspect "$VERIFY_DOCKER_NETWORK" >/dev/null 2>&1; then
        echo ""
        info "Teste IPv4-Konnektivität ('${VERIFY_DOCKER_NETWORK}' Netzwerk)..."
        verify_docker_ping "$VERIFY_DOCKER_NETWORK" "$VERIFY_TEST_IPV4" "$VERIFY_DOCKER_NETWORK" || \
            warning "Bitte überprüfen Sie Ihre Docker-Netzwerkkonfiguration und Firewall-Regeln."

        if [ "$ipv6" = "1" ]; then
            info "Teste IPv6-Konnektivität ('${VERIFY_DOCKER_NETWORK}' Netzwerk)..."
            verify_docker_ping "$VERIFY_DOCKER_NETWORK" "$VERIFY_TEST_IPV6" "$VERIFY_DOCKER_NETWORK"
        fi
    else
        warning "Docker-Netzwerk '${VERIFY_DOCKER_NETWORK}' existiert nicht - Test wird übersprungen."
    fi
}

module_main() {
    local ssh_port admin_user

    # --- Netzwerk-Konnektivität ---
    echo ""
    verify_check_network

    # --- Docker-Netzwerk-Test ---
    if command -v docker >/dev/null 2>&1; then
        echo ""
        info "🧪 Finaler Docker-Netzwerk-Konnektivitätstest..."
        verify_docker_network
    else
        debug "Docker ist nicht installiert - Netzwerktest wird übersprungen."
    fi

    # --- Nächste Schritte ---
    ssh_port="$(config_get SSH_PORT 22)"
    admin_user="$(config_get ADMIN_USER "")"
    [ -n "$admin_user" ] || admin_user="<ADMIN_USER>"

    echo ""
    echo -e "${C_GREEN}🔗 SSH-Verbindung:${C_RESET}"
    echo -e "     ${C_BLUE}ssh -i /pfad/zum/privaten/schlüssel -p ${ssh_port} ${admin_user}@<IHRE_SERVER_IP>${C_RESET}"
    echo ""
    echo -e "${C_YELLOW}📝 Nächste Schritte:${C_RESET}"
    echo -e "     1. Testen Sie die SSH-Verbindung in einem NEUEN Terminal"
    echo -e "     2. Verwenden Sie den gespeicherten privaten SSH-Schlüssel"
    echo -e "     3. Starten Sie den Server neu: ${C_BLUE}sudo reboot${C_RESET}"
    echo ""
    echo -e "${C_RED}⚠️  KRITISCH: Testen Sie die SSH-Verbindung BEVOR Sie sich abmelden!${C_RESET}"
    echo ""

    info "📋 Setup-Log wurde gespeichert unter: ${LOGFILE:-nicht gesetzt}"

    echo ""
    echo -e "${C_YELLOW}===================================================================${C_RESET}"
    echo -e "${C_YELLOW}Der Server sollte nun neu gestartet werden, um alle Änderungen zu übernehmen.${C_RESET}"
    echo -e "${C_YELLOW}===================================================================${C_RESET}"
    echo ""

    # Bewusst KEIN Reboot hier - das Hauptscript fragt am Ende selbst nach
    # (REBOOT_AT_END) und startet den Server nur dort neu.
    info "Ein Neustart wird nur vom Hauptscript ausgeführt (REBOOT_AT_END)."

    # Die Prüfungen sind Diagnostik: ein fehlgeschlagener Test ist ein Hinweis,
    # aber kein Fehler des Setups - der Server bleibt nutzbar.
    return 0
}

module_status() {
    local net="offline"
    local docker="nicht installiert"

    ping -c 1 "$VERIFY_TEST_IPV4" >/dev/null 2>&1 && net="online"
    command -v docker >/dev/null 2>&1 && docker="vorhanden"

    echo "Netzwerk ${net}, Docker ${docker}"
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local net="offline"
    local docker_state="fehlt"

    if ! command -v ping >/dev/null 2>&1; then
        echo "info|Konnektivität nicht prüfbar|ping ist nicht installiert"
        return 0
    fi

    ping -c 1 "$VERIFY_TEST_IPV4" >/dev/null 2>&1 && net="online"

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            docker_state="erreichbar"
        else
            docker_state="Daemon antwortet nicht"
        fi
    fi

    if [ "$net" != "online" ] || [ "$docker_state" != "erreichbar" ]; then
        echo "abweichung|Netzwerk ${net}, Docker ${docker_state}|Abschlussprüfung nicht bestanden"
        return 0
    fi

    echo "ok|Netzwerk online, Docker erreichbar"
    return 0
}