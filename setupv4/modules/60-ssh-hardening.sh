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

    # --- Benutzerbezogene Beschränkung (AllowUsers) ---
    # AllowGroups und AllowUsers wirken zusammen (UND): Ein Benutzer muss in
    # der Gruppe sein UND in der Liste stehen. Das ist die strengste Form.
    #
    # Sicherheitsregel: Der Admin-Benutzer wird IMMER mit aufgenommen. Ohne
    # diese Absicherung koennte ein Tippfehler in der Liste den einzigen
    # SSH-Zugang des Servers abschneiden.
    local allowed_users
    allowed_users="$(config_get SSH_ALLOWED_USERS "")"
    if [ -n "$allowed_users" ]; then
        local user_list user_name
        user_list=""
        for user_name in ${allowed_users//,/ }; do
            user_name="$(echo "$user_name" | xargs)"
            [ -z "$user_name" ] && continue
            case ",$user_list," in
                *",$user_name,"*) continue ;;
            esac
            user_list="${user_list:+$user_list,}$user_name"
        done

        # Den Zielbenutzer zwingend mit aufnehmen - Lockout verhindern
        if [ -n "$target_user" ]; then
            case ",$user_list," in
                *",$target_user,"*) ;;
                *) user_list="${user_list:+$user_list,}$target_user" ;;
            esac
        fi

        if [ -n "$user_list" ]; then
            info "Beschränke SSH-Zugriff auf Benutzer: $user_list"
            ssh_append_lines "$config" \
                "# SSH-Zugriff nur für die gelisteten Benutzer" \
                "AllowUsers $user_list"
        fi
    else
        debug "SSH_ALLOWED_USERS nicht gesetzt - Zugriff regelt allein die Gruppe remotessh"
    fi

    # --- SSH nur über das NetBird-Interface erreichbar machen ---
    # Der Dienst bindet dann nur an die NetBird-IP. Aus dem Internet ist der
    # SSH-Port damit nicht erreichbar - automatische Scanner sehen nichts.
    if config_bool SSH_NETBIRD_ONLY; then
        local netbird_ip
        netbird_ip="$(ssh_netbird_ip)"
        if [ -n "$netbird_ip" ]; then
            info "Binde SSH an das NetBird-Interface ($netbird_ip) - nur im Mesh erreichbar."
            run_eval "sed -i '/^#*ListenAddress/d' '$config'"
            ssh_append_lines "$config" \
                "# SSH nur ueber das NetBird-Interface erreichbar" \
                "ListenAddress $netbird_ip"
        else
            warning "SSH_NETBIRD_ONLY ist gesetzt, aber es laeuft kein NetBird - SSH bleibt auf allen Interfaces erreichbar."
        fi
    fi

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

    # --- Konfiguration prüfen, BEVOR der Dienst neu gestartet wird ---
    # Das ist der wichtigste Schritt des ganzen Moduls: Eine syntaktisch
    # kaputte sshd_config macht der Neustart den Server unerreichbar. Also
    # erst prüfen, dann starten, und bei einem Fehler die alte Konfiguration
    # zurückholen.
    info "Prüfe SSH-Konfiguration..."
    ssh_validate_config "$config"
    local validate_rc=$?
    if [ $validate_rc -eq 1 ]; then
        error "Die neue SSH-Konfiguration ist fehlerhaft - der Dienst wird NICHT neu gestartet."
        ssh_restore_config "$config"
        return 2
    elif [ $validate_rc -eq 2 ]; then
        warning "Konfiguration konnte nicht geprüft werden - der Neustart wird trotzdem versucht."
    else
        success "SSH-Konfiguration ist gültig."
    fi

    info "Starte SSH-Dienst neu, um Änderungen zu übernehmen..."
    debug "Neustarten des SSH-Dienstes: $SSH_SERVICE"

    if ! manage_service restart "$SSH_SERVICE"; then
        error "SSH-Dienst-Neustart fehlgeschlagen - Konfiguration wird zurückgerollt."
        ssh_restore_config "$config"
        manage_service restart "$SSH_SERVICE" >/dev/null 2>&1
        error "Die alte SSH-Konfiguration wurde wiederhergestellt."
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

# Prüft die SSH-Konfiguration mit dem echten sshd - genau so, wie es der
# Dienst selbst tun würde. "sshd -t" bricht bei Syntaxfehlern, unbekannten
# Direktiven und fehlerhaften Pfaden ab, ohne den Dienst anzufassen.
#
# Rückgabe:  0 = gültig
#            1 = fehlerhaft -> abbrechen und zurücksetzen
#            2 = nicht prüfbar (z. B. fehlende Host-Keys auf einem frischen
#                Server) -> warnen, aber weitermachen
ssh_validate_config() {
    local config="$1"
    local output

    if ! command -v sshd >/dev/null 2>&1; then
        warning "sshd-Binary nicht gefunden - Konfiguration kann nicht geprüft werden."
        return 2
    fi

    output="$(sshd -t -f "$config" 2>&1)"
    if [ $? -eq 0 ]; then
        debug "sshd -t: Konfiguration ist gültig"
        return 0
    fi

    # Fehlende Host-Keys heißen: es läuft noch kein sshd, es kann also auch
    # nichts kaputtgemacht werden. Das ist kein Konfigurationsfehler.
    if printf '%s' "$output" | grep -qiE 'no hostkeys|host key'; then
        warning "sshd -t kann nicht prüfen (keine Host-Keys vorhanden - es läuft noch kein sshd)."
        debug "sshd -t Ausgabe: $output"
        return 2
    fi

    error "sshd -t meldet einen Fehler:"
    echo "$output" | sed 's/^/     /'
    return 1
}

# Holt die zuletzt von create_backup() erzeugte Sicherung zurück.
ssh_restore_config() {
    local config="$1"
    local backup_dir="${BACKUP_DIR:-/var/backups/serversetup}"
    local newest

    newest=$(ls -1t "$backup_dir"/$(echo "$config" | tr '/' '_').*.bak 2>/dev/null | head -n1)
    if [ -z "$newest" ]; then
        error "Keine Sicherung für $config gefunden - bitte manuell prüfen!"
        return 1
    fi

    if cp -p "$newest" "$config" 2>/dev/null; then
        success "SSH-Konfiguration aus $newest wiederhergestellt."
        return 0
    fi

    error "Wiederherstellung der SSH-Konfiguration fehlgeschlagen!"
    return 1
}

# Ermittelt die IP-Adresse des NetBird-Interfaces (wt0).
ssh_netbird_ip() {
    local ip
    ip="$(ip -4 -o addr show dev wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [ -n "$ip" ] && echo "$ip"
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