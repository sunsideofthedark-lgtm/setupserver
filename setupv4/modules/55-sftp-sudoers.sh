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
# ==============================================================================

MODULE_ID="sftp-sudoers"
MODULE_NAME="SFTP-Sudoers-Regel"
MODULE_DESC="NOPASSWD-Regel für den sftp-server des Admin-Benutzers"
MODULE_ORDER=55
MODULE_REQUIRED_KEYS=(ADMIN_USER)
MODULE_TAGS=("sicherheit" "benutzer")

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
    local user="$ADMIN_USER"
    local sftp_path
    local sudoers_file="/etc/sudoers.d/92-sftp-nopasswd-${user//[$]/}"

    sftp_path="$(module_sftp_path)"
    if [ -z "$sftp_path" ]; then
        warning "SFTP-Server-Binary nicht gefunden - Sudoers-Regel wird übersprungen."
        return 1
    fi

    if [ ! -d /etc/sudoers.d ]; then
        warning "/etc/sudoers.d nicht vorhanden - Sudoers-Regel wird übersprungen."
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
    local user="$ADMIN_USER"
    local file="/etc/sudoers.d/92-sftp-nopasswd-${user//[$]/}"

    if [ -z "$user" ]; then
        echo "ADMIN_USER nicht gesetzt"
    elif [ -f "$file" ]; then
        echo "Regel vorhanden: $file"
    else
        echo "keine Regel für '$user'"
    fi
}