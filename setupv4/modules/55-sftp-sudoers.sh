#!/bin/bash
# ==============================================================================
# Modul: sftp-sudoers
# ==============================================================================
# Erlaubt dem Admin-Benutzer den passwortfreien Aufruf des SFTP-Servers.
# Benötigt wird das u.a. von SFTP-GUI-Clients (WinSCP, Cyberduck, ...), die
# intern ein 'sudo' vor dem sftp-server vorschalten.
#
# SICHERHEIT: Wer den SSH-Key dieses Benutzers besitzt, kann damit per SFTP
# alle Dateien des Servers als root lesen, schreiben und löschen. Deshalb ist
# der Schalter standardmäßig AUS.
#
# Config:
#   SFTP_SUDOERS  - Regel setzen (Default false)
#   ADMIN_USER    - Zielbenutzer (Pflicht)
#
# Der Zielbenutzer kommt aus ADMIN_USER. Das Modul 50 (users) setzt diese
# Variable zur Laufzeit und exportiert sie - dadurch wird der gerade angelegte
# Admin-Benutzer auch dann gefunden, wenn ADMIN_USER nicht in der Config
# steht. Ein in der Config gesetzter ADMIN_USER bleibt dabei erhalten.
# ==============================================================================

MODULE_ID="sftp-sudoers"
MODULE_NAME="SFTP-Sudoers-Regel"
MODULE_DESC="NOPASSWD-Regel für den sftp-server des Admin-Benutzers"
MODULE_ORDER=55
MODULE_REQUIRED_KEYS=(ADMIN_USER)
MODULE_TAGS=("sicherheit" "benutzer")

# Verzeichnis, in dem die Sudoers-Regel abgelegt wird. Überschreibbar, damit
# die Tests ohne Eingriff in /etc/sudoers.d arbeiten können.
SFTP_SUDOERS_DIR="${SFTP_SUDOERS_DIR:-/etc/sudoers.d}"

# Ermittelt den Admin-Benutzer: die zur Laufzeit gesetzte Variable hat
# Vorrang vor dem Config-Wert - sonst wäre der interaktiv angelegte
# Benutzer für dieses Modul unsichtbar.
sftp_admin_user() {
    local user="${ADMIN_USER:-}"

    [ -n "$user" ] || user="$(config_get ADMIN_USER "")"
    echo "$user"
}

# Prüft den Benutzernamen streng. Der Name landet sowohl im Dateinamen als
# auch im Sudoers-Eintrag - Leerzeichen, Zeilenumbrüche oder ein "/" wären
# ein Pfad-Traversal bzw. eine Injection in die Sudoers-Datei. Deshalb wird
# der Benutzer abgelehnt und nicht "bereinigt".
sftp_admin_user_valid() {
    local user="$1"

    [ -n "$user" ] || return 1
    [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_-]*[$]?$ ]] || return 1
    return 0
}

# Auch der Pfad zum SFTP-Server landet in der Sudoers-Regel - Leerzeichen
# oder Zeilenumbrüche würden die Datei unbrauchbar machen.
sftp_path_valid() {
    local path="$1"

    [ -n "$path" ] || return 1
    [[ "$path" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
    return 0
}

# Dateiname der Sudoers-Regel. Das "$" (Maschinenkonto) wird wie bisher
# entfernt - der Benutzername selbst ist vorher streng geprüft.
sftp_sudoers_file() {
    local user="$1"

    echo "$SFTP_SUDOERS_DIR/92-sftp-nopasswd-${user//[$]/}"
}

module_sftp_path() {
    # Pfad bevorst aus der laufenden sshd-Konfiguration, sonst über die
    # distributionsüblichen Orte.
    local sftp_path="" candidate

    sftp_path=$(sshd -T 2>/dev/null | awk '/^subsystem/ {print $3; exit}')
    if [ -z "$sftp_path" ] || [ ! -x "$sftp_path" ]; then
        for candidate in /usr/lib/openssh/sftp-server \
                         /usr/libexec/openssh/sftp-server \
                         /usr/lib/ssh/sftp-server; do
            if [ -x "$candidate" ]; then
                sftp_path="$candidate"
                break
            fi
        done
    fi

    echo "$sftp_path"
}

module_main() {
    local user
    local sftp_path
    local sudoers_file

    user="$(sftp_admin_user)"
    if [ -z "$user" ]; then
        error "Kein Admin-Benutzer ermittelt - Sudoers-Regel wird übersprungen."
        return 1
    fi

    # Der Benutzername landet im Dateinamen und in der Sudoers-Regel - ohne
    # diese Prüfung wäre ein Name mit "/" ein Pfad-Traversal und ein Name
    # mit Zeilenumbruch eine Injection in die Sudoers-Datei.
    if ! sftp_admin_user_valid "$user"; then
        error "Ungültiger Admin-Benutzername: '$user' - Sudoers-Regel wird übersprungen."
        return 2
    fi

    sftp_path="$(module_sftp_path)"
    if [ -z "$sftp_path" ]; then
        warning "SFTP-Server-Binary nicht gefunden - Sudoers-Regel wird übersprungen."
        return 1
    fi

    if ! sftp_path_valid "$sftp_path"; then
        error "Ungültiger Pfad zum SFTP-Server: '$sftp_path' - Sudoers-Regel wird übersprungen."
        return 2
    fi

    sudoers_file="$(sftp_sudoers_file "$user")"

    if [ ! -d "$SFTP_SUDOERS_DIR" ]; then
        warning "$SFTP_SUDOERS_DIR nicht vorhanden - Sudoers-Regel wird übersprungen."
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${sudoers_file}${C_RESET}" >&2
        echo "             Inhalt: ${user} ALL=(ALL) NOPASSWD: ${sftp_path}"
        return 0
    fi

    # Regel schreiben: exaktes Binary, KEIN Pfad-Wildcard
    cat > "$sudoers_file" << EOF
# Erlaubt '$user' den passwortfreien Zugriff auf den SFTP-Server (SFTP-GUI-Clients)
$user ALL=(ALL) NOPASSWD: $sftp_path
EOF

    run_cmd chmod 0440 "$sudoers_file"
    run_cmd chown root:root "$sudoers_file"
    debug "Sudoers-Regel geschrieben: $sudoers_file"

    # Prüfen, ob die Regel wirklich geschrieben wurde (sonst könnte eine
    # veraltete Datei als Erfolg durchgehen)
    if ! grep -qF "$user ALL=(ALL) NOPASSWD: $sftp_path" "$sudoers_file" 2>/dev/null; then
        error "Sudoers-Regel konnte nicht geschrieben werden - Datei wird entfernt."
        rm -f "$sudoers_file"
        return 2
    fi

    # Syntax & Berechtigungen prüfen, bei Fehler sofort zurückrollen
    if command -v visudo >/dev/null 2>&1 && ! visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
        error "Sudoers-Syntaxprüfung fehlgeschlagen - Regel wird entfernt."
        rm -f "$sudoers_file"
        return 2
    fi

    success "✅ SFTP-Sudoers-Regel für '$user' gesetzt ($sftp_path)"
    return 0
}

module_status() {
    local user file

    user="$(sftp_admin_user)"
    if [ -z "$user" ]; then
        echo "ADMIN_USER nicht gesetzt"
        return 0
    fi

    if ! sftp_admin_user_valid "$user"; then
        echo "ungültiger Admin-Benutzername"
        return 0
    fi

    file="$(sftp_sudoers_file "$user")"
    if [ -f "$file" ]; then
        echo "Regel vorhanden: $file"
    else
        echo "keine Regel für '$user'"
    fi
}

# Ziel: die NOPASSWD-Regel liegt unter /etc/sudoers.d. Ist SFTP_SUDOERS nicht
# gesetzt, gibt es bewusst kein Ziel - dann ist "keine Regel" der Sollzustand.
module_audit() {
    local user file

    if ! config_bool SFTP_SUDOERS; then
        echo "info|SFTP-Sudoers-Regel für den Admin-Benutzer|SFTP_SUDOERS ist nicht gesetzt"
        return 0
    fi

    user="$(sftp_admin_user)"
    if [ -z "$user" ]; then
        echo "info|SFTP-Sudoers-Regel für den Admin-Benutzer|ADMIN_USER ist nicht gesetzt"
        return 0
    fi

    if ! sftp_admin_user_valid "$user"; then
        echo "info|SFTP-Sudoers-Regel für den Admin-Benutzer|ungültiger Admin-Benutzername"
        return 0
    fi

    file="$(sftp_sudoers_file "$user")"

    if [ ! -d "$SFTP_SUDOERS_DIR" ]; then
        echo "abweichung|$SFTP_SUDOERS_DIR fehlt|NOPASSWD-Regel für $user"
        return 0
    fi

    if [ -f "$file" ]; then
        echo "ok|NOPASSWD-Regel für $user vorhanden"
    else
        echo "abweichung|$file fehlt|NOPASSWD-Regel für $user"
    fi
    return 0
}