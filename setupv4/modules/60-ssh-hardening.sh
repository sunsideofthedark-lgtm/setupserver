#!/bin/bash
# ==============================================================================
# Modul: ssh-hardening
# ==============================================================================
# Härtet den SSH-Dienst:
#   - eigener Port (schützt vor einfachen Brute-Force-Automatismen)
#   - Root-Login abgeschaltet
#   - Passwort-Authentifizierung abgeschaltet (nur Schlüssel)
#   - Zugriff nur für die Gruppe 'remotessh'
#   - eine Reihe weiterer Härtungsoptionen
#
# Voraussetzung: die Gruppe 'remotessh' und mindestens ein Benutzer darin -
# sie wird vom Modul 'users' angelegt. Ohne sie sperst du dich selbst aus!
#
# Exportiert für nachfolgende Module:
#   SSH_PORT - der aktive SSH-Port (Standard 22)
#
# Config:
#   SSH_PORT            - Ziel-Port; leer = nachfragen (Vorschlag 2222)
#   DISABLE_ROOT_LOGIN  - PermitRootLogin no setzen (Default true)
# ==============================================================================

MODULE_ID="ssh-hardening"
MODULE_NAME="SSH-Härtung"
MODULE_DESC="SSH-Port ändern, Root-Login deaktivieren, nur Schlüssel-Login über remotessh"
MODULE_ORDER=60
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "ssh")

# Zusätzliche Sicherheitsoptionen für die sshd_config (aus dem Original)
#
# Bewusst NICHT übernommen: "Protocol 2"
# Die Direktive wurde mit OpenSSH 7.6 aus der sshd_config entfernt, weil die
# Unterstützung für SSHv1 vollständig aus dem Daemon entfernt wurde. Auf jedem
# heute unterstützten System bringt die Zeile keinen zusätzlichen Schutz mehr.
# Ältere sshd-Versionen behandeln unbekannte Direktiven je nach Build
# unterschiedlich - das Risiko eines fehlschlagenden sshd -t (und damit eines
# SSH-Lockouts) ist größer als der Nutzen.
SSH_HARDEN_OPTIONS=(
    "MaxAuthTries 3"
    "ClientAliveInterval 300"
    "ClientAliveCountMax 2"
    "MaxSessions 10"
    "X11Forwarding no"
    "AllowAgentForwarding no"
    "AllowTcpForwarding no"
    "PermitEmptyPasswords no"
    "PermitUserEnvironment no"
    "Compression no"
)

ssh_config_file() {
    echo "${SSH_CONFIG:-/etc/ssh/sshd_config}"
}

# Aktuell konfigurierter SSH-Port (22 ist der Default, wenn nichts gesetzt ist)
ssh_current_port() {
    local config port
    config="$(ssh_config_file)"
    port=$(grep -E "^Port\s+" "$config" 2>/dev/null | awk '{print $2}' | tail -n1)
    echo "${port:-22}"
}

# Die Port-Regeln des Originals: 1024-65535 und keine der bekannten Proxy-Ports
ssh_port_allowed() {
    local port="$1"

    if ! validate_port "$port"; then
        error "Ungültiger Port: $port"
        warning "Port-Regeln:"
        warning "• Bereich: 1024-65535"
        warning "• Vermeiden Sie bekannte Proxy-Ports (1080, 3128, 8080, 8888, 9050, 9051)"
        warning "• Empfohlen: 2222, 2200, 22000, oder andere nicht-standard Ports"
        return 1
    fi

    if [ "$port" -lt 1024 ]; then
        error "Ungültiger Port: $port"
        warning "• Bereich: 1024-65535"
        return 1
    fi

    case "$port" in
        1080|3128|8080|8888|9050|9051)
            error "Ungültiger Port: $port"
            warning "• Vermeiden Sie bekannte Proxy-Ports (1080, 3128, 8080, 8888, 9050, 9051)"
            return 1
            ;;
    esac

    return 0
}

ssh_port_in_use() {
    local port="$1"

    if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 0
    fi
    return 1
}

# Ermittelt den Ziel-Port: aus der Config, sonst interaktiv mit Schleife
ssh_choose_port() {
    local current="$1"

    if [ -n "$SSH_PORT" ]; then
        if ! ssh_port_allowed "$SSH_PORT"; then
            return 1
        fi
        return 0
    fi

    if [ "$NON_INTERACTIVE" = "1" ]; then
        warning "SSH_PORT ist nicht gesetzt - nicht-interaktiver Modus behält den aktuellen Port $current."
        SSH_PORT="$current"
        return 0
    fi

    while true; do
        ask_value "Geben Sie einen neuen SSH-Port ein (1024-65535, Enter für 2222)" "2222" SSH_PORT || return 1
        debug "Benutzer-Eingabe für SSH-Port: '$SSH_PORT'"

        if ! ssh_port_allowed "$SSH_PORT"; then
            continue
        fi

        # Überprüfen, ob der Port schon belegt ist - außer er ist ohnehin der
        # aktuelle SSH-Port.
        debug "Prüfe Port-Verfügbarkeit: $SSH_PORT"
        if [ "$SSH_PORT" -eq "$current" ] 2>/dev/null; then
            info "Port $SSH_PORT ist bereits der aktuelle SSH-Port."
            return 0
        elif ssh_port_in_use "$SSH_PORT"; then
            error "Port $SSH_PORT wird bereits von einem anderen Dienst verwendet. Bitte wählen Sie einen anderen Port."
            continue
        fi

        return 0
    done
}

# Hängt einen Block an die sshd_config an (im Dry-Run nur anzeigen)
ssh_append_lines() {
    local config="$1"
    shift
    local line

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde an ${config} anfügen:${C_RESET}" >&2
        for line in "$@"; do
            echo "     $line" >&2
        done
        return 0
    fi

    {
        echo ""
        for line in "$@"; do
            echo "$line"
        done
    } >> "$config"
}

module_main() {
    local config current_port option key
    local login_user

    # Der Benutzer, mit dem anschließend gearbeitet wird - für die Abschluss-
    # Meldung und als Kontrollwert, dass jemand zugreifen kann.
    login_user="${LOGIN_USER:-${NEW_USER:-${ADMIN_USER:-}}}"

    config="$(ssh_config_file)"
    if [ ! -f "$config" ]; then
        warning "SSH-Konfiguration '$config' nicht gefunden - SSH-Härtung wird übersprungen."
        SSH_PORT="$(ssh_current_port)"
        export SSH_PORT
        return 1
    fi

    # Ohne Benutzer in der remotessh-Gruppe wäre nach der Härtung kein Login
    # mehr möglich - vorher prüfen und abbrechen.
    if [ -z "$login_user" ] || ! id -nG "$login_user" 2>/dev/null | tr ' ' '\n' | grep -qx remotessh; then
        warning "Es ist kein Benutzer in der Gruppe 'remotessh' bekannt - es könnte der Zugang verloren gehen."
        if [ "$NON_INTERACTIVE" = "1" ] || ! ask_yes_no "Trotzdem fortfahren?" "n"; then
            skip "SSH-Härtung übersprungen."
            SSH_PORT="$(ssh_current_port)"
            export SSH_PORT
            return 1
        fi
    fi

    if ! confirm "Soll der SSH-Dienst gehärtet werden (Port ändern, Key-Auth erzwingen)?" "n"; then
        warning "SSH-Härtung übersprungen."
        SSH_PORT="$(ssh_current_port)"
        export SSH_PORT
        return 0
    fi

    # --- SSH-Port ändern ---
    current_port="$(ssh_current_port)"
    info "Aktueller SSH-Port: $current_port"
    debug "Aktueller SSH-Port: $current_port"

    if ! ssh_choose_port "$current_port"; then
        error "Kein gültiger SSH-Port bestimmt - SSH-Härtung wird abgebrochen."
        SSH_PORT="$current_port"
        export SSH_PORT
        return 2
    fi

    info "Ändere SSH-Port von $current_port auf $SSH_PORT..."

    # Backup der SSH-Konfiguration erstellen
    create_backup "$config"

    debug "Ändere SSH-Port in $config"
    if ! run_eval "sed -i 's/^#*Port.*/Port $SSH_PORT/' '$config'"; then
        error "SSH-Port-Änderung fehlgeschlagen"
        SSH_PORT="$current_port"
        export SSH_PORT
        return 2
    fi

    success "SSH-Port wurde auf $SSH_PORT geändert."

    # --- SSH-Konfiguration härten ---
    info "Konfiguriere erweiterte SSH-Sicherheit..."

    if config_bool DISABLE_ROOT_LOGIN; then
        debug "Deaktiviere SSH Root-Login"
        if ! run_eval "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' '$config'"; then
            error "Root-Login-Deaktivierung fehlgeschlagen"
            return 2
        fi
    else
        warning "DISABLE_ROOT_LOGIN ist nicht gesetzt - Root-Login bleibt in der sshd_config unverändert."
    fi

    debug "Deaktiviere SSH Passwort-Authentifizierung"
    if ! run_eval "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' '$config'"; then
        error "Passwort-Authentifizierung-Deaktivierung fehlgeschlagen"
        return 2
    fi

    # SSH-Zugriff nur für remotessh-Gruppe erlauben
    info "Beschränke SSH-Zugriff auf die 'remotessh'-Gruppe..."
    debug "Konfiguriere AllowGroups für remotessh"

    # Entferne eventuell existierende AllowGroups/AllowUsers Einträge
    run_eval "sed -i '/^#*AllowGroups/d' '$config'"
    run_eval "sed -i '/^#*AllowUsers/d' '$config'"

    ssh_append_lines "$config" \
        "# SSH-Zugriff nur für remotessh-Gruppe" \
        "AllowGroups remotessh"

    # Zusätzliche SSH-Härtungs-Optionen
    info "Aktiviere zusätzliche SSH-Sicherheitsoptionen..."
    debug "Erweiterte SSH-Härtung"

    for option in "${SSH_HARDEN_OPTIONS[@]}"; do
        key=$(echo "$option" | cut -d' ' -f1)
        debug "Setze SSH-Option: $option"

        # Entferne existierende Einträge für diese Option
        run_eval "sed -i '/^#*$key /d' '$config'"
    done

    ssh_append_lines "$config" "# Erweiterte SSH-Sicherheitsoptionen" \
        "${SSH_HARDEN_OPTIONS[@]}"

    info "Starte SSH-Dienst neu, um Änderungen zu übernehmen..."
    debug "Neustarten des SSH-Dienstes: $SSH_SERVICE"

    if ! manage_service restart "$SSH_SERVICE"; then
        error "SSH-Dienst-Neustart fehlgeschlagen"
        return 2
    fi

    export SSH_PORT

    success "SSH-Dienst wurde gehärtet und neugestartet."
    if [ -n "$login_user" ]; then
        warning "Zukünftige SSH-Verbindungen müssen über Port $SSH_PORT mit dem Benutzer '$login_user' und SSH-Schlüssel erfolgen."
    else
        warning "Zukünftige SSH-Verbindungen müssen über Port $SSH_PORT mit SSH-Schlüssel erfolgen."
    fi

    return 0
}

module_status() {
    local config port
    config="$(ssh_config_file)"
    port="$(ssh_current_port)"

    if [ ! -f "$config" ]; then
        echo "keine sshd_config gefunden"
        return 0
    fi

    local details="Port $port"
    if grep -qE "^#*PermitRootLogin[[:space:]]+no" "$config" 2>/dev/null; then
        details="$details, Root-Login aus"
    else
        details="$details, Root-Login AN"
    fi
    if grep -qE "^#*PasswordAuthentication[[:space:]]+no" "$config" 2>/dev/null; then
        details="$details, nur Schlüssel"
    else
        details="$details, Passwort ERLAUBT"
    fi
    if grep -qE "^AllowGroups[[:space:]]+remotessh" "$config" 2>/dev/null; then
        details="$details, nur remotessh"
    fi

    echo "$details"
}

# Ziel: Port aus der Config, Root-Login aus, nur Schlüssel-Login und Zugriff
# ausschliesslich über 'remotessh'. Alle Einzelabweichungen sammeln sich im
# Detailfeld, damit genau eine Zeile entsteht.
module_audit() {
    local config port missing=""

    config="$(ssh_config_file)"
    if [ ! -f "$config" ]; then
        echo "info|SSH gehärtet auf Port ${SSH_PORT:-?} über remotessh|sshd_config nicht gefunden: $config"
        return 0
    fi

    if [ -z "$SSH_PORT" ]; then
        echo "info|SSH gehärtet, Port aus der Config|SSH_PORT ist nicht gesetzt"
        return 0
    fi

    port="$(ssh_current_port)"
    if [ "$port" != "$SSH_PORT" ]; then
        missing="Port $port statt $SSH_PORT"
    fi

    if config_bool DISABLE_ROOT_LOGIN \
        && ! grep -qE "^#*PermitRootLogin[[:space:]]+no" "$config" 2>/dev/null; then
        missing="${missing:+$missing, }PermitRootLogin nicht auf no"
    fi

    if ! grep -qE "^#*PasswordAuthentication[[:space:]]+no" "$config" 2>/dev/null; then
        missing="${missing:+$missing, }PasswordAuthentication nicht auf no"
    fi

    if ! grep -qE "^AllowGroups[[:space:]]+remotessh" "$config" 2>/dev/null; then
        missing="${missing:+$missing, }AllowGroups remotessh fehlt"
    fi

    if [ -z "$missing" ]; then
        echo "ok|Port $SSH_PORT, nur Schlüssel über remotessh"
    else
        echo "abweichung|$missing|Port $SSH_PORT, nur Schlüssel über remotessh"
    fi
    return 0
}