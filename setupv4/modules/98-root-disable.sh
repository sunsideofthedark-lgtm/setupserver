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
# 'visudo -c' geprüft und bei einem Syntaxfehler aus der Sicherung
# zurückgerollt.
#
# Config:
#   DISABLE_ROOT_LOGIN - Root-Login deaktivieren (Default true)
# ==============================================================================

MODULE_ID="root-disable"
MODULE_NAME="Root-Deaktivierung"
MODULE_DESC="Sperrt den Root-Account, verschärft sudo und räumt alte sudoers-Dateien auf"
MODULE_ORDER=98
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
        error "Sudoers-Syntaxprüfung nach Schreiben von ${ROOTDIS_SECURITY_FILE} fehlerhaft! Konfiguration wird zurückgerollt..."
        # Nicht einfach löschen: eine zuvor gültige Datei mit gleichem Namen
        # wäre damit endgültig weg. Stattdessen die letzte Sicherung zurück.
        if ! rootdis_restore_security_sudoers; then
            rm -f "$ROOTDIS_SECURITY_FILE"
            warning "Keine Sicherung vorhanden - die fehlerhafte Datei wurde entfernt."
        fi
        return 1
    fi

    debug "Sudoers-Sicherheitskonfiguration geschrieben: $ROOTDIS_SECURITY_FILE"
    return 0
}

# Stellt die letzte Sicherung der sudoers-Datei wieder her. create_backup legt
# sie als "<BACKUP_DIR>/<pfad mit _>.<timestamp>.bak" ab. Gibt es keine
# Sicherung, wird nichts wiederhergestellt - dann muss die fehlerhafte Datei
# entfernt werden, damit keine kaputte sudoers-Konfiguration liegen bleibt.
rootdis_restore_security_sudoers() {
    local backup_dir="${BACKUP_DIR:-/var/backups/serversetup}"
    local prefix newest

    prefix="$(echo "$ROOTDIS_SECURITY_FILE" | tr '/' '_')"
    newest="$(ls -1t "$backup_dir"/${prefix}.*.bak 2>/dev/null | head -n1)"

    if [ -z "$newest" ]; then
        debug "Keine Sicherung für $ROOTDIS_SECURITY_FILE unter $backup_dir gefunden."
        return 1
    fi

    if cp -p "$newest" "$ROOTDIS_SECURITY_FILE" 2>/dev/null; then
        success "Sudoers-Datei aus $newest wiederhergestellt."
        return 0
    fi

    error "Wiederherstellung der Sudoers-Datei fehlgeschlagen!"
    return 1
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

    # --- Root-Passwort bewusst NICHT leeren ---
    # "usermod --lock" stellt dem Passwort-Hash ein "!" vor und sperrt den
    # Account damit vollständig. Ein leeres Passwortfeld wäre auf Ubuntu
    # (pam_unix.so nullok) ein Einfallstor: "su root" ginge dann ohne
    # Passwort. Das Lock von usermod genügt also aus.
    debug "Root-Account ist gesperrt - der Passwort-Hash bleibt unverändert."

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

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local locked="nein"
    local missing=""

    if ! config_bool DISABLE_ROOT_LOGIN; then
        echo "info|Root nicht angefordert|DISABLE_ROOT_LOGIN ist nicht gesetzt"
        return 0
    fi

    # 'passwd -S root' meldet den Status im zweiten Feld (L = gesperrt)
    passwd -S root 2>/dev/null | awk '{print $2}' | grep -q '^L' && locked="ja"

    [ "$locked" = "ja" ] || missing="Root-Sperre"
    [ -f "$ROOTDIS_SECURITY_FILE" ] || missing="${missing}${missing:+, }$(basename "$ROOTDIS_SECURITY_FILE")"

    if [ -n "$missing" ]; then
        echo "abweichung|DISABLE_ROOT_LOGIN ist gesetzt, die Härtung ist unvollständig|fehlt: ${missing}"
        return 0
    fi

    echo "ok|Root gesperrt, sudoers-Regel aktiv"
    return 0
}