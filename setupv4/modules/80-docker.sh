#!/bin/bash
# ==============================================================================
# Modul: docker
# ==============================================================================
# Installiert Docker inklusive Compose-Plugin und konfiguriert den Daemon:
# IPv6, MTU, Logging-Rotation, getrennte Adress-Pools für IPv4 und IPv6 sowie
# live-restore (außer im Swarm-Modus, da dort nicht kompatibel).
#
# Docker überschreibt die Firewall-Regeln für seine Container - deshalb werden
# hier die Docker-Netze in ufw freigegeben und die Forward-Policy auf ACCEPT
# gesetzt, sonst bleiben die Container nicht erreichbar.
#
# Config:
#   INSTALL_DOCKER - Docker installieren/konfigurieren (Default false)
#   ADMIN_USER     - Benutzer, der zur docker-Gruppe kommt (optional)
# ==============================================================================

MODULE_ID="docker"
MODULE_NAME="Docker"
MODULE_DESC="Docker mit Compose, daemon.json (IPv6, MTU, Log-Rotation)"
MODULE_ORDER=80
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("docker" "software")

DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_IPV4_POOL_BASE="172.25.0.0/16"
DOCKER_IPV4_POOL_SIZE=24
DOCKER_IPV6_FIXED_CIDR="fd00:db8:1::/64"
DOCKER_IPV6_POOL_BASE="fd00:db8:10::/56"
DOCKER_IPV6_POOL_SIZE=64
DOCKER_MTU=1450

# v3 benutzte hier $VERSION_CODENAME aus dem eigenen OS-Block. detect_os() in v4
# setzt diese Variable nicht, deshalb wird das Codename direkt aus os-release
# gelesen.
docker_os_codename() {
    local codename=""

    if [ -r /etc/os-release ]; then
        codename=$( . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" )
    fi

    echo "$codename"
}

docker_write_daemon_json() {
    local live_restore="$1"

    # Im Dry-Run darf nicht geschrieben werden - sonst würde die echte
    # daemon.json beim Testlauf überschrieben.
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${DOCKER_DAEMON_JSON}${C_RESET}" >&2
        echo "             mtu=${DOCKER_MTU}, live-restore=${live_restore}, ipv6=true"
        return 0
    fi

    mkdir -p /etc/docker
    cat > "$DOCKER_DAEMON_JSON" << EOF
{
  "mtu": ${DOCKER_MTU},
  "live-restore": ${live_restore},
  "metrics-addr": "127.0.0.1:9323",
  "experimental": true,
  "ipv6": true,
  "fixed-cidr-v6": "${DOCKER_IPV6_FIXED_CIDR}",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {
      "base": "${DOCKER_IPV4_POOL_BASE}",
      "size": ${DOCKER_IPV4_POOL_SIZE}
    },
    {
      "base": "${DOCKER_IPV6_POOL_BASE}",
      "size": ${DOCKER_IPV6_POOL_SIZE}
    }
  ]
}
EOF

    return 0
}

docker_configure_ufw() {
    [ "$FIREWALL_CMD" = "ufw" ] || return 0

    info "Konfiguriere UFW für Docker..."

    if [ -f /etc/default/ufw ]; then
        create_backup /etc/default/ufw
        run_eval "sed -i 's/^DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/' /etc/default/ufw"
    fi

    run_eval "ufw allow from ${DOCKER_IPV4_POOL_BASE} to any"
    run_eval "ufw allow from ${DOCKER_IPV6_FIXED_CIDR} to any"
    run_eval "ufw allow from ${DOCKER_IPV6_POOL_BASE} to any"
    run_eval "ufw reload"

    success "UFW für Docker konfiguriert."
    return 0
}

docker_create_newt_network() {
    if ! ask_yes_no "Möchten Sie das Docker-Netzwerk 'newt_talk' erstellen? (Empfohlen für Container-Isolation mit IPv6)" "y"; then
        info "Docker-Netzwerk 'newt_talk' wird übersprungen."
        return 0
    fi

    info "Erstelle Docker-Netzwerk 'newt_talk'..."
    run_eval "docker network rm newt_talk 2>/dev/null || true"

    if run_eval "docker network create \
            --opt com.docker.network.driver.mtu=${DOCKER_MTU} \
            --ipv6 \
            --subnet=172.25.0.0/24 \
            --subnet=fd00:db8:10:0::/64 \
            newt_talk"; then
        success "Docker-Netzwerk 'newt_talk' erstellt."
    else
        warning "Docker-Netzwerk 'newt_talk' konnte nicht erstellt werden."
    fi

    return 0
}

docker_add_user_to_group() {
    local user
    user="$(config_get ADMIN_USER)"

    if [ -z "$user" ]; then
        debug "ADMIN_USER nicht gesetzt - docker-Gruppe wird nicht verändert."
        return 0
    fi

    if ! id "$user" >/dev/null 2>&1; then
        warning "Benutzer '$user' existiert nicht - docker-Gruppe bleibt unverändert."
        return 0
    fi

    run_cmd usermod -aG docker "$user"
    success "Benutzer '$user' zur docker-Gruppe hinzugefügt."
    warning "Neuanmeldung erforderlich für docker-Gruppe."
    return 0
}

docker_install() {
    case "$OS_ID" in
        ubuntu|debian)
            info "Installiere Docker über offizielles Repository..."
            install_package "apt-transport-https ca-certificates curl gnupg lsb-release" || return 1

            local codename repo_line
            codename="$(docker_os_codename)"
            if [ -z "$codename" ]; then
                warning "VERSION_CODENAME konnte nicht gelesen werden - Repository-Eintrag wird übersprungen."
                return 1
            fi
            debug "VERSION_CODENAME: $codename"

            run_eval "curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg" || return 1

            repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${OS_ID} ${codename} stable"
            run_eval "echo '${repo_line}' > /etc/apt/sources.list.d/docker.list" || return 1

            run_eval "$PKG_UPDATE" || return 1
            install_package "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || return 1
            ;;
        centos|rhel|rocky|almalinux)
            info "Installiere Docker über yum/dnf Repository..."
            if [ "$PKG_MANAGER" = "dnf" ]; then
                run_eval "dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo" || return 1
            else
                run_eval "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo" || return 1
            fi
            install_package "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || return 1
            ;;
        fedora)
            info "Installiere Docker über dnf Repository..."
            run_eval "dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo" || return 1
            install_package "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || return 1
            ;;
        *)
            warning "Docker-Installation für $OS_ID nicht über offizielles Repo unterstützt. Versuche Standard-Paket."
            install_package "docker.io docker-compose" || install_package "docker" || return 1
            ;;
    esac

    return 0
}

module_main() {
    local swarm_mode=false live_restore

    if ! config_bool INSTALL_DOCKER; then
        skip "Docker ist nicht aktiviert (INSTALL_DOCKER=false)."
        return 1
    fi

    info "Prüfe Docker-Installation..."

    if command -v docker >/dev/null 2>&1; then
        success "Docker ist bereits installiert: $(docker --version)"
        # Prüfe ob IPv6 in daemon.json aktiviert ist
        if [ -f "$DOCKER_DAEMON_JSON" ] && grep -q '"ipv6": true' "$DOCKER_DAEMON_JSON" 2>/dev/null; then
            debug "IPv6 in Docker daemon.json ist aktiviert"
        else
            debug "IPv6 in Docker nicht aktiviert"
        fi
        return 0
    fi

    info "Installiere Docker und Docker Compose automatisch..."
    debug "Starte Docker-Installation"
    log_action "DOCKER" "Starting automatic Docker installation"

    docker_install
    if [ $? -ne 0 ]; then
        error "Docker-Installation fehlgeschlagen"
        log_action "DOCKER" "Docker installation failed"
        return 2
    fi

    manage_service enable docker
    manage_service start docker

    # Docker-Installation verifizieren
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker-Installation fehlgeschlagen"
        log_action "DOCKER" "Docker installation failed"
        return 2
    fi

    success "✅ Docker erfolgreich installiert: $(docker --version)"
    log_action "DOCKER" "Docker installed successfully"

    # --- Docker-Konfiguration (daemon.json) ---
    info "Konfiguriere Docker Daemon..."
    create_backup "$DOCKER_DAEMON_JSON"

    # Docker Swarm Abfrage
    if ask_yes_no "Wird dieser Server Teil eines Docker Swarm Clusters?" "n"; then
        swarm_mode=true
        warning "Docker Swarm Modus: live-restore wird deaktiviert (nicht kompatibel mit Swarm)"
        log_action "DOCKER" "Docker Swarm mode enabled"
    fi

    # live-restore nur wenn KEIN Swarm
    if [ "$swarm_mode" = true ]; then
        live_restore="false"
    else
        live_restore="true"
    fi

    docker_write_daemon_json "$live_restore"
    success "Docker daemon.json konfiguriert."
    if [ "$swarm_mode" = true ]; then
        info "Swarm-Modus: live-restore=false gesetzt"
    fi

    # UFW für Docker konfigurieren
    docker_configure_ufw

    # Docker neu starten
    manage_service restart docker

    # newt_talk Netzwerk erstellen (optional)
    docker_create_newt_network

    # Benutzer zur docker-Gruppe hinzufügen
    docker_add_user_to_group

    return 0
}

# Versionsangabe fuer Status und Erfolgsmeldung.
# Das Binary kann vorhanden sein, ohne dass eine Versionsausgabe entsteht
# (etwa ein nicht integrierter Docker-Desktop-Stub im PATH). Manche Wrapper
# schreiben dabei mehrzeilige Texte auf stdout - die Statuszeile darf aber
# genau eine Zeile sein, deshalb wird nur die erste Zeile ausgewertet und
# gegen das erwartete Muster geprueft.
docker_version() {
    local version
    version="$(docker --version 2>/dev/null | head -n1)"

    if [[ "$version" == Docker\ version* ]]; then
        echo "$version"
    else
        echo "Docker installiert (Version nicht abfragbar)"
    fi
}

module_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "nicht installiert"
    elif [ -f "$DOCKER_DAEMON_JSON" ] && grep -q '"ipv6": true' "$DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "$(docker_version), IPv6 aktiv"
    else
        echo "$(docker_version), IPv6 nicht aktiviert"
    fi
}

# Ziel: Docker ist installiert und die daemon.json aktiviert IPv6 - ohne die
# beiden nächsten Module (Pangolin/NetBird) laeuft auf diesem Server nichts.
module_audit() {
    if ! config_bool INSTALL_DOCKER; then
        echo "info|Docker mit daemon.json (IPv6)|INSTALL_DOCKER ist nicht gesetzt"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "abweichung|docker ist nicht installiert|Docker mit daemon.json (IPv6)"
        return 0
    fi

    if [ ! -f "$DOCKER_DAEMON_JSON" ]; then
        echo "abweichung|$DOCKER_DAEMON_JSON fehlt|Docker mit daemon.json (IPv6)"
        return 0
    fi

    if grep -q '"ipv6": true' "$DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "ok|$(docker_version), daemon.json mit IPv6"
    else
        echo "abweichung|$(docker_version), aber keine IPv6-Konfiguration|Docker mit daemon.json (IPv6)"
    fi
    return 0
}