#!/bin/bash

# ==============================================================================
# Universelles Server-Setup-Skript für Linux-Distributionen (Version 2.3.0)
# ==============================================================================
# Dieses Skript führt den Administrator durch die grundlegenden Schritte zur
# Absicherung eines neuen Servers. Jeder kritische Schritt erfordert eine
# explizite Bestätigung.
#
# Hinzugefügte Features v2.3.0:
# - (Wunsch) Interaktive Abfrage in `setup_firewall`, ob Ports für
#   HTTP (80), HTTPS (443), Pangolin (51820/udp, 21820/udp) und
#   Komodo (8120/tcp) geöffnet werden sollen.
#
# Hinzugefügte Features v2.2.1:
# - (Wunsch) Das 'newt_talk' Netzwerk wird wieder in Schritt 7 erstellt,
#   basierend auf den neuen Pool-Konfigurationen.
# - (Wunsch) Finaler Netzwerk-Test (Schritt 10) prüft nun explizit:
#   1. Default (bridge) IPv4
#   2. Default (bridge) IPv6
#   3. 'newt_talk' (custom) IPv4
#   4. 'newt_talk' (custom) IPv6
#
# Hinzugefügte Features v2.2 (Integration):
# - Vollständige Integration des Docker & UFW Konfigurations-Skripts.
# - Ersetzt die einfache Docker-Konfig durch eine robuste MTU-, IPv4/IPv6-Pool-
#   und UFW-Forwarding-Konfiguration.
# - Konfiguriert DEFAULT_FORWARD_POLICY in UFW korrekt bei Docker-Installation.
# - Fügt UFW 'allow' Regeln für die Docker-Netzwerk-Pools hinzu.
# - Optionale (deaktivierte) 'data-root' Konfiguration in daemon.json.
#
# Unterstützte Distributionen: Ubuntu, Debian, CentOS, RHEL, Fedora, SUSE, Arch
# Ausführung: sudo bash ./setup_server.sh
# Debug-Modus: DEBUG=1 sudo bash ./setup_server.sh
# ==============================================================================

# --- OS-Erkennung und Kompatibilität ---

# Betriebssystem und Distribution erkennen
detect_os() {
    info "Erkenne Betriebssystem..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$PRETTY_NAME"
        debug "OS erkannt über /etc/os-release: $OS_NAME"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_NAME=$(cat /etc/redhat-release)
        debug "OS erkannt über /etc/redhat-release: $OS_NAME"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian $(cat /etc/debian_version)"
        debug "OS erkannt über /etc/debian_version: $OS_NAME"
    else
        error "Betriebssystem konnte nicht erkannt werden"
        log_action "FATAL" "OS detection failed"
        exit 1
    fi
    
    # Paketmanager bestimmen
    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_UPGRADE="apt upgrade -y"
            PKG_INSTALL="apt install -y"
            PKG_AUTOREMOVE="apt autoremove -y"
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="ufw"
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="ssh"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            # Für neuere Versionen dnf verwenden
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
                PKG_UPDATE="dnf check-update || true"
                PKG_UPGRADE="dnf upgrade -y"
                PKG_INSTALL="dnf install -y"
                PKG_AUTOREMOVE="dnf autoremove -y"
            else
                PKG_UPDATE="yum check-update || true"
                PKG_UPGRADE="yum update -y"
                PKG_INSTALL="yum install -y"
                PKG_AUTOREMOVE="yum autoremove -y"
            fi
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="firewall-cmd"
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf check-update || true"
            PKG_UPGRADE="dnf upgrade -y"
            PKG_INSTALL="dnf install -y"
            PKG_AUTOREMOVE="dnf autoremove -y"
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="firewall-cmd"
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"
            PKG_UPDATE="zypper refresh"
            PKG_UPGRADE="zypper update -y"
            PKG_INSTALL="zypper install -y"
            PKG_AUTOREMOVE="zypper remove --clean-deps -y"
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="firewall-cmd"
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        arch)
            PKG_MANAGER="pacman"
            PKG_UPDATE="pacman -Sy"
            PKG_UPGRADE="pacman -Syu --noconfirm"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_AUTOREMOVE="pacman -Rs --noconfirm"
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="ufw"  # Arch kann ufw installieren
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        *)
            echo "[ERROR] Nicht unterstützte Distribution: $OS_ID"
            echo "[INFO] Unterstützte Distributionen: Ubuntu, Debian, CentOS, RHEL, Fedora, openSUSE, Arch Linux"
            exit 1
            ;;
    esac
    
    debug "Paketmanager: $PKG_MANAGER"
    debug "Service-Manager: $SERVICE_MANAGER"
    debug "Firewall: $FIREWALL_CMD"
    debug "SSH-Service: $SSH_SERVICE"
}

# Hilfsfunktion für Ja/Nein-Fragen
# (Wird von setup_firewall benötigt)
ask_yes_no() {
    local prompt="$1"
    local default_answer="$2" # "y" oder "n"

    while true; do
        if [ "$default_answer" = "y" ]; then
            read -p "$prompt [J/n]: " answer
            answer=${answer:-y}
        elif [ "$default_answer" = "n" ]; then
            read -p "$prompt [j/N]: " answer
            answer=${answer:-n}
        else
            read -p "$prompt [j/n]: " answer
        fi

        case $answer in
            [JjYy]* ) return 0;; # Ja
            [Nn]* ) return 1;; # Nein
            * ) echo "Bitte mit 'j' (Ja) oder 'n' (Nein) antworten.";;
        esac
    done
}


# Firewall-Funktionen je nach System
setup_firewall() {
    local ssh_port=$1
    
    # Interaktive Abfragen für Dienst-Ports
    local open_web_ports=1 # 0 = ja, 1 = nein
    local open_pangolin_ports=1
    local open_komodo_ports=1

    info "Konfiguration der Firewall-Regeln..."
    
    if ask_yes_no "Sollen Standard-Webserver-Ports (80/tcp, 443/tcp) geöffnet werden?" "n"; then
        open_web_ports=0
        log_action "FIREWALL" "User requested to open HTTP/HTTPS ports"
    fi
    
    if ask_yes_no "Hostet dieser Server 'Pangolin'? (Ports 51820/udp, 21820/udp öffnen?)" "n"; then
        open_pangolin_ports=0
        log_action "FIREWALL" "User requested to open Pangolin ports"
    fi
    
    if ask_yes_no "Hostet dieser Server 'Komodo'? (Port 8120/tcp öffnen?)" "n"; then
        open_komodo_ports=0
        log_action "FIREWALL" "User requested to open Komodo port"
    fi
    
    case "$FIREWALL_CMD" in
        ufw)
            echo "[INFO] Konfiguriere UFW-Firewall"
            # IPv6-Unterstützung in UFW aktivieren
            if [ -f /etc/default/ufw ]; then
                sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw
                info "IPv6-Unterstützung in UFW aktiviert."
                
                # HINWEIS: Die DEFAULT_FORWARD_POLICY wird jetzt bei der Docker-Installation
                # in Schritt 7 korrekt auf "ACCEPT" gesetzt, falls UFW aktiv ist.
                # Hier wird sie nicht mehr angefasst, um Systeme ohne Docker nicht zu beeinträchtigen.
            fi
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow $ssh_port/tcp
            if [ "$ssh_port" -ne 22 ]; then
                ufw deny 22/tcp # Standard-SSH explizit blockieren, falls $ssh_port != 22
            fi
            
            # Konditionale Regeln
            if [ $open_web_ports -eq 0 ]; then
                ufw allow 80/tcp
                ufw allow 443/tcp
                info "Firewall: HTTP (80) und HTTPS (443) freigegeben."
            fi
            
            if [ $open_pangolin_ports -eq 0 ]; then
                ufw allow 51820/udp  # Pangolin VPN
                ufw allow 21820/udp  # Pangolin zusätzlich
                info "Firewall: Pangolin (51820/udp, 21820/udp) freigegeben."
            fi
            
            if [ $open_komodo_ports -eq 0 ]; then
                ufw allow 8120/tcp   # Komodo
                info "Firewall: Komodo (8120/tcp) freigegeben."
            fi
            
            echo "y" | ufw enable
            ;;
        firewall-cmd)
            echo "[INFO] Konfiguriere firewalld (Regeln gelten für IPv4 & IPv6)"
            systemctl enable firewalld
            systemctl start firewalld
            firewall-cmd --permanent --remove-service=ssh  # Standard SSH entfernen
            firewall-cmd --permanent --add-port=$ssh_port/tcp
            
            # Konditionale Regeln
            if [ $open_web_ports -eq 0 ]; then
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                info "Firewall: HTTP und HTTPS (Services) freigegeben."
            fi
            
            if [ $open_pangolin_ports -eq 0 ]; then
                firewall-cmd --permanent --add-port=51820/udp  # Pangolin VPN
                firewall-cmd --permanent --add-port=21820/udp  # Pangolin zusätzlich
                info "Firewall: Pangolin (51820/udp, 21820/udp) freigegeben."
            fi
            
            if [ $open_komodo_ports -eq 0 ]; then
                firewall-cmd --permanent --add-port=8120/tcp   # Komodo
                info "Firewall: Komodo (8120/tcp) freigegeben."
            fi
            
            firewall-cmd --reload
            ;;
        *)
            echo "[WARNING] Unbekannte Firewall: $FIREWALL_CMD"
            return 1
            ;;
    esac
}

# Service-Management-Funktionen
manage_service() {
    local action=$1
    local service=$2
    
    case "$SERVICE_MANAGER" in
        systemctl)
            systemctl $action $service
            ;;
        service)
            service $service $action
            ;;
        *)
            echo "[ERROR] Unbekannter Service-Manager: $SERVICE_MANAGER"
            return 1
            ;;
    esac
}

# Prüft ob ein Software-Paket bereits installiert ist
is_package_installed() {
    local package="$1"
    local alternative_check="$2"  # Alternative Prüfmethode (z.B. command name)
    
    debug "Prüfe Installation von: $package"
    
    # Zuerst mit Paketmanager prüfen
    case "$PKG_MANAGER" in
        apt)
            if dpkg -l | grep -q "^ii.*$package "; then
                return 0
            fi
            ;;
        yum|dnf)
            if $PKG_MANAGER list installed "$package" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        zypper)
            if zypper se -i "$package" | grep -q "^i "; then
                return 0
            fi
            ;;
        pacman)
            if pacman -Q "$package" >/dev/null 2>&1; then
                return 0
            fi
            ;;
    esac
    
    # Alternative Prüfung (z.B. command verfügbar)
    if [ -n "$alternative_check" ] && command -v "$alternative_check" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Paket-Installation mit OS-spezifischen Besonderheiten und Validierung
install_package() {
    local package="$1"
    local alt_package="$2"  # Alternative für verschiedene Distributionen
    local max_retries=3
    local retry_count=0
    
    debug "Installiere Paket: $package"
    log_action "INSTALL" "Starting installation of package: $package"
    
    while [ $retry_count -lt $max_retries ]; do
        case "$OS_ID" in
            ubuntu|debian)
                if eval "$PKG_INSTALL $package"; then
                    log_action "INSTALL" "Successfully installed: $package"
                    return 0
                fi
                ;;
            centos|rhel|rocky|almalinux)
                # Einige Pakete haben andere Namen in RHEL/CentOS
                case "$package" in
                    ufw)
                        warning "UFW ist nicht verfügbar. Verwende firewalld."
                        if eval "$PKG_INSTALL firewalld"; then
                            log_action "INSTALL" "Successfully installed: firewalld (instead of ufw)"
                            return 0
                        fi
                        ;;
                    unattended-upgrades)
                        if eval "$PKG_INSTALL yum-cron"; then
                            log_action "INSTALL" "Successfully installed: yum-cron (instead of unattended-upgrades)"
                            return 0
                        fi
                        ;;
                    *)
                        if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
                            return 0
                        fi
                        ;;
                esac
                ;;
            fedora)
                case "$package" in
                    unattended-upgrades)
                        if eval "$PKG_INSTALL dnf-automatic"; then
                            log_action "INSTALL" "Successfully installed: dnf-automatic (instead of unattended-upgrades)"
                            return 0
                        fi
                        ;;
                    *)
                        if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
                            return 0
                        fi
                        ;;
                esac
                ;;
            opensuse*|sles)
                case "$package" in
                    ufw)
                        warning "UFW ist nicht verfügbar. Verwende firewalld."
                        if eval "$PKG_INSTALL firewalld"; then
                            log_action "INSTALL" "Successfully installed: firewalld (instead of ufw)"
                            return 0
                        fi
                        ;;
                    unattended-upgrades)
                        if eval "$PKG_INSTALL yast2-online-update-configuration"; then
                            log_action "INSTALL" "Successfully installed: yast2-online-update-configuration (instead of unattended-upgrades)"
                            return 0
                        fi
                        ;;
                    *)
                        if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
                            return 0
                        fi
                        ;;
                esac
                ;;
            arch)
                case "$package" in
                    unattended-upgrades)
                        warning "Automatische Updates nicht verfügbar in Arch. Überspringe."
                        return 0
                        ;;
                    *)
                        if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
                            return 0
                        fi
                        ;;
                esac
                ;;
        esac
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            warning "Installation fehlgeschlagen. Versuche erneut ($retry_count/$max_retries)..."
            sleep 2
        fi
    done
    
    log_action "ERROR" "Failed to install package after $max_retries attempts: $package"
    return 1
}

# Erweiterte automatische Updates konfigurieren
configure_auto_updates() {
    debug "Konfiguriere automatische Updates für $OS_ID"
    log_action "AUTOUPDATE" "Configuring automatic updates for $OS_ID"
    
    case "$OS_ID" in
        ubuntu|debian)
            info "Installiere und konfiguriere unattended-upgrades..."
            
            if ! install_package "unattended-upgrades"; then
                error "Installation von unattended-upgrades fehlgeschlagen"
                return 1
            fi
            
            # Backup der bestehenden Konfiguration
            create_backup "/etc/apt/apt.conf.d/20auto-upgrades"
            
            # Erweiterte Konfiguration für automatische Updates
            debug "Erstelle erweiterte unattended-upgrades Konfiguration"
            cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
// Automatische Updates - Konfiguriert durch Server-Setup-Skript
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            
            # Unattended-Upgrades Hauptkonfiguration anpassen
            if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
                create_backup "/etc/apt/apt.conf.d/50unattended-upgrades"
                
                # Sicherheitsupdates aktivieren und Reboot-Handling konfigurieren
                debug "Konfiguriere unattended-upgrades Optionen"
                sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "false";|g' /etc/apt/apt.conf.d/50unattended-upgrades
                sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies "false";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|g' /etc/apt/apt.conf.d/50unattended-upgrades
                
                # Mail-Benachrichtigungen deaktivieren (da kein Mail-Server)
                sed -i 's|//Unattended-Upgrade::Mail "";|//Unattended-Upgrade::Mail "";|g' /etc/apt/apt.conf.d/50unattended-upgrades
            fi
            
            # Service aktivieren
            systemctl enable unattended-upgrades
            systemctl start unattended-upgrades
            ;;
            
        centos|rhel|rocky|almalinux)
            info "Installiere und konfiguriere yum-cron..."
            
            if ! install_package "yum-cron"; then
                error "Installation von yum-cron fehlgeschlagen"
                return 1
            fi
            
            # yum-cron Konfiguration für automatische Sicherheitsupdates
            if [ -f /etc/yum/yum-cron.conf ]; then
                create_backup "/etc/yum/yum-cron.conf"
                
                debug "Konfiguriere yum-cron für automatische Sicherheitsupdates"
                sed -i 's|update_cmd = default|update_cmd = security|g' /etc/yum/yum-cron.conf
                sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/yum/yum-cron.conf
                sed -i 's|emit_via = stdio|emit_via = stdio|g' /etc/yum/yum-cron.conf
            fi
            
            systemctl enable yum-cron
            systemctl start yum-cron
            ;;
            
        fedora)
            info "Installiere und konfiguriere dnf-automatic..."
            
            if ! install_package "dnf-automatic"; then
                error "Installation von dnf-automatic fehlgeschlagen"
                return 1
            fi
            
            # dnf-automatic Konfiguration
            if [ -f /etc/dnf/automatic.conf ]; then
                create_backup "/etc/dnf/automatic.conf"
                
                debug "Konfiguriere dnf-automatic für Sicherheitsupdates"
                sed -i 's|upgrade_type = default|upgrade_type = security|g' /etc/dnf/automatic.conf
                sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/dnf/automatic.conf
            fi
            
            systemctl enable dnf-automatic.timer
            systemctl start dnf-automatic.timer
            ;;
            
        opensuse*|sles)
            info "Konfiguriere SUSE automatische Updates..."
            
            if ! install_package "yast2-online-update-configuration"; then
                warning "YaST Online-Update-Konfiguration nicht verfügbar"
            fi
            
            # Zypper auto-update konfigurieren
            debug "Konfiguriere zypper für automatische Updates"
            if command -v zypper >/dev/null 2>&1; then
                # Automatic refresh aktivieren
                zypper modifyrepo --refresh --all 2>/dev/null || true
            fi
            ;;
# HINWEIS: Das ursprüngliche Skript endete hier abrupt.
# Ich habe den Code bis zu diesem Punkt beibehalten.
# Wenn dein Skript weitergeht, fehlen diese Teile hier.
