#!/bin/bash
# ==============================================================================
# Modul: github-ssh
# ==============================================================================
# Richtet einen SSH-Key für GitHub ein und konfiguriert git für Commits.
# Zwei Wege sind möglich:
#   1. über die GitHub CLI (gh) - dort wird der Key automatisch hochgeladen
#   2. manuell - Key wird erzeugt und muss bei GitHub unter
#      https://github.com/settings/keys eingetragen werden
#
# Wird die GitHub CLI benutzt und ist nicht vorhanden, wird sie - sofern
# möglich - automatisch installiert.
#
# Abweichung zu setupv3: dort stand "GITHUB_USER=${NEW_USER:-root}". v4 kennt
# kein NEW_USER mehr, deshalb wird die Ziel-Auflösung über
# GITHUB_USERNAME -> ADMIN_USER -> root gebildet.
#
# Config:
#   INSTALL_GITHUB_SSH  - SSH-Key einrichten (Default false)
#   GITHUB_USERNAME     - lokaler Benutzer, dessen SSH-Key eingerichtet wird
#   GITHUB_EMAIL        - E-Mail-Adresse für git; daraus wird auch die Domain
#                         für den SSH-Key-Kommentar abgeleitet
#   GITHUB_USE_CLI      - GitHub CLI bevorzugen, wenn vorhanden (Default true)
# ==============================================================================

MODULE_ID="github-ssh"
MODULE_NAME="GitHub SSH-Key"
MODULE_DESC="SSH-Key für GitHub erzeugen und git konfigurieren"
MODULE_ORDER=94
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("git" "ssh" "github")

# Löst den Benutzer auf, für den der Key erzeugt wird. Reihenfolge wie in
# setupv3, wo der neu angelegte Benutzer (NEW_USER) verwendet wurde.
ghssh_resolve_user() {
    local candidate

    for candidate in "$GITHUB_USERNAME" "$ADMIN_USER" "root"; do
        [ -z "$candidate" ] && continue
        if [ "$candidate" = "root" ] || id -u "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
        debug "Benutzer '$candidate' existiert nicht - wird übersprungen."
    done

    return 1
}

ghssh_user_home() {
    if [ "$1" = "root" ]; then
        echo "/root"
    else
        echo "/home/$1"
    fi
}

# Installiert die GitHub CLI je nach Distribution
ghssh_install_cli() {
    install_package "curl" || return 1

    case "$OS_ID" in
        ubuntu|debian)
            run_cmd curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                -o /usr/share/keyrings/githubcli-archive-keyring.gpg || return 1
            run_cmd sh -c "echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list" || return 1
            run_eval "$PKG_UPDATE" || return 1
            install_package "gh" || return 1
            ;;
        centos|rhel|rocky|almalinux|fedora|opensuse*|sles|arch)
            install_package "gh" || return 1
            ;;
        *)
            warning "Automatische Installation für $OS_ID nicht verfügbar."
            echo "Installiere gh manuell: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
            return 1
            ;;
    esac

    command -v gh >/dev/null 2>&1
}

# Legt den GitHub-Block in die ssh_config an, falls er noch fehlt
ghssh_write_ssh_config() {
    local ssh_dir="$1"
    local target_user="$2"

    if [ -f "$ssh_dir/config" ] && grep -q "github.com" "$ssh_dir/config" 2>/dev/null; then
        debug "ssh_config enthält bereits einen GitHub-Eintrag."
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde an ${ssh_dir}/config einen GitHub-Block anhängen${C_RESET}" >&2
        return 0
    fi

    cat >> "$ssh_dir/config" << 'EOF'

# GitHub
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF

    chmod 600 "$ssh_dir/config"
    [ "$target_user" != "root" ] && run_cmd chown "$target_user:$target_user" "$ssh_dir/config"
    return 0
}

# Verbindungsprobe zu GitHub
ghssh_test_connection() {
    local target_user="$1"

    # Im Dry-Run wird nichts ausgeführt - run_cmd liefert dann nur die
    # angezeigte Zeile auf stderr, die_pipe-Auswertung ergäbe also einen
    # irreführenden Fehler.
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] Verbindungstest zu GitHub würde laufen${C_RESET}" >&2
        return 0
    fi

    sudo -u "$target_user" ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"
}

module_main() {
    local target_user home_dir ssh_dir key_file host_name domain key_comment git_email
    local generate_key=false backup_time

    echo ""
    info "Richte GitHub SSH-Key ein..."
    debug "Starte GitHub SSH-Key Setup"
    log_action "GITHUB_SSH" "Starting GitHub SSH key setup"

    if ! config_bool INSTALL_GITHUB_SSH; then
        debug "INSTALL_GITHUB_SSH ist nicht gesetzt - das Modul wurde aber explizit ausgewählt."
    fi

    # --- git installieren falls nicht vorhanden ---
    if ! command -v git >/dev/null 2>&1; then
        info "Installiere git..."
        if ! install_package "git"; then
            error "git Installation fehlgeschlagen."
            return 2
        fi
    fi

    # --- Ziel-User bestimmen ---
    if ! target_user="$(ghssh_resolve_user)"; then
        error "Kein gültiger Zielbenutzer gefunden - bitte GITHUB_USERNAME prüfen."
        return 2
    fi

    home_dir="$(ghssh_user_home "$target_user")"
    ssh_dir="$home_dir/.ssh"
    key_file="$ssh_dir/id_ed25519"

    if [ "$target_user" != "root" ]; then
        home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
        [ -n "$home_dir" ] || home_dir="/home/$target_user"
        ssh_dir="$home_dir/.ssh"
        key_file="$ssh_dir/id_ed25519"
    fi

    host_name="$(hostname)"

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  GitHub SSH-Key Setup${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}Zielbenutzer:${C_RESET} $target_user"

    # --- Domain für den SSH-Key-Kommentar ---
    git_email="$GITHUB_EMAIL"
    domain=""
    if [ -n "$git_email" ] && [[ "$git_email" == *@* ]]; then
        domain="${git_email#*@}"
    fi

    if [ -z "$domain" ] && [ "$NON_INTERACTIVE" != "1" ]; then
        info "Domain für SSH-Key Kommentar eingeben"
        info "  (Der SSH-Key wird als ${host_name}@<domain> angezeigt)"
        ask_value "Domain (z. B. sunriseing.dev)" "" domain
    fi

    if [ -n "$domain" ]; then
        key_comment="${host_name}@${domain}"
    else
        key_comment="${host_name}-server"
    fi

    # E-Mail für git: aus der Config, sonst aus Hostname und Domain ableiten
    if [ -z "$git_email" ] && [ -n "$domain" ]; then
        git_email="${host_name}@${domain}"
    fi

    info "SSH-Key Kommentar: $key_comment"
    info "Git Username: $host_name"

    # --- Weg 1: GitHub CLI ---
    if config_bool GITHUB_USE_CLI; then
        if command -v gh >/dev/null 2>&1; then
            echo -e "${C_GREEN}GitHub CLI (gh) ist installiert!${C_RESET}"
            echo ""

            # 'gh auth login' ist ein interaktiver Dialog - im Dry-Run und im
            # nicht-interaktiven Modus wird er nicht ausgeführt.
            local use_cli=1
            if [ "$NON_INTERACTIVE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
                info "GitHub CLI Login würde jetzt interaktiv gestartet."
                use_cli=0
            elif ask_yes_no "Möchtest du die GitHub CLI für das Setup verwenden? (Empfohlen - automatischer Key-Upload)" "y"; then
                use_cli=1
            else
                use_cli=0
            fi

            if [ "$use_cli" = "1" ]; then
                echo ""
                echo -e "${C_YELLOW}=== GitHub CLI Login ===${C_RESET}"
                echo ""
                echo "Wähle im folgenden Dialog:"
                echo "  1. Account: GitHub.com"
                echo "  2. Protocol: SSH"
                echo "  3. Generate new SSH key: Yes"
                echo "  4. Authenticate: Login with a web browser"
                echo ""

                if sudo -u "$target_user" gh auth login; then
                    success "✅ GitHub CLI Authentifizierung erfolgreich!"
                    log_action "GITHUB_SSH" "GitHub CLI auth successful"

                    # Verbindung testen
                    echo ""
                    info "Teste GitHub Verbindung..."
                    if ghssh_test_connection "$target_user"; then
                        success "✅ SSH-Verbindung zu GitHub funktioniert!"
                    fi

                    # Git konfigurieren
                    run_cmd sudo -u "$target_user" git config --global user.name "$host_name"
                    if [ -n "$git_email" ]; then
                        run_cmd sudo -u "$target_user" git config --global user.email "$git_email"
                    fi

                    echo ""
                    success "Git konfiguriert:"
                    echo "  Username: $host_name"
                    [ -n "$git_email" ] && echo "  E-Mail: $git_email"

                    echo ""
                    echo -e "${C_GREEN}===========================================${C_RESET}"
                    echo -e "${C_GREEN}  Setup abgeschlossen!${C_RESET}"
                    echo -e "${C_GREEN}===========================================${C_RESET}"
                    echo ""
                    echo -e "${C_BLUE}SSH-Key:${C_RESET} $key_comment"
                    echo -e "${C_BLUE}Repository klonen:${C_RESET}"
                    echo "  git clone git@github.com:username/repo.git"
                    echo ""

                    log_action "GITHUB_SSH" "Setup completed via gh CLI"
                    return 0
                fi

                warning "GitHub CLI Login fehlgeschlagen. Falle auf manuelle Methode zurück."
            fi
        else
            echo -e "${C_YELLOW}GitHub CLI (gh) ist nicht installiert.${C_RESET}"
            echo ""

            local install_cli=0
            if [ "$NON_INTERACTIVE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
                info "GitHub CLI würde jetzt installiert."
                install_cli=1
            elif ask_yes_no "Möchtest du die GitHub CLI installieren? (Empfohlen für einfachere Einrichtung)" "y"; then
                install_cli=1
            fi

            if [ "$install_cli" = "1" ]; then
                info "Installiere GitHub CLI..."

                if ghssh_install_cli && command -v gh >/dev/null 2>&1; then
                    success "GitHub CLI installiert! Starte Login..."
                    echo ""
                    echo -e "${C_YELLOW}Wähle im folgenden Dialog:${C_RESET}"
                    echo "  1. Account: GitHub.com"
                    echo "  2. Protocol: SSH"
                    echo "  3. Generate new SSH key: Yes"
                    echo "  4. Authenticate: Login with a web browser"
                    echo ""

                    if [ "$NON_INTERACTIVE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
                        info "GitHub CLI Login würde jetzt interaktiv gestartet."
                    elif sudo -u "$target_user" gh auth login; then
                        success "✅ GitHub CLI Authentifizierung erfolgreich!"
                        log_action "GITHUB_SSH" "GitHub CLI installed and auth successful"

                        if ghssh_test_connection "$target_user"; then
                            success "✅ SSH-Verbindung zu GitHub funktioniert!"
                        fi

                        echo ""
                        echo -e "${C_GREEN}Setup abgeschlossen!${C_RESET}"
                        log_action "GITHUB_SSH" "Setup completed"
                        return 0
                    fi
                else
                    warning "GitHub CLI konnte nicht installiert werden."
                fi
            fi
        fi
    fi

    # --- Weg 2: Manuelle Methode ---
    echo ""
    echo -e "${C_YELLOW}=== Manuelle SSH-Key Einrichtung ===${C_RESET}"
    echo ""

    # Prüfen ob bereits ein Key existiert
    if [ -f "$key_file" ]; then
        echo -e "${C_YELLOW}Es existiert bereits ein SSH-Key:${C_RESET}"
        echo "  Pfad: $key_file"
        echo ""

        if ask_yes_no "Möchtest du einen neuen Key generieren? (Der alte wird überschrieben)" "n"; then
            backup_time=$(date +%Y%m%d_%H%M%S)
            run_cmd mv "$key_file" "$key_file.backup_$backup_time"
            run_cmd mv "$key_file.pub" "$key_file.pub.backup_$backup_time"
            info "Alte Keys gesichert"
            generate_key=true
        fi
    else
        generate_key=true
    fi

    # Neuen Key generieren
    if [ "$generate_key" = true ]; then
        echo ""
        info "Generiere neuen ed25519 SSH-Key mit Kommentar: $key_comment"

        run_cmd mkdir -p "$ssh_dir"
        run_cmd chmod 700 "$ssh_dir"

        if ! run_cmd ssh-keygen -t ed25519 -C "$key_comment" -f "$key_file" -N ""; then
            error "SSH-Key konnte nicht erzeugt werden."
            return 2
        fi

        run_cmd chmod 600 "$key_file"
        run_cmd chmod 644 "$key_file.pub"

        [ "$target_user" != "root" ] && run_cmd chown -R "$target_user:$target_user" "$ssh_dir"

        success "✅ SSH-Key generiert: $key_comment"
        log_action "GITHUB_SSH" "SSH key generated manually: $key_comment"
    fi

    # Public Key anzeigen
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde den öffentlichen Key aus ${key_file}.pub anzeigen${C_RESET}" >&2
    elif [ -f "$key_file.pub" ]; then
        echo ""
        echo -e "${C_GREEN}=== Dein öffentlicher SSH-Key ===${C_RESET}"
        echo ""
        cat "$key_file.pub"
        echo ""
        echo -e "${C_YELLOW}Füge diesen Key bei GitHub hinzu:${C_RESET}"
        echo -e "  ${C_BLUE}https://github.com/settings/keys${C_RESET}"
        echo -e "  ${C_GREEN}\"New SSH key\" → Key einfügen → Save${C_RESET}"
        echo ""
    fi

    if ask_yes_no "Key hinzugefügt? Verbindung testen?" "y"; then
        ghssh_write_ssh_config "$ssh_dir" "$target_user"

        echo ""
        if ghssh_test_connection "$target_user"; then
            success "✅ GitHub Verbindung erfolgreich!"
            log_action "GITHUB_SSH" "Manual setup successful"
        else
            error "Verbindung fehlgeschlagen. Prüfe ob der Key korrekt hinzugefügt wurde."
        fi
    fi

    # Git konfigurieren
    echo ""
    run_cmd sudo -u "$target_user" git config --global user.name "$host_name"
    if [ -n "$git_email" ]; then
        run_cmd sudo -u "$target_user" git config --global user.email "$git_email"
    else
        warning "Keine E-Mail-Adresse ermittelbar - git user.email bleibt unverändert."
        echo "     GITHUB_EMAIL in der Config setzen, um das zu korrigieren."
    fi

    success "Git konfiguriert:"
    echo "  Username: $host_name"
    [ -n "$git_email" ] && echo "  E-Mail: $git_email"

    echo ""
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_GREEN}  Setup abgeschlossen!${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}SSH-Key:${C_RESET} $key_comment"
    echo -e "${C_BLUE}Git Commits werden als:${C_RESET} $host_name <$git_email>"
    echo ""

    log_action "GITHUB_SSH" "Manual setup completed"
    return 0
}

module_status() {
    local target_user home_dir key_file

    if ! target_user="$(ghssh_resolve_user)"; then
        echo "kein Zielbenutzer ermittelbar"
        return 0
    fi

    home_dir="$(ghssh_user_home "$target_user")"
    if [ "$target_user" != "root" ]; then
        home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
        [ -n "$home_dir" ] || home_dir="/home/$target_user"
    fi
    key_file="$home_dir/.ssh/id_ed25519"

    if [ -f "$key_file" ]; then
        if [ -f "$home_dir/.ssh/config" ] && grep -q "github.com" "$home_dir/.ssh/config" 2>/dev/null; then
            echo "Key vorhanden, ssh_config mit GitHub-Eintrag"
        else
            echo "Key vorhanden, ssh_config ohne GitHub-Eintrag"
        fi
    else
        echo "kein SSH-Key für '$target_user'"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local target_user home_dir key_file

    if ! target_user="$(ghssh_resolve_user)"; then
        echo "info|SSH-Key nicht bewertbar|kein Zielbenutzer ermittelbar - GITHUB_USERNAME, ADMIN_USER und root passen nicht"
        return 0
    fi

    home_dir="$(ghssh_user_home "$target_user")"
    if [ "$target_user" != "root" ]; then
        home_dir="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)"
        [ -n "$home_dir" ] || home_dir="/home/$target_user"
    fi
    key_file="${home_dir}/.ssh/id_ed25519"

    if [ ! -f "$key_file" ]; then
        echo "abweichung|${key_file} existiert nicht|SSH-Key fehlt für '${target_user}'"
        return 0
    fi

    if [ -f "${home_dir}/.ssh/config" ] && grep -q "github.com" "${home_dir}/.ssh/config" 2>/dev/null; then
        echo "ok|SSH-Key und GitHub-Eintrag für '${target_user}'"
    else
        echo "ok|SSH-Key für '${target_user}'|ssh_config ohne GitHub-Eintrag - Verbindung nutzt dann ~/.ssh/id_ed25519 automatisch"
    fi
    return 0
}