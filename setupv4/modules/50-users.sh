#!/bin/bash
# ==============================================================================
# Modul: users
# ==============================================================================
# Legt den administrativen Benutzer an, richtet seinen SSH-Schlüssel ein und
# konfiguriert die Verzeichnisse, in denen er ohne sudo arbeiten kann:
#
#   ~/projects, ~/scripts, ~/backups   Arbeitsverzeichnisse
#   /srv, /opt                         Gruppenberechtigungen (Modus 2775)
#
# Optional: ein gesperrter Backup-Benutzer (nur SSH-Key) und ein geteiltes
# Verzeichnis für mehrere administrative Benutzer.
#
# Die SFTP-Sudoers-Regel macht Modul 55 - dieses Modul ruft sie NICHT auf.
#
# Exportiert für nachfolgende Module:
#   NEW_USER    - der angelegte bzw. ausgewählte Admin-Benutzer
#   LOGIN_USER  - der Benutzer, für den der SSH-Zugang einzurichten ist
#
# Config:
#   ADMIN_USER         - Benutzername des Admin-Accounts (Pflicht für nicht-interaktiv)
#   SSH_KEY_TYPE       - Typ des erzeugten Schlüssels (Default ed25519)
#   CREATE_BACKUP_USER - Backup-Benutzer anlegen (Default false)
#   DB_BACKUP_USER     - Name des Backup-Benutzers (Default dbbackup)
#   CREATE_SHARED_DIR  - geteiltes Verzeichnis einrichten (Default false)
#   SHARED_DIR         - Pfad des geteilten Verzeichnisses (Default /opt)
#   SHARED_GROUP       - Gruppe des geteilten Verzeichnisses (Default opt-admins)
# ==============================================================================

MODULE_ID="users"
MODULE_NAME="Benutzerverwaltung"
MODULE_DESC="Admin-Benutzer mit SSH-Schlüssel anlegen und /srv sowie /opt freigeben"
MODULE_ORDER=50
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("benutzer" "sicherheit")

# Vom Modul gesetzte Werte (bewusst global - alle Module werden in dieselbe
# Shell gesourct, die Namen sind deshalb mit users_ präfixt).
NEW_USER=""            # wird exportiert
LOGIN_USER=""          # wird exportiert
users_backup_created=0 # 1 = Backup-Benutzer wurde in diesem Lauf angelegt
users_passphrase=""    # nur während der Schlüsselerzeugung, danach unset

# --- Hilfsfunktionen ---

users_user_exists() {
    id "$1" >/dev/null 2>&1
}

users_home_dir() {
    local home
    home=$(getent passwd "$1" 2>/dev/null | cut -d: -f6)
    if [ -z "$home" ]; then
        home=$(eval echo "~$1")
    fi
    echo "$home"
}

# Administrative Gruppe der Distribution
users_admin_group() {
    case "$OS_ID" in
        ubuntu|debian) echo "sudo" ;;
        *)             echo "wheel" ;;
    esac
}

# Dateiname des privaten Schlüssels zum gewählten Schlüsseltyp
users_key_suffix() {
    case "$1" in
        ed25519) echo "ed25519" ;;
        rsa)     echo "rsa" ;;
        ecdsa)   echo "ecdsa" ;;
        *)       echo "$1" ;;
    esac
}

# Erzeugt die SSH-Zugriffsgruppe - sie ist die Grundlage für AllowGroups
users_ensure_remotessh_group() {
    info "Erstelle spezielle SSH-Zugriffs-Gruppe 'remotessh'..."
    debug "Erstelle remotessh-Gruppe"

    if getent group remotessh >/dev/null 2>&1; then
        warning "Gruppe 'remotessh' existiert bereits."
        return 0
    fi

    if ! run_cmd groupadd remotessh; then
        error "Erstellung der remotessh-Gruppe fehlgeschlagen"
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        success "Gruppe 'remotessh' würde erstellt."
    else
        success "Gruppe 'remotessh' wurde erstellt."
    fi
    return 0
}

# adduser gibt es nur auf Debian/Ubuntu und fragt dort interaktiv nach
#vollständigem Namen und Passwort ab - genau dieses Verhalten wird beibehalten.
users_add_user() {
    local user="$1"

    if command -v adduser >/dev/null 2>&1; then
        run_cmd adduser "$user"
    else
        run_cmd useradd -m -s /bin/bash "$user"
    fi
}

# Löscht einen Benutzer samt Home-Verzeichnis und aller Spuren
users_delete_user() {
    local user="$1"

    # Bestehenden Benutzer komplett löschen mit vollständiger Bereinigung
    debug "Lösche Benutzer '$user' und alle zugehörigen Daten"

    # Benutzer-Prozesse beenden (falls vorhanden)
    debug "Beende alle Prozesse von Benutzer '$user'"
    run_cmd pkill -u "$user" 2>/dev/null || true
    run_cmd sleep 1

    # Benutzer aus allen zusätzlichen Gruppen entfernen
    debug "Entferne Benutzer aus allen Gruppen"
    local group
    for group in sudo wheel remotessh users; do
        run_cmd gpasswd -d "$user" "$group" 2>/dev/null || true
    done

    if [ "$DRY_RUN" != "1" ]; then
        # Benutzer und Home-Verzeichnis löschen
        if userdel -r "$user" 2>/dev/null; then
            success "Bestehender Benutzer '$user' wurde komplett gelöscht."
        else
            warning "Benutzer-Löschung teilweise fehlgeschlagen, bereinige manuell..."

            # Manuelle Bereinigung
            if [ -d "/home/$user" ]; then
                debug "Entferne Home-Verzeichnis manuell"
                rm -rf "/home/$user"
            fi

            # Mail-Spool bereinigen
            [ -f "/var/mail/$user" ] && rm -f "/var/mail/$user"
            [ -f "/var/spool/mail/$user" ] && rm -f "/var/spool/mail/$user"

            # Cron-Jobs bereinigen
            crontab -r -u "$user" 2>/dev/null || true
        fi
    fi

    # Sicherstellen, dass Benutzer nicht mehr existiert
    if users_user_exists "$user"; then
        error "Benutzer '$user' konnte nicht vollständig entfernt werden."
        return 1
    fi

    success "Alter Benutzer wurde erfolgreich bereinigt. Erstelle nun neuen Benutzer..."
    return 0
}

# Fragt den Namen des neu anzulegenden Benutzers ab und bereinigt einen
# eventuell vorhandenen Altbestand (Schleife wie im Original).
users_ask_new_username() {
    while true; do
        if ! ask_value "Bitte geben Sie den Benutzernamen für den neuen Benutzer ein" "" NEW_USER; then
            return 1
        fi
        debug "Benutzer-Eingabe für neuen Benutzer: '$NEW_USER'"

        if [ -z "$NEW_USER" ]; then
            warning "Benutzername darf nicht leer sein."
            continue
        fi

        if ! validate_username "$NEW_USER"; then
            error "Ungültiger Benutzername: '$NEW_USER'"
            warning "Benutzername-Regeln:"
            warning "• Nur Kleinbuchstaben (a-z), Zahlen (0-9), Unterstriche (_) und Bindestriche (-)"
            warning "• Muss mit Buchstabe oder Unterstrich beginnen"
            warning "• Maximal 32 Zeichen lang"
            warning "• Keine reservierten Systemnamen"
            continue
        fi

        if users_user_exists "$NEW_USER"; then
            warning "Benutzer '$NEW_USER' existiert bereits."
            if ask_yes_no "Soll der bestehende Benutzer gelöscht und neu erstellt werden?" "n"; then
                info "Lösche bestehenden Benutzer und erstelle ihn neu mit frischem SSH-Schlüssel..."
                users_delete_user "$NEW_USER" || return 1
            else
                error "Benutzererstellung abgebrochen."
                continue
            fi
        fi

        break
    done
    return 0
}

users_ask_existing_username() {
    if ! ask_value "Bitte geben Sie den Namen eines existierenden sudo-Benutzers an, für den SSH konfiguriert werden soll" "" NEW_USER; then
        return 1
    fi
    debug "Benutzer-Eingabe für existierenden Benutzer: '$NEW_USER'"

    if ! users_user_exists "$NEW_USER"; then
        error "Benutzer '$NEW_USER' nicht gefunden."
        return 1
    fi
    return 0
}

users_ask_passphrase() {
    local confirm_input=""

    users_passphrase=""
    if [ "$NON_INTERACTIVE" = "1" ]; then
        info "SSH-Schlüssel wird ohne Passwort erstellt (für automatische Verbindungen)."
        return 0
    fi

    if ! ask_yes_no "Soll der SSH-Schlüssel mit einem Passwort geschützt werden?" "n"; then
        info "SSH-Schlüssel wird ohne Passwort erstellt (für automatische Verbindungen)."
        return 0
    fi

    info "Ein Passwort erhöht die Sicherheit, erfordert aber eine Eingabe bei jeder SSH-Verbindung."
    while true; do
        echo -e "${C_CYAN}SSH-Schlüssel Passwort eingeben: ${C_RESET}" >&2
        read -rs users_passphrase || users_passphrase=""
        echo "" >&2
        echo -e "${C_CYAN}Passwort bestätigen: ${C_RESET}" >&2
        read -rs confirm_input || confirm_input=""
        echo "" >&2

        if [ "$users_passphrase" != "$confirm_input" ]; then
            error "Passwörter stimmen nicht übereen."
            continue
        fi

        if [ ${#users_passphrase} -ge 8 ]; then
            success "Passwort akzeptiert."
            break
        fi

        error "Passwort muss mindestens 8 Zeichen lang sein."
    done

    unset confirm_input
    return 0
}

# Zeigt den erzeugten Schlüssel an und löscht den privaten Teil wieder
users_show_ssh_keys() {
    local user="$1"
    local home="$2"
    local key_file="$3"
    local private_key="$home/.ssh/$key_file"
    local public_key="$private_key.pub"

    if [ "$DRY_RUN" = "1" ] || [ ! -f "$private_key" ]; then
        warning "Schlüssel-Details werden im Trockenlauf nicht angezeigt (es wurde kein Schlüssel erzeugt)."
        return 0
    fi

    info "=== SSH-Schlüssel-Information ==="

    # PuTTY-ähnliche Darstellung
    echo -e "${C_BLUE}SSH-Schlüssel-Details (ähnlich PuTTY-Format):${C_RESET}"
    echo "============================================================"
    echo "Key-Type: $(awk '{print $1}' "$public_key" 2>/dev/null)"
    echo "OS: $OS_NAME"
    echo "Comment: ${user}@$(hostname)-$(date +%Y%m%d)"
    echo "Public-Key:"
    awk '{print $2}' "$public_key" | fold -w 64
    echo ""
    echo "Key-Fingerprint:"
    ssh-keygen -lf "$public_key"
    echo "Key-Randomart:"
    ssh-keygen -lvf "$public_key" | tail -n +2
    echo "============================================================"
    echo ""

    echo -e "${C_BLUE}Öffentlicher SSH-Schlüssel (für authorized_keys):${C_RESET}"
    echo "------------------------------------------------------------"
    cat "$public_key"
    echo "------------------------------------------------------------"
    echo ""

    echo -e "${C_BLUE}Privater SSH-Schlüssel (OpenSSH-Format):${C_RESET}"
    echo -e "${C_RED}⚠️ WARNUNG: Kopieren Sie diesen Schlüssel SOFORT an einen sicheren Ort!${C_RESET}"
    echo "------------------------------------------------------------"
    cat "$private_key"
    echo "------------------------------------------------------------"
    echo ""

    # Zusätzliche Informationen für Windows/PuTTY-Benutzer
    echo -e "${C_YELLOW}💡 Für Windows/PuTTY-Benutzer:${C_RESET}"
    echo "     1. Kopieren Sie den privaten Schlüssel (oben)"
    echo "     2. Speichern Sie ihn als Textdatei (z.B. server_key.pem)"
    echo "     3. Verwenden Sie PuTTYgen: Load → Conversions → Export OpenSSH key"
    echo "     4. Oder nutzen Sie den privaten Schlüssel direkt mit modernen SSH-Clients"
    echo ""

    warning "WICHTIG: Notieren oder kopieren Sie den privaten Schlüssel JETZT!"
    echo -e "${C_RED}Der private Schlüssel wird nach dieser Anzeige aus Sicherheitsgründen gelöscht!${C_RESET}"

    if ! confirm "Haben Sie den privaten Schlüssel gesichert und möchten fortfahren?" "n"; then
        error "Setup wird abgebrochen. Privater Schlüssel bleibt temporär erhalten."
        return 1
    fi

    # Privaten Schlüssel aus Home-Verzeichnis löschen (Sicherheit)
    debug "Lösche privaten Schlüssel aus Sicherheitsgründen"
    rm -f "$private_key"
    success "Privater Schlüssel wurde aus Sicherheitsgründen vom Server gelöscht."
    warning "Sie können sich nur noch mit dem kopierten privaten Schlüssel anmelden!"
    return 0
}

users_setup_ssh_key() {
    local user="$1"
    local home key_type key_file

    home="$(users_home_dir "$user")"

    # Im Dry-Run wurde der Benutzer nicht wirklich angelegt - das Home-
    # Verzeichnis existiert dann zwangsläufig noch nicht. Ohne diesen Zweig
    # würde der Trockenlauf hier abbruch.
    if [ "$DRY_RUN" = "1" ] && { [ -z "$home" ] || [ ! -d "$home" ]; }; then
        home="/home/$user"
        echo -e "${C_MAGENTA}[DRY-RUN] würde SSH-Schlüssel in ${home}/.ssh erzeugen${C_RESET}" >&2
        return 0
    fi

    if [ -z "$home" ] || [ ! -d "$home" ]; then
        error "Home-Verzeichnis für '$user' konnte nicht ermittelt werden."
        return 1
    fi

    key_type="$(config_get SSH_KEY_TYPE ed25519)"
    key_file="id_$(users_key_suffix "$key_type")"

    info "Generiere SSH-Schlüsselpaar für Benutzer '$user'..."
    debug "Benutzer-Home-Verzeichnis: $home"

    # SSH-Verzeichnis erstellen falls nicht vorhanden
    debug "Erstelle SSH-Verzeichnis: $home/.ssh"
    run_cmd sudo -u "$user" mkdir -p "$home/.ssh"
    run_cmd sudo -u "$user" chmod 700 "$home/.ssh"

    # Ein vorhandener Schlüssel wird nie überschrieben - der Benutzer soll
    # entscheiden, was mit dem alten Schlüssel passiert.
    if [ -f "$home/.ssh/$key_file" ]; then
        error "Es existiert bereits ein Schlüssel: $home/.ssh/$key_file"
        echo "     Der Schlüssel wird nicht überschrieben. Bitte zuerst sichern und entfernen."
        return 1
    fi

    debug "Generiere ${key_type}-Schlüsselpaar"
    users_ask_passphrase

    if ! run_cmd sudo -u "$user" ssh-keygen -t "$key_type" -f "$home/.ssh/$key_file" -N "$users_passphrase" -C "$user@$(hostname)"; then
        error "SSH-Schlüssel-Generierung fehlgeschlagen"
        unset users_passphrase
        return 1
    fi
    unset users_passphrase

    # Öffentlichen Schlüssel zu authorized_keys hinzufügen
    debug "Füge öffentlichen Schlüssel zu authorized_keys hinzu"
    if ! run_cmd sudo -u "$user" cp "$home/.ssh/$key_file.pub" "$home/.ssh/authorized_keys"; then
        error "Authorized_keys-Konfiguration fehlgeschlagen"
        return 1
    fi

    # Korrekte Berechtigungen setzen
    debug "Setze SSH-Verzeichnis-Berechtigungen"
    run_cmd sudo -u "$user" chmod 700 "$home/.ssh"
    run_cmd sudo -u "$user" chmod 600 "$home/.ssh/$key_file"
    run_cmd sudo -u "$user" chmod 644 "$home/.ssh/$key_file.pub"
    run_cmd sudo -u "$user" chmod 600 "$home/.ssh/authorized_keys"

    users_show_ssh_keys "$user" "$home" "$key_file" || return 1
    return 0
}

users_prepare_workdirs() {
    local user="$1"
    local home dir
    local work_dirs=()

    home="$(users_home_dir "$user")"
    work_dirs=("$home/projects" "$home/scripts" "$home/backups")

    info "Erstelle sichere Arbeitsverzeichnisse für Benutzer '$user'..."

    for dir in "${work_dirs[@]}"; do
        debug "Erstelle Arbeitsverzeichnis: $dir"
        run_cmd sudo -u "$user" mkdir -p "$dir"
        run_cmd sudo -u "$user" chmod 755 "$dir"
    done
    return 0
}

# Gruppenberechtigung für /srv und /opt - bewusst über die Gruppenzugehörigkeit
# des Benutzers statt über sudoers-Regeln.
users_setup_srv_opt() {
    local user="$1"

    info "Konfiguriere direkte Gruppenberechtigungen für /srv..."
    run_cmd mkdir -p /srv
    run_cmd chown "root:$user" /srv
    run_cmd chmod 2775 /srv

    info "Konfiguriere direkte Gruppenberechtigungen für /opt..."
    run_cmd mkdir -p /opt
    run_cmd chown -R "root:$user" /opt
    run_cmd chmod -R 2775 /opt
    if command -v setfacl &>/dev/null; then
        run_eval "setfacl -R -m g:$user:rwx,d:g:$user:rwx /opt 2>/dev/null || true"
    fi

    # Alte/fehlerhafte sudoers-Dateien aufräumen, um Sudo-Parserfehler zu beheben
    if [ -d /etc/sudoers.d ]; then
        run_cmd rm -f /etc/sudoers.d/91-*-srv
        run_cmd rm -f /etc/sudoers.d/91-*-opt
    fi

    success "✅ Berechtigungen für '/srv' konfiguriert (Gruppe '$user', Mode 2775)"
    info "     Benutzer kann nun 'mkdir -p /srv/projektname' direkt ohne sudo verwenden"

    success "✅ Berechtigungen für '/opt' konfiguriert (Gruppe '$user', Mode 2775)"
    info "     Benutzer kann nun in '/opt' Dateien/Ordner erstellen, bearbeiten und löschen (ohne sudo)"
    return 0
}

users_create_new() {
    local user="$1"
    local admin_group

    debug "Erstelle neuen Benutzer: $user"
    if ! users_add_user "$user"; then
        error "Benutzer-Erstellung fehlgeschlagen"
        return 2
    fi

    if [ "$DRY_RUN" = "1" ]; then
        success "Benutzer '$user' würde erstellt."
    else
        success "Neuer Benutzer '$user' wurde erfolgreich erstellt."
    fi

    # SSH-Gruppe erstellen für erweiterte Sicherheit
    users_ensure_remotessh_group || return 2

    # Zur entsprechenden Admin-Gruppe hinzufügen (je nach Distribution)
    admin_group="$(users_admin_group)"

    debug "Füge Benutzer zur $admin_group-Gruppe hinzu"
    if ! run_cmd usermod -aG "$admin_group" "$user"; then
        error "Hinzufügung zur $admin_group-Gruppe fehlgeschlagen"
        return 2
    fi

    debug "Füge Benutzer zur remotessh-Gruppe hinzu"
    if ! run_cmd usermod -aG remotessh "$user"; then
        error "Hinzufügung zur remotessh-Gruppe fehlgeschlagen"
        return 2
    fi

    success "Benutzer '$user' wurde erstellt und zu den Gruppen '$admin_group' und 'remotessh' hinzugefügt."

    # Passwort für den Benutzer setzen (optional)
    # Auf Debian/Ubuntu wird das Passwort bereits interaktiv von 'adduser' abgefragt.
    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        if ask_yes_no "Möchten Sie ein Passwort für den Benutzer '$user' setzen?" "n"; then
            info "Setzen Sie ein starkes Passwort für '$user':"
            if ! run_cmd passwd "$user"; then
                error "Passwort-Setzung fehlgeschlagen"
                return 2
            fi
            success "Passwort für '$user' wurde gesetzt."
        else
            info "Kein Passwort gesetzt. Benutzer kann sich nur mit SSH-Schlüssel anmelden."
        fi
    else
        debug "Überspringe separate Passwortabfrage (wurde von 'adduser' erledigt)"
    fi

    # Root-Benutzer wird am Ende des Setups automatisch deaktiviert
    info "Root-Benutzer wird am Ende der Konfiguration automatisch deaktiviert."
    warning "WICHTIG: Nach der SSH-Konfiguration wird der Root-Zugang vollständig gesperrt."

    users_setup_ssh_key "$user" || return 2

    # Sichere Arbeitsverzeichnisse erstellen
    users_prepare_workdirs "$user"

    # /srv- und /opt-Berechtigungen
    users_setup_srv_opt "$user"

    success "✅ Arbeitsverzeichnisse für '$user' wurden eingerichtet:"
    echo "     • ~/projects/ - Für Entwicklungsprojekte"
    echo "     • ~/scripts/  - Für persönliche Scripts"
    echo "     • ~/backups/  - Für lokale Backups"
    echo "     • /srv/       - Direkt beschreibbar für Projekte (ohne sudo)"
    echo "     • /opt/       - Direkt beschreibbar für Anwendungen & Software (ohne sudo)"
    return 0
}

# Zweig "Benutzer existiert bereits": kein neuer Schlüssel, keine sudo-Gruppe,
# aber remotessh und die Verzeichnisberechtigungen werden gesetzt.
users_use_existing() {
    local user="$1"

    users_ensure_remotessh_group || return 2

    # Bestehenden Benutzer zur remotessh-Gruppe hinzufügen
    debug "Füge existierenden Benutzer zur remotessh-Gruppe hinzu"
    if ! run_cmd usermod -aG remotessh "$user"; then
        error "Hinzufügung zur remotessh-Gruppe fehlgeschlagen"
        return 2
    fi

    success "Benutzer '$user' wurde zur 'remotessh'-Gruppe hinzugefügt."

    # Direktzugriff auf /srv und /opt für bestehenden Benutzer konfigurieren
    info "Konfiguriere direkte Gruppenberechtigungen für /srv und /opt..."
    run_cmd mkdir -p /srv /opt
    run_cmd chown "root:$user" /srv
    run_cmd chmod 2775 /srv
    run_cmd chown -R "root:$user" /opt
    run_cmd chmod -R 2775 /opt
    if command -v setfacl &>/dev/null; then
        run_eval "setfacl -R -m g:$user:rwx,d:g:$user:rwx /opt 2>/dev/null || true"
    fi
    success "✅ Berechtigungen für '/srv' und '/opt' für Benutzer '$user' konfiguriert."
    return 0
}

# Fragt den SSH-Public-Key für den Backup-Benutzer ab. Das Ergebnis wird in
# users_db_key abgelegt (bewusst global) - eine Command-Substitution würde die
# Ausgaben der Fragefunktionen mit einsammeln.
users_db_key=""

users_ask_dbbackup_key() {
    local user="$1"
    local key=""

    users_db_key=""
    while true; do
        # Ohne TTY gibt es keine sinnvolle Frage - dann überspringen statt
        # endlos nachzufragen.
        if [ "$NON_INTERACTIVE" = "1" ]; then
            warning "Kein SSH-Public-Key für '$user' angegeben - nicht-interaktiver Modus ohne Schlüssel."
            return 1
        fi

        echo -e "${C_CYAN}Bitte kopieren Sie den SSH Public Key für '$user' (z.B. ssh-ed25519 AAA...):${C_RESET}" >&2
        read -r key || key=""

        if [ -z "$key" ]; then
            warning "Der SSH Public Key darf nicht leer sein."
            continue
        fi

        # Einfache Validierung (sollte mit ssh- oder ecdsa- beginnen)
        if [[ "$key" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]]; then
            users_db_key="$key"
            return 0
        fi

        warning "Ungültiges SSH-Key-Format. Bitte stellen Sie sicher, dass der Key mit einem gültigen Typ beginnt (z.B. ssh-ed25519 oder ssh-rsa)."
    done
}

users_setup_backup_user() {
    local db_user db_home db_key auth_keys

    db_user="$(config_get DB_BACKUP_USER dbbackup)"
    echo ""

    if ! config_bool CREATE_BACKUP_USER; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "CREATE_BACKUP_USER ist nicht gesetzt - kein Backup-Benutzer."
            users_backup_created=0
            return 0
        fi
        if ! ask_yes_no "Soll ein Backup-Benutzer '$db_user' (nur SSH-Key-Authentifizierung) erstellt werden?" "n"; then
            users_backup_created=0
            return 0
        fi
    fi

    info "Erstelle Backup-Benutzer '$db_user'..."

    # Falls Benutzer bereits existiert, optional neu anlegen
    if users_user_exists "$db_user"; then
        warning "Benutzer '$db_user' existiert bereits."
        if ask_yes_no "Soll der bestehende Benutzer '$db_user' gelöscht und neu erstellt werden?" "n"; then
            run_cmd pkill -u "$db_user" 2>/dev/null || true
            run_cmd sleep 1
            run_cmd userdel -r "$db_user" 2>/dev/null || true
            success "Bestehender Benutzer '$db_user' wurde gelöscht."
        fi
    fi

    if ! users_user_exists "$db_user"; then
        # Benutzer ohne Passwort erstellen (gesperrter Account für Passwort-Login)
        if ! run_cmd useradd -m -s /bin/bash -p '*' "$db_user"; then
            error "Erstellung des Benutzers '$db_user' fehlgeschlagen"
            return 1
        fi
        success "Benutzer '$db_user' wurde erfolgreich erstellt."
    fi

    # Zur remotessh-Gruppe hinzufügen
    if ! run_cmd usermod -aG remotessh "$db_user"; then
        error "Hinzufügen von '$db_user' zur remotessh-Gruppe fehlgeschlagen"
        return 1
    fi
    success "Benutzer '$db_user' zur 'remotessh'-Gruppe hinzugefügt."

    # SSH-Verzeichnis konfigurieren
    db_home="$(users_home_dir "$db_user")"
    run_cmd mkdir -p "$db_home/.ssh"
    run_cmd chmod 700 "$db_home/.ssh"
    run_cmd chown "$db_user:$db_user" "$db_home/.ssh"

    # SSH Public Key abfragen
    if ! users_ask_dbbackup_key "$db_user"; then
        warning "Backup-Benutzer '$db_user' bleibt ohne SSH-Schlüssel - Anmeldung ist so nicht möglich."
        return 0
    fi
    auth_keys="$db_home/.ssh/authorized_keys"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${auth_keys}${C_RESET}" >&2
        echo "     Inhalt: <öffentlicher Schlüssel von '$db_user'>" >&2
    else
        create_backup "$auth_keys"
        printf '%s\n' "$users_db_key" > "$auth_keys"
        run_cmd chmod 600 "$auth_keys"
        run_cmd chown "$db_user:$db_user" "$auth_keys"
    fi
    success "SSH Public Key für '$db_user' wurde erfolgreich hinterlegt."

    users_backup_created=1
    return 0
}

users_setup_shared_dir() {
    local shared_dir shared_group group_user db_user
    local u skip_user already add_user
    local group_users=()
    local system_users available_users=()
    local add_users_input additional

    echo ""

    if ! config_bool CREATE_SHARED_DIR; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "CREATE_SHARED_DIR ist nicht gesetzt - kein geteiltes Verzeichnis."
            return 0
        fi
        if ! ask_yes_no "Soll ein geteiltes Verzeichnis für administrative Benutzergruppen eingerichtet werden?" "n"; then
            return 0
        fi
    fi

    info "Konfiguriere geteiltes Verzeichnis..."

    # Verzeichnispfad und Gruppenname aus der Config, sonst nachfragen
    shared_dir="$(config_get SHARED_DIR /opt)"
    shared_group="$(config_get SHARED_GROUP opt-admins)"

    if [ "$NON_INTERACTIVE" != "1" ]; then
        while true; do
            ask_value "Bitte geben Sie den Pfad des geteilten Verzeichnisses an" "$shared_dir" shared_dir || return 1
            # Pfad muss absolut sein
            if [[ "$shared_dir" =~ ^/ ]]; then
                break
            fi
            warning "Der Pfad muss absolut sein (mit / beginnen)."
        done

        while true; do
            ask_value "Bitte geben Sie den Namen der neuen Admin-Gruppe an" "$shared_group" shared_group || return 1
            if [[ "$shared_group" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                break
            fi
            warning "Ungültiger Gruppenname. Nur Buchstaben, Zahlen, Bindestriche und Unterstriche erlaubt."
        done
    fi

    # Gruppe erstellen
    if ! getent group "$shared_group" >/dev/null; then
        if ! run_cmd groupadd "$shared_group"; then
            error "Erstellung der Gruppe '$shared_group' fehlgeschlagen"
            return 1
        fi
        success "Gruppe '$shared_group' wurde erfolgreich erstellt."
    else
        warning "Gruppe '$shared_group' existiert bereits."
    fi

    # Standardbenutzer hinzufügen
    db_user="$(config_get DB_BACKUP_USER dbbackup)"
    group_users=("root" "$NEW_USER")
    if [ "$users_backup_created" = "1" ] || users_user_exists "$db_user"; then
        group_users+=("$db_user")
    fi

    # Weitere Benutzer abfragen
    # Liste aller Systembenutzer mit UID >= 1000 ermitteln (ohne nobody)
    if [ "$NON_INTERACTIVE" != "1" ]; then
        system_users=($(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd))
        # Bereits ausgewählte Benutzer ausschließen
        for u in "${system_users[@]}"; do
            skip_user=0
            for already in "${group_users[@]}"; do
                if [ "$u" = "$already" ]; then
                    skip_user=1
                    break
                fi
            done
            [ "$skip_user" = "0" ] && available_users+=("$u")
        done

        if [ ${#available_users[@]} -gt 0 ]; then
            echo -e "${C_BLUE}Verfügbare zusätzliche Systembenutzer:${C_RESET} ${available_users[*]}"
            ask_value "Möchten Sie zusätzliche Benutzer zur Gruppe '$shared_group' hinzufügen? (kommagetrennt, leer lassen für keine)" "" add_users_input || return 1
            if [ -n "$add_users_input" ]; then
                IFS=',' read -ra additional <<< "$add_users_input"
                for add_user in "${additional[@]}"; do
                    # Whitespace trimmen
                    add_user="$(echo "$add_user" | xargs)"
                    if users_user_exists "$add_user"; then
                        group_users+=("$add_user")
                    else
                        warning "Benutzer '$add_user' existiert nicht und wird übersprungen."
                    fi
                done
            fi
        fi
    fi

    # Benutzer der Gruppe hinzufügen
    info "Füge Benutzer zur Gruppe '$shared_group' hinzu..."
    for group_user in "${group_users[@]}"; do
        debug "Füge $group_user zu $shared_group hinzu"
        if run_cmd usermod -aG "$shared_group" "$group_user"; then
            success "Benutzer '$group_user' zur Gruppe '$shared_group' hinzugefügt."
        else
            warning "Fehler beim Hinzufügen von '$group_user' zur Gruppe '$shared_group'."
        fi
    done

    # Verzeichnis erstellen falls nicht vorhanden
    run_cmd mkdir -p "$shared_dir"

    # 1. Eigentümer auf root und Gruppe auf $shared_group setzen
    info "Setze Eigentümer von $shared_dir auf root:$shared_group..."
    run_cmd chown -R "root:$shared_group" "$shared_dir"

    # 2. Schreib- und Leserechte für den Eigentümer (root) und die Gruppe geben,
    #    SGID-Bit setzen (chmod 2775 oder g+s)
    info "Konfiguriere Berechtigungen (Mode 2775 / SGID) für $shared_dir..."
    run_cmd chmod -R 2775 "$shared_dir"

    # Falls setfacl vorhanden, Standard-ACLs setzen
    if command -v setfacl &>/dev/null; then
        debug "Konfiguriere ACLs für $shared_dir"
        run_eval "setfacl -R -m g:$shared_group:rwx,d:g:$shared_group:rwx '$shared_dir' 2>/dev/null || true"
    fi

    success "✅ Geteiltes Verzeichnis '$shared_dir' wurde für die Gruppe '$shared_group' konfiguriert."
    info "     Mitglieder: ${group_users[*]}"
    info "     Berechtigungen: Besitzer: root, Gruppe: $shared_group, Mode: 2775 (SGID)"
    return 0
}

# --- Modul ---

module_main() {
    local mode=""

    NEW_USER="$(config_get ADMIN_USER "")"

    if [ -n "$NEW_USER" ]; then
        if users_user_exists "$NEW_USER"; then
            info "Benutzer '$NEW_USER' (ADMIN_USER) existiert bereits."
            if [ "$NON_INTERACTIVE" = "1" ] \
               || ! ask_yes_no "Soll der bestehende Benutzer '$NEW_USER' gelöscht und neu erstellt werden? (Es wird ein neuer SSH-Schlüssel erzeugt)" "n"; then
                mode="bestehend"
            else
                users_delete_user "$NEW_USER" || return 2
                mode="neu"
            fi
        else
            info "Zielbenutzer aus der Config: '$NEW_USER'"
            mode="neu"
        fi
    else
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "ADMIN_USER ist nicht gesetzt - nicht-interaktiver Modus ohne Benutzerangabe."
            return 1
        fi

        if ask_yes_no "Soll ein neuer Benutzer mit sudo-Rechten angelegt werden?" "n"; then
            info "Neuen administrativen Benutzer anlegen"
            users_ask_new_username || return 2
            mode="neu"
        else
            warning "Erstellung eines neuen Benutzers übersprungen."
            # Fallback, falls kein neuer Benutzer erstellt wird
            users_ask_existing_username || return 2
            mode="bestehend"
        fi
    fi

    case "$mode" in
        neu)
            users_create_new "$NEW_USER" || return $?
            ;;
        bestehend)
            users_use_existing "$NEW_USER" || return $?
            ;;
    esac

    # Für nachfolgende Module bereitstellen
    LOGIN_USER="$NEW_USER"
    export NEW_USER LOGIN_USER
    debug "NEW_USER=$NEW_USER LOGIN_USER=$LOGIN_USER"

    # Backup-Benutzer und geteiltes Verzeichnis
    users_setup_backup_user || return $?
    users_setup_shared_dir || return $?

    echo ""
    success "✅ Benutzerverwaltung abgeschlossen für '$NEW_USER'."
    return 0
}

module_status() {
    local user admin_group shared_group
    local details=""

    user="$(config_get ADMIN_USER "")"
    if [ -z "$user" ]; then
        echo "kein ADMIN_USER gesetzt"
        return 0
    fi

    if ! users_user_exists "$user"; then
        echo "$user existiert nicht"
        return 0
    fi

    admin_group="$(users_admin_group)"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$admin_group" \
        && details="$admin_group" || details="kein $admin_group"

    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx remotessh \
        && details="$details+remotessh" || details="$details, kein remotessh"

    shared_group="$(config_get SHARED_GROUP opt-admins)"
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$shared_group"; then
        details="$details+$shared_group"
    fi

    echo "$user: $details"
}

# Ziel: ADMIN_USER existiert und ist Mitglied in der Admin-Gruppe der
# Distribution sowie in 'remotessh' - Letzteres ist die Voraussetzung für
# AllowGroups in der SSH-Härtung. Fehlende Gruppen sammeln sich im Detail.
module_audit() {
    local user admin_group missing=""

    user="$(config_get ADMIN_USER "")"
    if [ -z "$user" ]; then
        echo "info|Admin-Benutzer mit sudo und remotessh|ADMIN_USER ist nicht in der Config gesetzt"
        return 0
    fi

    admin_group="$(users_admin_group)"

    if ! users_user_exists "$user"; then
        echo "abweichung|Benutzer existiert nicht|Benutzer $user in $admin_group + remotessh"
        return 0
    fi

    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$admin_group" \
        || missing="$admin_group"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx remotessh \
        || missing="${missing:+$missing, }remotessh"

    if [ -z "$missing" ]; then
        echo "ok|Benutzer $user in $admin_group + remotessh"
    else
        echo "abweichung|nicht Mitglied in: $missing|Benutzer $user in $admin_group + remotessh"
    fi
    return 0
}