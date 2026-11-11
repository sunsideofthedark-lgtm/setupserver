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
#   FIREWALL_DOCKER_AUDIT   - Pruefung durchfuehren (Default true). Auf false
#                            laeuft das Modul nicht.
#   FIREWALL_DOCKER_USER    - DOCKER-USER-Regeln setzen (Default false)
#   FIREWALL_DOCKER_PORTS   - Ports, die trotz Docker-Freigabe offen bleiben
#                            sollen, kommagetrennt. Leer = nur die in der
#                            Firewall freigegebenen Ports bleiben offen.
#   FIREWALL_DOCKER_EXT_IF  - externes Interface fuer die DOCKER-USER-Regeln.
#                            Default: aus der Default-Route ermittelt, sonst
#                            dieser Wert.
# ==============================================================================

MODULE_ID="docker-firewall"
MODULE_NAME="Docker-Port-Audit"
MODULE_DESC="Von Docker veroeffentlichte Ports gegen die Firewall-Regeln pruefen"
MODULE_ORDER=71
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "docker" "firewall")

# Zustand der Docker-Ermittlung:
#   ok          - der Docker-Daemon hat geantwortet
#   no-docker   - Docker ist nicht installiert
#   daemon-down - Docker ist installiert, der Daemon antwortet nicht
#
# Wichtig: ohne diese Information waere ein gestoppter Daemon nicht von
# "keine Ports veroeffentlicht" zu unterscheiden - der Zustand waere dann
# schlicht unbekannt.
DOCKER_PORT_STATE="ok"

# Zuordnung Host-Port -> Container-Port fuer die DOCKER-USER-Regel.
# Format: "hostport/proto=containerport", kommagetrennt.
DOCKER_CPORT_MAP=""

# Ermittelt die von Docker veroeffentlichten Ports.
#
# Entscheidend ist, AUF WELCHER Adresse ein Port veroeffentlicht wird:
#
#   ports: - "8000:8000"            -> 0.0.0.0 und ::  -> aus dem Internet
#                                        erreichbar, Firewall (INPUT) greift nicht
#   ports: - "10.0.0.1:8000:8000"   -> nur auf der NetBird-IP -> aus dem
#                                        Internet NICHT erreichbar
#
# "docker ps" zeigt die Zuordnung als
#   "0.0.0.0:8000->8000/tcp, :::8000->8000/tcp"     (offen)
#   "10.0.0.1:8000->8000/tcp"                       (nur NetBird)
#
# Fueber die Firewall zaehlt der HOST-Port - das ist der Port, den jemand
# von aussen anfragen kann. Fuer die DOCKER-USER-Regel wird der
# CONTAINER-Port gebraucht: dort ist das Paket bereits per DNAT auf den
# Container-Port umgeschrieben.
#
# Rueckgabe: vier Zeilen - Zustand, offene Ports, an eine Adresse gebundene
# Ports und die Zuordnung Host-Port -> Container-Port.
docker_published_ports() {
    local line exposed="" bound="" cport_map="" mapping rest target
    local proto container_port host_ip host_port

    command -v docker >/dev/null 2>&1 || { echo "no-docker"; return 0; }
    docker info >/dev/null 2>&1 || { echo "daemon-down"; return 0; }

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Eine Zeile je Container, darin mehrere Zuordnungen durch ", " getrennt:
        #   "0.0.0.0:8120->8120/tcp, :::8120->8120/tcp"
        #   "10.0.0.1:8000->8000/tcp"
        #
        # Wichtig: ohne IFS-Manipulation splitten. Bei IFS=',' ist der
        # Zeilenumbruch KEIN Trennzeichen - die ganze Zeile bliebe ein
        # einziges Element und der letzte Port faelle aus der Liste.
        # printf '%s\n' sorgt fuer den abschliessenden Zeilenumbruch, sonst
        # wuerde "read" die letzte Zuordnung nicht mehr lesen.
        while IFS= read -r mapping; do
            mapping="$(echo "$mapping" | xargs)"
            [ -z "$mapping" ] && continue

            # Ohne "->" ist es nur ein exponierter Container-Port und kein
            # veroeffentlichter Host-Port - der gehoert nicht in die Liste.
            case "$mapping" in
                *'->'*) ;;
                *) continue ;;
            esac

            # "IP:HOSTPORT->CONTAINERPORT/PROTO" in Teile zerlegen.
            # Ohne Regex, weil IPv6-Adressen selbst Doppelpunkte enthalten.
            rest="${mapping%%->*}"        # "0.0.0.0:8120"  bzw.  ":::8120"
            target="${mapping##*->}"      # "8120/tcp"

            proto="${target##*/}"          # "tcp"
            container_port="${target%%/*}" # "8120"

            host_port="${rest##*:}"       # letzter Teil = Port
            host_ip="${rest%:*}"          # Rest = IP
            host_ip="${host_ip#[}"        # Klammern entfernen
            host_ip="${host_ip%]}"

            # Alles was nicht auf einer konkreten Adresse lauscht, ist offen.
            case "$host_ip" in
                0.0.0.0|""|::)
                    exposed="${exposed}${exposed:+,}${host_port}/${proto}"
                    ;;
                *)
                    bound="${bound}${bound:+,}${host_ip}:${host_port}/${proto}"
                    ;;
            esac

            # Zuordnung festhalten - sie wird fuer die DOCKER-USER-Regel
            # gebraucht, dort ist der Container-Port der richtige.
            cport_map="${cport_map}${cport_map:+,}${host_port}/${proto}=${container_port}"
        done < <(printf '%s\n' "$line" | tr ',' '\n')
    done < <(docker ps --format '{{.Ports}}' 2>/dev/null)

    # Deduplizieren (IPv4 und IPv6 fuehren zum selben Port)
    exposed=$(echo "$exposed" | tr ',' '\n' | awk 'NF && !s[$0]++' | paste -sd, -)
    bound=$(echo "$bound" | tr ',' '\n' | awk 'NF && !s[$0]++' | paste -sd, -)
    cport_map=$(echo "$cport_map" | tr ',' '\n' | awk 'NF && !s[$0]++' | paste -sd, -)

    echo "ok"
    echo "$exposed"
    echo "$bound"
    echo "$cport_map"
}

# Holt beide Portlisten in Globale: offene Ports und an eine Adresse gebundene.
DOCKER_EXPOSED_PORTS=""
DOCKER_BOUND_PORTS=""
docker_collect_ports() {
    local out
    out="$(docker_published_ports)"
    DOCKER_PORT_STATE="$(echo "$out" | sed -n 1p)"
    DOCKER_EXPOSED_PORTS="$(echo "$out" | sed -n 2p)"
    DOCKER_BOUND_PORTS="$(echo "$out" | sed -n 3p)"
    DOCKER_CPORT_MAP="$(echo "$out" | sed -n 4p)"
}

# Ermittelt den Container-Port zu einem Host-Port.
#
# In der DOCKER-USER-Kette ist das Paket bereits per DNAT auf den
# Container-Port umgeschrieben - eine Regel auf den Host-Port wuerde dort
# nichts treffen.
docker_container_port() {
    local host_port="$1" proto="$2" entry

    for entry in ${DOCKER_CPORT_MAP//,/ }; do
        if [ "${entry%%=*}" = "${host_port}/${proto}" ]; then
            echo "${entry##*=}"
            return 0
        fi
    done

    # Ohne Zuordnung bleibt der Host-Port - dann trifft die Regel
    # wenigstens den Port, der auch von aussen kommt.
    echo "$host_port"
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

# Ermittelt das externe Interface des Hosts aus der Default-Route.
#
# "ip route get 1.1.1.1" liefert z.B.:
#   1.1.1.1 via 172.30.16.1 dev eth0 src 172.30.31.47 uid 0
# Das Interface steht hinter "dev". Ein festes "eth0" waere auf einem Host
# mit ens3, ens18, enp1s0 ... falsch - die Regel wuerde dort nie greifen.
docker_ext_interface() {
    local detected=""

    if command -v ip >/dev/null 2>&1; then
        detected="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
        [ -z "$detected" ] && detected="$(ip route show default 2>/dev/null | awk '/^default/ {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    fi

    # Nur ein Interface, das es auf dem Host wirklich gibt, ist brauchbar.
    if [ -n "$detected" ] && [ ! -d "/sys/class/net/${detected}" ]; then
        detected=""
    fi

    if [ -n "$detected" ]; then
        echo "$detected"
        return 0
    fi

    # Fallback: der konfigurierte Wert.
    detected="$(config_get FIREWALL_DOCKER_EXT_IF "")"
    if [ -n "$detected" ]; then
        echo "$detected"
        return 0
    fi

    return 1
}

# Setzt eine DROP-Regel in der DOCKER-USER-Kette.
# Der Port ist der CONTAINER-Port - in der FORWARD-Kette ist das Paket
# bereits per DNAT auf den Container-Port umgeschrieben.
docker_user_drop() {
    local port="$1" proto="$2"
    local ext_if rule
    ext_if="$(docker_ext_interface)"

    if [ -n "$ext_if" ]; then
        rule="iptables -I DOCKER-USER -i ${ext_if} -p ${proto} --dport ${port} -j DROP"
    else
        # Ohne Interface gilt die Regel auf allen - das ist der Notfall,
        # wenn das externe Interface nicht ermittelbar ist.
        rule="iptables -I DOCKER-USER -p ${proto} --dport ${port} -j DROP"
        warning "Externes Interface nicht ermittelbar - die DOCKER-USER-Regel gilt fuer alle Interfaces."
    fi

    if ! iptables -L DOCKER-USER >/dev/null 2>&1; then
        run_eval "iptables -N DOCKER-USER"
        run_eval "iptables -A FORWARD -j DOCKER-USER"
    fi

    # Doppelte Regeln vermeiden
    if iptables -S DOCKER-USER 2>/dev/null | grep -q -- "--dport ${port}.*-j DROP"; then
        debug "DOCKER-USER-Regel für ${port}/${proto} existiert bereits."
        return 0
    fi

    debug "DOCKER-USER-Regel für ${port}/${proto} auf Interface ${ext_if:-alle}."
    run_eval "$rule"
}

module_main() {
    local published allowed extra entry port proto cport
    local -a unexpected=()

    if ! command -v docker >/dev/null 2>&1; then
        skip "Docker ist nicht installiert - es gibt keine veroeffentlichten Ports."
        return 1
    fi

    # Der Schalter entscheidet, ob die Pruefung ueberhaupt laeuft.
    # Der Default wird hier ausdruecklich gesetzt - sonst waere die
    # Pruefung ohne gesetzte Variable aus.
    if ! config_bool FIREWALL_DOCKER_AUDIT true; then
        skip "Pruefung nicht angefordert (FIREWALL_DOCKER_AUDIT=false)."
        return 1
    fi

    docker_collect_ports
    published="$DOCKER_EXPOSED_PORTS"

    # Ohne erreichbaren Daemon ist der Zustand unbekannt - das darf nicht
    # wie "nichts veroeffentlicht" aussehen.
    if [ "$DOCKER_PORT_STATE" = "daemon-down" ]; then
        warning "Docker-Daemon nicht erreichbar - die veroeffentlichten Ports konnten nicht geprueft werden."
        return 1
    fi

    if [ -z "$published" ] && [ -z "$DOCKER_BOUND_PORTS" ]; then
        success "Keine Ports von Docker veroeffentlicht - die Firewall greift vollstaendig."
        return 0
    fi

    allowed="$(fw_allowed_ports)"
    extra="$(config_get FIREWALL_DOCKER_PORTS "")"

    if [ -n "$published" ]; then
        info "Von Docker auf ALLEN Adressen veroeffentlicht (aus dem Internet erreichbar):"
        for entry in ${published//,/ }; do
            echo "     ${entry}"
        done
    fi
    if [ -n "$DOCKER_BOUND_PORTS" ]; then
        info "An eine bestimmte Adresse gebunden (nur im Mesh erreichbar, unkritisch):"
        for entry in ${DOCKER_BOUND_PORTS//,/ }; do
            echo "     ${entry}"
        done
    fi
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
        # Die Abweichung ist gemeldet - das Modul hat seine Arbeit getan.
        return 0
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
        # In der DOCKER-USER-Kette ist das Paket bereits per DNAT auf den
        # Container-Port umgeschrieben - dort greift der Container-Port.
        cport="$(docker_container_port "$port" "$proto")"
        docker_user_drop "$cport" "$proto"
        if [ "$cport" = "$port" ]; then
            success "  ${port}/${proto} blockiert"
        else
            success "  ${port}/${proto} blockiert (Container-Port ${cport})"
        fi
    done

    return 0
}

module_status() {
    local count exposed bound

    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker nicht installiert"
        return 0
    fi

    docker_collect_ports
    exposed="$DOCKER_EXPOSED_PORTS"
    bound="$DOCKER_BOUND_PORTS"

    # Ein gestoppter Daemon ist nicht "nichts veroeffentlicht" - der
    # Zustand ist schlicht unbekannt.
    if [ "$DOCKER_PORT_STATE" = "daemon-down" ]; then
        echo "Docker-Daemon nicht erreichbar - Zustand unbekannt"
        return 0
    fi

    if [ -z "$exposed" ] && [ -z "$bound" ]; then
        echo "keine veroeffentlichten Ports"
        return 0
    fi

    count=$(echo "$exposed" | tr ',' '\n' | grep -c .)
    if [ -n "$exposed" ]; then
        echo "${count} Ports auf allen Adressen offen - Firewall greift dort nicht"
    else
        echo "nur an konkrete Adresse gebunden - unkritisch"
    fi
}

module_audit() {
    local count exposed bound

    # Ohne angeforderte Pruefung gibt es keinen Zielzustand und damit auch
    # keine Abweichung.
    if ! config_bool FIREWALL_DOCKER_AUDIT true; then
        echo "info|Docker-Port-Audit nicht angefordert|FIREWALL_DOCKER_AUDIT ist nicht gesetzt"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "info|Docker nicht installiert|keine Docker-Ports zu pruefen"
        return 0
    fi

    docker_collect_ports
    exposed="$DOCKER_EXPOSED_PORTS"
    bound="$DOCKER_BOUND_PORTS"

    # Der Zustand ist unbekannt - das ist keine Abweichung, aber auch kein
    # "ok".
    if [ "$DOCKER_PORT_STATE" = "daemon-down" ]; then
        echo "info|Docker-Daemon nicht erreichbar|Zustand nicht pruefbar"
        return 0
    fi

    if [ -z "$exposed" ] && [ -z "$bound" ]; then
        echo "ok|keine Docker-Ports veroeffentlicht"
        return 0
    fi

    if [ -z "$exposed" ]; then
        echo "ok|nur an konkrete Adresse gebunden - nicht aus dem Internet erreichbar"
        return 0
    fi

    count=$(echo "$exposed" | tr ',' '\n' | grep -c .)
    echo "abweichung|${count} Ports auf allen Adressen offen|DOCKER-USER-Regeln noetig, sonst umgehen sie die Firewall"
    return 0
}
