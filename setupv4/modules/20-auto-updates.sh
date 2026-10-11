#!/bin/bash
# ==============================================================================
# Modul: auto-updates
# ==============================================================================
# Richtet je nach Distribution automatische Sicherheitsupdates ein:
#   Ubuntu/Debian   unattended-upgrades
#   RHEL/CentOS     yum-cron (nur Sicherheitsupdates)
#   Fedora          dnf-automatic
#   openSUSE/SLES   zypper --refresh (YaST Online-Update)
#   Arch            bewusst NICHT - Rolling Release, manuelle Kontrolle
#
# Config:
#   AUTO_UPDATES - Automatische Updates einrichten (Default true)
# ==============================================================================

MODULE_ID="auto-updates"
MODULE_NAME="Automatische Sicherheitsupdates"
MODULE_DESC="Unattended-Upgrades bzw. yum-cron/dnf-automatic für Sicherheitsupdates einrichten"
MODULE_ORDER=20
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "system")

APT_AUTO_CONF="/etc/apt/apt.conf.d/20auto-upgrades"
APT_UNATTENDED_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

# Schreibt einen Textinhalt auf Platte - im Dry-Run wird nur angezeigt.
autoupdates_write_file() {
    local file="$1"
    local content="$2"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${file}${C_RESET}" >&2
        printf '%s\n' "$content" | sed 's/^/    /' >&2
        return 0
    fi

    printf '%s\n' "$content" > "$file"
}

autoupdates_configure_apt() {
    local content

    info "Installiere und konfiguriere unattended-upgrades..."

    if ! install_package "unattended-upgrades"; then
        error "Installation von unattended-upgrades fehlgeschlagen"
        return 1
    fi

    # Backup der bestehenden Konfiguration
    create_backup "$APT_AUTO_CONF"

    # Erweiterte Konfiguration für automatische Updates
    debug "Erstelle erweiterte unattended-upgrades Konfiguration"
    content=$(cat << 'EOF'
// Automatische Updates - Konfiguriert durch Server-Setup-Skript
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
)
    autoupdates_write_file "$APT_AUTO_CONF" "$content"

    # Unattended-Upgrades Hauptkonfiguration anpassen
    if [ -f "$APT_UNATTENDED_CONF" ]; then
        create_backup "$APT_UNATTENDED_CONF"

        # Sicherheitsupdates aktivieren und Reboot-Handling konfigurieren
        debug "Konfiguriere unattended-upgrades Optionen"
        run_eval "sed -i 's|//Unattended-Upgrade::Automatic-Reboot \"false\";|Unattended-Upgrade::Automatic-Reboot \"false\";|g' $APT_UNATTENDED_CONF"
        run_eval "sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies \"false\";|Unattended-Upgrade::Remove-Unused-Dependencies \"true\";|g' $APT_UNATTENDED_CONF"

        # Mail-Benachrichtigungen deaktiviert lassen (da kein Mail-Server)
        run_eval "sed -i 's|//Unattended-Upgrade::Mail \"\";|//Unattended-Upgrade::Mail \"\";|g' $APT_UNATTENDED_CONF"
    fi

    # Service aktivieren
    manage_service enable unattended-upgrades
    manage_service start unattended-upgrades
    return 0
}

autoupdates_configure_yum() {
    info "Installiere und konfiguriere yum-cron..."

    if ! install_package "yum-cron"; then
        error "Installation von yum-cron fehlgeschlagen"
        return 1
    fi

    # yum-cron Konfiguration für automatische Sicherheitsupdates
    if [ -f /etc/yum/yum-cron.conf ]; then
        create_backup "/etc/yum/yum-cron.conf"

        debug "Konfiguriere yum-cron für automatische Sicherheitsupdates"
        run_eval "sed -i 's|update_cmd = default|update_cmd = security|g' /etc/yum/yum-cron.conf"
        run_eval "sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/yum/yum-cron.conf"
        run_eval "sed -i 's|emit_via = stdio|emit_via = stdio|g' /etc/yum/yum-cron.conf"
    fi

    manage_service enable yum-cron
    manage_service start yum-cron
    return 0
}

autoupdates_configure_dnf() {
    info "Installiere und konfiguriere dnf-automatic..."

    if ! install_package "dnf-automatic"; then
        error "Installation von dnf-automatic fehlgeschlagen"
        return 1
    fi

    # dnf-automatic Konfiguration
    if [ -f /etc/dnf/automatic.conf ]; then
        create_backup "/etc/dnf/automatic.conf"

        debug "Konfiguriere dnf-automatic für Sicherheitsupdates"
        run_eval "sed -i 's|upgrade_type = default|upgrade_type = security|g' /etc/dnf/automatic.conf"
        run_eval "sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/dnf/automatic.conf"
    fi

    manage_service enable dnf-automatic.timer
    manage_service start dnf-automatic.timer
    return 0
}

autoupdates_configure_suse() {
    info "Konfiguriere SUSE automatische Updates..."

    if ! install_package "yast2-online-update-configuration"; then
        warning "YaST Online-Update-Konfiguration nicht verfügbar"
    fi

    # Zypper auto-update konfigurieren
    debug "Konfiguriere zypper für automatische Updates"
    if command -v zypper >/dev/null 2>&1; then
        # Automatic refresh aktivieren
        run_eval "zypper modifyrepo --refresh --all 2>/dev/null || true"
    fi
    return 0
}

# Verteilungsabhängige Einrichtung (ehemals configure_auto_updates)
autoupdates_configure() {
    debug "Konfiguriere automatische Updates für $OS_ID"
    log_action "AUTOUPDATE" "Configuring automatic updates for $OS_ID"

    case "$OS_ID" in
        ubuntu|debian)
            autoupdates_configure_apt || return 1
            ;;
        centos|rhel|rocky|almalinux)
            autoupdates_configure_yum || return 1
            ;;
        fedora)
            autoupdates_configure_dnf || return 1
            ;;
        opensuse*|sles)
            autoupdates_configure_suse || return 1
            ;;
        arch)
            warning "Arch Linux: Automatische Updates werden nicht empfohlen"
            info "Grund: Rolling Release kann Breaking Changes enthalten"
            info "Empfehlung: Manuelle Updates mit 'pacman -Syu'"
            return 0
            ;;
        *)
            error "Automatische Updates für $OS_ID nicht implementiert"
            return 1
            ;;
    esac

    log_action "AUTOUPDATE" "Automatic updates configured successfully for $OS_ID"
    return 0
}

# Übersicht, was nach der Einrichtung gilt (aus dem Original übernommen)
autoupdates_summary() {
    case "$OS_ID" in
        ubuntu|debian)
            info "📋 Ubuntu/Debian Update-Konfiguration:"
            echo "   • Paketlisten-Update: Täglich"
            echo "   • Sicherheitsupdates: Automatisch installiert"
            echo "   • Unattended-Upgrades: Aktiviert"
            echo "   • Auto-Reboot: Deaktiviert (manuell erforderlich)"
            echo "   • Unused Dependencies: Automatisch entfernt"
            ;;
        centos|rhel|rocky|almalinux)
            info "📋 RHEL/CentOS Update-Konfiguration:"
            echo "   • yum-cron: Aktiviert und gestartet"
            echo "   • Update-Typ: Nur Sicherheitsupdates"
            echo "   • Installation: Automatisch angewendet"
            echo "   • Zeitplan: Täglich via cron"
            ;;
        fedora)
            info "📋 Fedora Update-Konfiguration:"
            echo "   • dnf-automatic: Aktiviert"
            echo "   • Timer: Täglich um 6:00 Uhr"
            echo "   • Update-Typ: Nur Sicherheitsupdates"
            echo "   • Installation: Automatisch angewendet"
            ;;
        opensuse*|sles)
            info "📋 SUSE Update-Konfiguration:"
            echo "   • YaST Online Update: Konfiguriert"
            echo "   • Repository Refresh: Automatisch"
            echo "   • Manuelle Überprüfung: zypper lu"
            ;;
        arch)
            warning "📋 Arch Linux:"
            echo "   • Automatische Updates sind nicht empfohlen"
            echo "   • Rolling Release erfordert manuelle Kontrolle"
            echo "   • Manuelle Updates mit: pacman -Syu"
            ;;
    esac
}

# Ausführliche Statusprüfung direkt nach der Einrichtung
# (ehemals check_auto_updates_status)
autoupdates_check() {
    debug "Überprüfe Status der automatischen Updates"

    case "$OS_ID" in
        ubuntu|debian)
            if systemctl is-active --quiet unattended-upgrades; then
                info "✅ unattended-upgrades Service: Aktiv"
            else
                warning "⚠️  unattended-upgrades Service: Inaktiv"
            fi

            if [ -f "$APT_AUTO_CONF" ]; then
                info "✅ Update-Konfiguration: Vorhanden"
            else
                warning "⚠️  Update-Konfiguration: Fehlt"
            fi
            ;;

        centos|rhel|rocky|almalinux)
            if systemctl is-active --quiet yum-cron || systemctl is-active --quiet crond; then
                info "✅ yum-cron Service: Aktiv"
            else
                warning "⚠️  yum-cron Service: Inaktiv"
            fi
            ;;

        fedora)
            if systemctl is-active --quiet dnf-automatic.timer; then
                info "✅ dnf-automatic Timer: Aktiv"
            else
                warning "⚠️  dnf-automatic Timer: Inaktiv"
            fi
            ;;

        opensuse*|sles)
            info "📋 SUSE Updates: Manuell überprüfen mit 'zypper lu'"
            ;;

        arch)
            info "📋 Arch Linux: Manuelle Updates empfohlen"
            ;;
    esac
}

module_main() {
    if ! config_bool AUTO_UPDATES; then
        skip "AUTO_UPDATES ist nicht gesetzt - automatische Updates bleiben deaktiviert."
        return 1
    fi

    info "Automatische Sicherheitsupdates werden für maximale Sicherheit aktiviert..."
    debug "Konfiguriere automatische Updates für $OS_ID"

    if ! autoupdates_configure; then
        warning "⚠️  Automatische Sicherheitsupdates konnten nicht vollständig konfiguriert werden."
        warning "Bitte prüfen Sie die Konfiguration manuell nach dem Setup."
        return 2
    fi

    success "✅ Automatische Sicherheitsupdates sind aktiviert und konfiguriert."

    autoupdates_summary

    echo ""
    info "🔍 Status-Überprüfung der automatischen Updates:"
    autoupdates_check

    return 0
}

module_status() {
    if [ -z "${OS_ID:-}" ]; then
        echo "nicht geprüft (OS noch nicht erkannt)"
        return 0
    fi

    case "$OS_ID" in
        ubuntu|debian)
            if systemctl is-active --quiet unattended-upgrades && [ -f "$APT_AUTO_CONF" ]; then
                echo "unattended-upgrades aktiv, Konfiguration vorhanden"
            elif [ -f "$APT_AUTO_CONF" ] || systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
                echo "unvollständig - Konfiguration oder Service fehlt"
            else
                echo "nicht konfiguriert"
            fi
            ;;
        centos|rhel|rocky|almalinux)
            if systemctl is-active --quiet yum-cron || systemctl is-active --quiet crond; then
                echo "yum-cron aktiv"
            else
                echo "yum-cron inaktiv"
            fi
            ;;
        fedora)
            if systemctl is-active --quiet dnf-automatic.timer; then
                echo "dnf-automatic Timer aktiv"
            else
                echo "dnf-automatic Timer inaktiv"
            fi
            ;;
        opensuse*|sles)
            echo "manuell prüfen (zypper lu)"
            ;;
        arch)
            echo "manuelle Updates empfohlen"
            ;;
        *)
            echo "nicht implementiert für $OS_ID"
            ;;
    esac
}