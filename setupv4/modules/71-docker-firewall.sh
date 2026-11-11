#!/bin/bash
# ==============================================================================
# Modul: docker-firewall
# ==============================================================================
# Docker-veroeffentlichte Ports umgehen die Firewall des Hosts.
#
# Warum: Eine von Docker veroeffentlichte Port-Weiterleitung laeuft ueber die
# FORWARD-Kette, nicht ueber INPUT. Die ufw-Regeln (INPUT) greifen darauf also
# nicht. Docker setzt eigene Regeln in die DOCKER-Kette, die VOR der
# Forward-Policy ausgewertet werden. Wer die Kette nicht kennt, haelt seinen
# Server fuer geschuetzt und ist es nicht.
#
# Docker-Doku: "By default, any remote host can connect to ports published
# to the Docker host's external addresses."
#
# Dieses Modul:
#   1. listet alle von Docker veroeffentlichten Ports auf
#   2. vergleicht sie mit den Ports, die die Firewall freigibt
#   3. meldet Abweichungen
#   4. setzt auf Wunsch Regeln in die DOCKER-USER-Kette, die genau diese
#      Abweichungen blockieren (nur beim iptables-Backend sinnvoll)
#
# Config:
#   FIREWALL_DOCKER_AUDIT   - Pruefung immer durchfuehren (Default true)
#   FIREWALL_DOCKER_USER    - DOCKER-USER-Regeln setzen (Default false)
#   FIREWALL_DOCKER_PORTS   - Ports, die trotz Docker-Freigabe offen bleiben
#                            sollen, kommagetrennt. Leer = nur die in der
#                            Firewall freigegebenen Ports bleiben offen.
# ==============================================================================

MODULE_ID="docker-firewall"
MODULE_NAME="Docker-Port-Audit"
MODULE_DESC="Von Docker veroeffentlichte Ports gegen die Firewall-Regeln pruefen"
MODULE_ORDER=71
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "docker" "firewall")

# Ermittelt die von Docker veroeffentlichten Ports als "port/protokoll"-Liste.
# Beispielausgabe von docker ps: "0.0.0.0:8120->8120/tcp, :::8120->8120/tcp"
docker_published_ports() {
    local line ports=""
    # Kein Pruefen auf /var/run/docker.sock: Docker laeuft auch mit
    # DOCKER_HOST, als rootless-Docker oder unter Podman. Entscheidend ist
    # nur, ob die CLI antwortet.
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Sowohl "0.0.0.0:8120->8120/tcp" als auch ":::8120->8120/tcp"
        # und "[::]:8120->8120/tcp" erfassen.
        local mapping
        for mapping in $(echo "$line" | grep -oE '[0-9]+->[0-9]+/[a-z]+'); do
            local container_port proto
            container_port="${mapping%%->*}"
            proto="${mapping##*/}"
            container_port="${container_port%%/*}"
            ports="${ports}${ports:+,}${container_port}/${proto}"
        done
    done < <(docker ps --format '{{.Ports}}' 2>/dev/null)

    # Doppelte Ports (IPv4 und IPv6 fuehren zum selben Port) einmal zaehlen
    echo "$ports" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

# Ports, die laut Firewall-Konfiguration offen sein sollen.
fw_allowed_ports() {
    local allowed=""

    if config_bool FIREWALL_OPEN_WEB_PORTS; then
        allowed="${allowed}80/tcp,443/tcp"
    fi
    if config_bool FIREWALL_HOSTS_PANGOLIN; then
        allowed="${allowed}51820/udp,21820/udp"
    fi
    if config_bool FIREWALL_HOSTS_KOMODO; then
        allowed="${allowed}8120/tcp"
    fi

    local entry
    for entry in ${FIREWALL_EXTRA_PORTS//,/ }; do
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        allowed="${allowed}${allowed:+,}${entry}"
    done

    echo "$allowed"
}

# Prüft, ob das iptables-Backend verwendet wird. Beim nftables-Backend
# existiert DOCKER-USER nicht und die Kette waere ohne Wirkung.
docker_uses_iptables_backend() {
    docker info --format '{{.FirewallBackend}}' 2>/dev/null | grep -qiE 'iptables'
}

# Setzt eine DROP-Regel in der DOCKER-USER-Kette.
docker_user_drop() {
    local port="$1" proto="$2"
    local ext_if="${FIREWALL_DOCKER_EXT_IF:-eth0}"
    local rule="iptables -I DOCKER-USER -i ${ext_if} -p ${proto} --dport ${port} -j DROP"

    if ! iptables -L DOCKER-USER >/dev/null 2>&1; then
        run_eval "iptables -N DOCKER-USER"
        run_eval "iptables -A FORWARD -j DOCKER-USER"
    fi

    # Doppelte Regeln vermeiden
    if iptables -S DOCKER-USER 2>/dev/null | grep -q -- "--dport ${port}.*-j DROP"; then
        debug "DOCKER-USER-Regel für ${port}/${proto} existiert bereits."
        return 0
    fi

    run_eval "$rule"
}

module_main() {
    local published allowed extra entry port proto
    local -a unexpected=()

    if ! command -v docker >/dev/null 2>&1; then
        skip "Docker ist nicht installiert - es gibt keine veroeffentlichten Ports."
        return 1
    fi

    published="$(docker_published_ports)"
    if [ -z "$published" ]; then
        success "Keine Ports von Docker veroeffentlicht - die Firewall greift vollstaendig."
        return 0
    fi

    allowed="$(fw_allowed_ports)"
    extra="$(config_get FIREWALL_DOCKER_PORTS "")"

    info "Von Docker veroeffentlichte Ports:"
    for entry in ${published//,/ }; do
        echo "     ${entry}"
    done
    echo ""

    # Welche veroeffentlichten Ports sind nicht durch die Firewall gedeckt?
    for entry in ${published//,/ }; do
        port="${entry%%/*}"
        proto="${entry##*/}"
        local found=0
        local a
        for a in ${allowed//,/ }; do
            a="$(echo "$a" | xargs)"
            [ -z "$a" ] && continue
            if [ "${a%%/*}" = "$port" ] && { [ "${a##*/}" = "$proto" ] || [ "${a##*/}" = "tcp" ]; }; then
                found=1
                break
            fi
        done
        # Ausnahmen aus FIREWALL_DOCKER_PORTS
        if [ $found -eq 0 ]; then
            for a in ${extra//,/ }; do
                a="$(echo "$a" | xargs)"
                [ -z "$a" ] && continue
                if [ "${a%%/*}" = "$port" ]; then
                    found=1
                    break
                fi
            done
        fi
        [ $found -eq 0 ] && unexpected+=("$entry")
    done

    if [ ${#unexpected[@]} -eq 0 ]; then
        success "Alle Docker-Ports sind durch die Firewall abgedeckt."
        return 0
    fi

    warning "${#unexpected[@]} von Docker veroeffentlichte Ports sind durch die Firewall NICHT abgedeckt:"
    for entry in "${unexpected[@]}"; do
        echo "     ${entry}  - direkt aus dem Internet erreichbar"
    done
    echo ""
    warning "Docker-Ports laufen ueber die FORWARD-Kette, nicht ueber INPUT."
    warning "Die ufw-Regeln greifen fuer sie nicht."

    if ! config_bool FIREWALL_DOCKER_USER; then
        info "Keine Aktion. Mit FIREWALL_DOCKER_USER=true werden passende"
        info "DOCKER-USER-Regeln gesetzt (nur beim iptables-Backend wirksam)."
        return 1
    fi

    if ! docker_uses_iptables_backend; then
        error "Docker laeuft mit dem nftables-Backend - DOCKER-USER hat dort keine Wirkung."
        warning "Bitte die Empfehlung aus der Docker-Doku beachten (nftables-Tabelle mit eigener forward-Kette)."
        return 2
    fi

    info "Setze DOCKER-USER-Regeln fuer die nicht abgedeckten Ports..."
    for entry in "${unexpected[@]}"; do
        port="${entry%%/*}"
        proto="${entry##*/}"
        docker_user_drop "$port" "$proto"
        success "  ${port}/${proto} blockiert"
    done

    return 1
}

module_status() {
    local published count
    published="$(docker_published_ports)"

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker nicht installiert"
        return 0
    fi

    if [ -z "$published" ]; then
        echo "keine veroeffentlichten Ports"
        return 0
    fi

    count=$(echo "$published" | tr ',' '\n' | grep -c .)
    echo "${count} Ports veroeffentlicht, Firewall deckt sie nicht automatisch ab"
}

module_audit() {
    local published count
    published="$(docker_published_ports)"

    if ! command -v docker >/dev/null 2>&1; then
        echo "info|Docker nicht installiert|keine Docker-Ports zu pruefen"
        return 0
    fi

    if [ -z "$published" ]; then
        echo "ok|keine Docker-Ports veroeffentlicht"
        return 0
    fi

    count=$(echo "$published" | tr ',' '\n' | grep -c .)
    echo "abweichung|${count} Ports veroeffentlicht|DOCKER-USER-Regeln noetig, sonst umgehen sie die Firewall"
    return 0
}
