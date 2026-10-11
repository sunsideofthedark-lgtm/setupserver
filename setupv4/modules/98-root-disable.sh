#!/bin/bash
# ==============================================================================
# Modul: root-disable
# ==============================================================================
# Letzte Härtungsstufe: der Root-Account wird für den Login gesperrt, die
# sudoers-Regeln werden verschärft und alte sudoers-Dateien mit Wildcards
# werden entfernt.
#
# VORAUSSETZUNG: Es muss bereits ein nicht-root Benutzer existieren, der sudo
# benutzen kann. Diese Prüfung gehört in das Benutzerverwaltungs-Modul - vor
# diesem Modul sollte der SSH-Zugang mit einem sudo-fähigen Benutzer getestet
# sein. Wer sich hier aussperrt, kommt nur noch über die Konsole zurück.
#
# SICHERHEIT: Die sudoers-Datei wird vor dem Schreiben gesichert, mit
# 'visudo -c' geprüft und bei einem Syntaxfehler sofort wieder entfernt.
#
# Config:
#   DISABLE_ROOT_LOGIN - Root-Login deaktivieren (Default true)
# ==============================================================================

MODULE_ID="root-disable"
MODULE_NAME="Root-Deaktivierung"
MODULE_DESC="Sperrt den Root-Account, verschärft sudo und räumt alte sudoers-Dateien auf"
MODULE_ORDER=96
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit")

ROOTDIS_SECURITY_FILE="/etc/sudoers.d/90-admin-security"

# Schreibt die verschärften sudo-Defaults und prüft sie sofort mit visudo.
# Bei einem Syntaxfehler wird die Datei wieder entfernt - eine kaputte
# sudoers-Konfiguration darf unter keinen Umständen liegen bleiben.
rootdis_write_security_sudoers() {
    if [ ! -d /etc/sudoers.d ]; then
        warning "/etc/sudoers.d nicht vorhanden - sudo-Sicherheit wird übersprungen."
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${ROOTDIS_SECURITY_FILE}${C_RESET}" >&2
        return 0
    fi

    create_backup "$ROOTDIS_SECURITY_FILE"

    cat > "$ROOTDIS_SECURITY_FILE" << 'EOF'
Defaults timestamp_timeout=15
Defaults passwd_timeout=5
Defaults pwfeedback
# Defaults logfile="/var/log/sudo.log" # Deaktiviert wegen Inkompatibilität mit manchen Sudo-Parsern (z.B. sudo-rs)
# Defaults log_input, log_output       # Deaktiviert wegen Inkompatibilität mit manchen Sudo-Parsern (z.B. sudo-rs)
EOF

    # sudo akzeptiert Dateien in sudoers.d nur mit den Rechten 0440 und
    # Besitz root - ohne das schlägt die Prüfung von sudo fehl.
    run_cmd chmod 0440 "$ROOTDIS_SECURITY_FILE"
    run_cmd chown root:root "$ROOTDIS_SECURITY_FILE"

    # Sudoers-Syntax für diese spezifische Datei prüfen
    if command -v visudo >/dev/null 2>&1 && ! visudo -c -f "$ROOTDIS_SECURITY_FILE" >/dev/null 2>&1; then
        error "Sudoers-Syntaxprüfung nach Schreiben von ${ROOTDIS_SECURITY_FILE} fehlerhaft! Entferne Konfiguration..."
        rm -f "$ROOTDIS_SECURITY_FILE"
        return 1
    fi

    debug "Sudoers-Sicherheitskonfiguration geschrieben: $ROOTDIS_SECURITY_FILE"
    return 0
}

module_main() {
    if ! config_bool DISABLE_ROOT_LOGIN; then
        skip "DISABLE_ROOT_LOGIN ist nicht gesetzt - Root-Account bleibt aktiv."
        warning "⚠️  Root-Benutzer bleibt aktiv - Sicherheitsrisiko!"
        return 1
    fi

    echo ""
    info "Deaktiviere Root-Benutzer für maximale Sicherheit..."

    # --- Root-Account sperren (verhindert Login) ---
    debug "Sperre Root-Account"
    if ! run_cmd usermod --lock root; then
        error "Root-Account-Sperrung fehlgeschlagen"
        return 2
    fi

    # --- Alte/fehlerhafte sudoers-Dateien mit Wildcards aufräumen ---
    # Dateien dieser Form gewähren pauschal Rechte und sind der häufigste
    # Grund für unbeabsichtigte Rechteausweitung.
    debug "Räume alte sudoers-Dateien auf"
    run_cmd rm -f /etc/sudoers.d/91-*-srv

    # --- Erweiterte sudo-Konfiguration für bessere Sicherheit ---
    debug "Konfiguriere erweiterte sudo-Sicherheit"
    if ! rootdis_write_security_sudoers; then
        # Bewusst Abbruch: die weiteren Schritte würden die Sicherheitskonfiguration
        # in einem halb angewandten Zustand zurücklassen.
        error "Root-Deaktivierung abgebrochen - bitte sudoers-Dateien prüfen."
        return 2
    fi
    success "✅ Erweiterte sudo-Sicherheit konfiguriert"

    # --- Root-Passwort entfernen ---
    debug "Entferne Root-Passwort"
    run_cmd passwd -d root

    # --- SSH-Konfiguration validieren ---
    info "Validiere SSH-Konfiguration..."
    if ! run_cmd sshd -t; then
        error "SSH-Konfiguration ist fehlerhaft!"
        return 2
    fi

    success "✅ Root-Benutzer wurde sicher deaktiviert!"
    warning "🔒 SSH-Zugriff ist jetzt nur noch für Mitglieder der 'remotessh'-Gruppe möglich!"
    return 0
}

module_status() {
    local locked="frei"
    local sudoers="fehlt"

    # 'passwd -S root' meldet den Status im zweiten Feld (L = gesperrt)
    if passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L'; then
        locked="gesperrt"
    fi

    if [ -f "$ROOTDIS_SECURITY_FILE" ]; then
        sudoers="aktiv"
    fi

    echo "Root ${locked}, sudoers ${sudoers}"
}