#!/bin/bash
# ==============================================================================
# Modul: maintenance
# ==============================================================================
# Richtet die wiederkehrenden Wartungsaufgaben ein: Log-Rotation für die
# Systemlogs und ein täglicher Disk-Space-Cronjob, der bei vollen Partitionen
# eine Warnung ins Syslog schreibt.
#
# Beide Teile haben einen eigenen Schalter. Ist keiner gesetzt, ist das Modul
# nicht anwendbar.
#
# Config:
#   MAINTENANCE_LOGROTATE   - Log-Rotation konfigurieren (Default true)
#   MAINTENANCE_DISK_MONITOR - Disk-Space-Monitor + Cronjob (Default true)
# ==============================================================================

MODULE_ID="maintenance"
MODULE_NAME="System-Wartung"
MODULE_DESC="Log-Rotation und täglichen Disk-Space-Monitor per Cronjob einrichten"
MODULE_ORDER=97
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("wartung")

MAINT_LOGROTATE_FILE="/etc/logrotate.d/custom-server"
MAINT_DISK_SCRIPT="/usr/local/bin/disk-space-monitor.sh"
# Täglich um 02:00 - die Nacht ist der ruhigste Zeitpunkt für einen
# Festplattenlauf über alle Partitionen.
MAINT_DISK_CRON_JOB="0 2 * * * /usr/local/bin/disk-space-monitor.sh"

# Log-Rotation für die Systemlogs
maint_configure_logrotate() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${MAINT_LOGROTATE_FILE}${C_RESET}" >&2
        return 0
    fi

    create_backup "$MAINT_LOGROTATE_FILE"

    cat > "$MAINT_LOGROTATE_FILE" << 'EOF'
/var/log/auth.log
/var/log/secure
/var/log/messages {
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    copytruncate
    maxage 365
}
/var/log/fail2ban.log {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

    debug "Log-Rotation geschrieben: $MAINT_LOGROTATE_FILE"
    return 0
}

# Erstellt das Monitoring-Skript für den Festplattenfüllstand
maint_write_disk_monitor() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${MAINT_DISK_SCRIPT}${C_RESET}" >&2
        return 0
    fi

    create_backup "$MAINT_DISK_SCRIPT"

    cat > "$MAINT_DISK_SCRIPT" << 'EOF'
#!/bin/bash
THRESHOLD=90
df -H | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 " " $1 }' | while read output;
do
    usep=$(echo $output | awk '{ print $1}' | cut -d'%' -f1)
    partition=$(echo $output | awk '{ print $2 }')
    if [ $usep -ge $THRESHOLD ]; then
        echo "WARNING: Partition $partition is ${usep}% full on $(hostname) as on $(date)"
    fi
done
EOF

    if ! run_cmd chmod +x "$MAINT_DISK_SCRIPT"; then
        return 1
    fi

    debug "Disk-Space-Monitor geschrieben: $MAINT_DISK_SCRIPT"
    return 0
}

# Stellt sicher, dass überhaupt ein Cron-Daemon vorhanden ist
maint_ensure_cron() {
    if command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    info "Installiere 'cron' Paket..."
    install_package "cron" || install_package "vixie-cron" || true
    manage_service enable cron 2>/dev/null || manage_service enable crond 2>/dev/null || true
    manage_service start cron 2>/dev/null || manage_service start crond 2>/dev/null || true
    return 0
}

# Trägt den Cronjob ein - ein bereits vorhandener Eintrag wird nicht verdoppelt
maint_install_cronjob() {
    local current_cron

    if ! command -v crontab >/dev/null 2>&1; then
        warning "crontab nicht verfügbar - Cronjob wurde nicht eingerichtet."
        return 1
    fi

    current_cron="$(crontab -l 2>/dev/null || true)"

    if echo "$current_cron" | grep -qF "$MAINT_DISK_SCRIPT"; then
        debug "Cronjob für Disk-Space-Monitor existiert bereits."
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] crontab-Eintrag: ${MAINT_DISK_CRON_JOB}${C_RESET}" >&2
        return 0
    fi

    if ! run_eval "( (crontab -l 2>/dev/null || true); echo '${MAINT_DISK_CRON_JOB}' ) | crontab -"; then
        warning "Cronjob konnte nicht eingetragen werden."
        return 1
    fi

    debug "Cronjob für Disk-Space-Monitor hinzugefügt."
    return 0
}

module_main() {
    local do_logrotate=0 do_disk=0

    config_bool MAINTENANCE_LOGROTATE && do_logrotate=1
    config_bool MAINTENANCE_DISK_MONITOR && do_disk=1

    if [ "$do_logrotate" = "0" ] && [ "$do_disk" = "0" ]; then
        skip "Weder MAINTENANCE_LOGROTATE noch MAINTENANCE_DISK_MONITOR gesetzt."
        return 1
    fi

    # --- Log-Rotation ---
    if [ "$do_logrotate" = "1" ]; then
        info "Konfiguriere Log-Rotation..."
        install_package "logrotate" || warning "logrotate konnte nicht installiert werden."
        if ! maint_configure_logrotate; then
            return 2
        fi
        success "Log-Rotation für Systemlogs konfiguriert."
    fi

    # --- Disk-Space-Monitoring ---
    if [ "$do_disk" = "1" ]; then
        echo ""
        info "Erstelle Disk-Space-Monitoring..."
        if ! maint_write_disk_monitor; then
            return 2
        fi

        maint_ensure_cron
        if ! maint_install_cronjob; then
            warning "Disk-Space-Monitor läuft, wird aber nicht automatisch aufgerufen."
        fi
        success "Disk-Space-Monitor eingerichtet (Cronjob täglich 02:00)."
    fi

    echo ""
    success "System-Wartung konfiguriert."
    return 0
}

module_status() {
    local parts=""

    [ -f "$MAINT_LOGROTATE_FILE" ] && parts="${parts} Logrotation"
    [ -x "$MAINT_DISK_SCRIPT" ] && parts="${parts} Disk-Monitor"

    if crontab -l 2>/dev/null | grep -qF "$MAINT_DISK_SCRIPT"; then
        parts="${parts} (Cronjob 02:00 aktiv)"
    fi

    if [ -z "$parts" ]; then
        echo "nichts eingerichtet"
        return 0
    fi

    echo "${parts# }"
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
# Bewertet wird nur, was die Konfiguration anfordert - ein nicht gesetzter
# Schalter ist kein Ziel und damit keine Abweichung.
module_audit() {
    local do_logrotate=0 do_disk=0
    local missing=""

    config_bool MAINTENANCE_LOGROTATE && do_logrotate=1
    config_bool MAINTENANCE_DISK_MONITOR && do_disk=1

    if [ "$do_logrotate" = "1" ] && [ ! -f "$MAINT_LOGROTATE_FILE" ]; then
        missing="Logrotation"
    fi

    if [ "$do_disk" = "1" ]; then
        if [ ! -x "$MAINT_DISK_SCRIPT" ]; then
            missing="${missing}${missing:+, }Monitor-Skript"
        elif ! crontab -l 2>/dev/null | grep -qF "$MAINT_DISK_SCRIPT"; then
            missing="${missing}${missing:+, }Disk-Monitor-Cronjob"
        fi
    fi

    if [ "$do_logrotate" = "0" ] && [ "$do_disk" = "0" ]; then
        echo "info|Keine Wartung angefordert|MAINTENANCE_LOGROTATE und MAINTENANCE_DISK_MONITOR sind nicht gesetzt"
        return 0
    fi

    if [ -n "$missing" ]; then
        echo "abweichung|die angeforderte Wartung ist nicht vollständig eingerichtet|fehlt: ${missing}"
        return 0
    fi

    echo "ok|Logrotation und Disk-Monitor-Cronjob (02:00) aktiv"
    return 0
}