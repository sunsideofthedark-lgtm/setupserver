#!/bin/bash

# ==============================================================================
# Universelles Server-Setup-Skript für Linux-Distributionen (Version 2.2.1)
# ==============================================================================
# Dieses Skript führt den Administrator durch die grundlegenden Schritte zur
# Absicherung eines neuen Servers. Jeder kritische Schritt erfordert eine
# explizite Bestätigung.
#
# Hinzugefügte Features v2.2.1:
# - (Wunsch) Das 'newt_talk' Netzwerk wird wieder in Schritt 7 erstellt,
#    basierend auf den neuen Pool-Konfigurationen.
# - (Wunsch) Finaler Netzwerk-Test (Schritt 10) prüft nun explizit:
#    1. Default (bridge) IPv4
#    2. Default (bridge) IPv6
#    3. 'newt_talk' (custom) IPv4
#    4. 'newt_talk' (custom) IPv6
#
# Hinzugefügte Features v2.2 (Integration):
# - Vollständige Integration des Docker & UFW Konfigurations-Skripts.
# - Ersetzt die einfache Docker-Konfig durch eine robuste MTU-, IPv4/IPv6-Pool-
#   und UFW-Forwarding-Konfiguration.
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
          _ PKG_UPGRADE="zypper update -y"
            PKG_INSTALL="zypper install -y"
            PKG_AUTOREMOVE="zypper remove --clean-deps -y"
            SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="firewall-cmd"
         _   SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        arch)
            PKG_MANAGER="pacman"
       _     PKG_UPDATE="pacman -Sy"
            PKG_UPGRADE="pacman -Syu --noconfirm"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_AUTOREMOVE="pacman -Rs --noconfirm"
        _     SERVICE_MANAGER="systemctl"
            FIREWALL_CMD="ufw"  # Arch kann ufw installieren
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
    _       ;;
        *)
            echo "[ERROR] Nicht unterstützte Distribution: $OS_ID"
            echo "[INFO] Unterstützte Distributionen: Ubuntu, Debian, CentOS, RHEL, Fedora, openSUSE, Arch Linux"
      _       exit 1
            ;;
    esac
    
    debug "Paketmanager: $PKG_MANAGER"
 _   debug "Service-Manager: $SERVICE_MANAGER"
    debug "Firewall: $FIREWALL_CMD"
    debug "SSH-Service: $SSH_SERVICE"
}

# Firewall-Funktionen je nach System
setup_firewall() {
    local ssh_port=$1
    
    case "$FIREWALL_CMD" in
        ufw)
         _   echo "[INFO] Konfiguriere UFW-Firewall"
            # IPv6-Unterstützung in UFW aktivieren
            if [ -f /etc/default/ufw ]; then
             _   sed -i 's/IPV6=no/IPV6=yes/' /etc/default/ufw
                info "IPv6-Unterstützung in UFW aktiviert."
                
                # HINWEIS: Die DEFAULT_FORWARD_POLICY wird jetzt bei der Docker-Installation
 _               # in Schritt 7 korrekt auf "ACCEPT" gesetzt, falls UFW aktiv ist.
                # Hier wird sie nicht mehr angefasst, um Systeme ohne Docker nicht zu beeinträchtigen.
            fi
            ufw default deny incoming
         _   ufw default allow outgoing
            ufw allow $ssh_port/tcp
            ufw deny 22/tcp
            ufw allow 80/tcp
        _     ufw allow 443/tcp
            ufw allow 51820/udp  # Pangolin VPN
            ufw allow 21820/udp  # Pangolin zusätzlich
            ufw allow 8120/tcp   # Komodo
       _     echo "y" | ufw enable
            ;;
        firewall-cmd)
            echo "[INFO] Konfiguriere firewalld (Regeln gelten für IPv4 & IPv6)"
    _         systemctl enable firewalld
            systemctl start firewalld
            firewall-cmd --permanent --remove-service=ssh  # Standard SSH entfernen
       _     firewall-cmd --permanent --add-port=$ssh_port/tcp
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
       _     firewall-cmd --permanent --add-port=51820/udp  # Pangolin VPN
            firewall-cmd --permanent --add-port=21820/udp  # Pangolin zusätzlich
            firewall-cmd --permanent --add-port=8120/tcp   # Komodo
 _           firewall-cmd --reload
            ;;
        *)
            echo "[WARNING] Unbekannte Firewall: $FIREWALL_CMD"
    _         return 1
            ;;
    esac
}

# Service-Management-Funktionen
manage_service() {
    local action=$1
    local service=$2
    
 _   case "$SERVICE_MANAGER" in
        systemctl)
            systemctl $action $service
            ;;
      _   service)
            service $service $action
            ;;
        *)
   _         echo "[ERROR] Unbekannter Service-Manager: $SERVICE_MANAGER"
            return 1
            ;;
    esac
}

# Prüft ob ein Software-Paket bereits installiert ist
is_package_installed() {
 _   local package="$1"
    local alternative_check="$2"  # Alternative Prüfmethode (z.B. command name)
    
    debug "Prüfe Installation von: $package"
   _  
    # Zuerst mit Paketmanager prüfen
    case "$PKG_MANAGER" in
        apt)
     _       if dpkg -l | grep -q "^ii.*$package "; then
                return 0
            fi
            ;;
        yum|dnf)
            if $PKG_MANAGER list installed "$package" >/dev/null 2>&1; then
                return 0
        _     fi
            ;;
        zypper)
            if zypper se -i "$package" | grep -q "^i "; then
      _         return 0
            fi
            ;;
        pacman)
      _       if pacman -Q "$package" >/dev/null 2>&1; then
                return 0
            fi
            ;;
  _   esac
    
    # Alternative Prüfung (z.B. command verfügbar)
    if [ -n "$alternative_check" ] && command -v "$alternative_check" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Paket-Installation mit OS-spezifischen Besonderheiten und Validierung
install_package() {
    local package="$1"
 _   local alt_package="$2"  # Alternative für verschiedene Distributionen
    local max_retries=3
    local retry_count=0
    
    debug "Installiere Paket: $package"
    log_action "INSTALL" "Starting installation of package: $package"
    
    while [ $retry_count -lt $max_retries ]; do
     _   case "$OS_ID" in
            ubuntu|debian)
                if eval "$PKG_INSTALL $package"; then
     _             log_action "INSTALL" "Successfully installed: $package"
                    return 0
                fi
                ;;
        _     centos|rhel|rocky|almalinux)
                # Einige Pakete haben andere Namen in RHEL/CentOS
                case "$package" in
           _         ufw)
                        warning "UFW ist nicht verfügbar. Verwende firewalld."
                        if eval "$PKG_INSTALL firewalld"; then
             _             log_action "INSTALL" "Successfully installed: firewalld (instead of ufw)"
                            return 0
                        fi
 _                     ;;
                    unattended-upgrades)
                        if eval "$PKG_INSTALL yum-cron"; then
        _                   log_action "INSTALL" "Successfully installed: yum-cron (instead of unattended-upgrades)"
                            return 0
         _               fi
                        ;;
                    *)
                 _       if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
 _                           return 0
                        fi
                        ;;
    _           esac
                ;;
            fedora)
                case "$package" in
 _                   unattended-upgrades)
                        if eval "$PKG_INSTALL dnf-automatic"; then
               _             log_action "INSTALL" "Successfully installed: dnf-automatic (instead of unattended-upgrades)"
                            return 0
    _                   fi
                        ;;
                    *)
             _           if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
 _                           return 0
                        fi
                        ;;
   _             esac
                ;;
            opensuse*|sles)
         _       case "$package" in
                    ufw)
                   _     warning "UFW ist nicht verfügbar. Verwende firewalld."
                        if eval "$PKG_INSTALL firewalld"; then
 _                           log_action "INSTALL" "Successfully installed: firewalld (instead of ufw)"
                            return 0
   _                     fi
                        ;;
                    unattended-upgrades)
  _                       if eval "$PKG_INSTALL yast2-online-update-configuration"; then
                            log_action "INSTALL" "Successfully installed: yast2-online-update-configuration (instead of unattended-upgrades)"
 _                           return 0
                        fi
         _             ;;
                    *)
                   _     if eval "$PKG_INSTALL ${alt_package:-$package}"; then
                            log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
 _                           return 0
                        fi
         _               ;;
                esac
                ;;
        _     arch)
                case "$package" in
               _     unattended-upgrades)
                        warning "Automatische Updates nicht verfügbar in Arch. Überspringe."
    _                     return 0
                        ;;
       _             *)
                        if eval "$PKG_INSTALL ${alt_package:-$package}"; then
 _                           log_action "INSTALL" "Successfully installed: ${alt_package:-$package}"
                   _         return 0
                        fi
     _                   ;;
                esac
                ;;
  _     esac
        
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
 _   log_action "AUTOUPDATE" "Configuring automatic updates for $OS_ID"
    
    case "$OS_ID" in
        ubuntu|debian)
       _     info "Installiere und konfiguriere unattended-upgrades..."
            
            if ! install_package "unattended-upgrades"; then
   _           error "Installation von unattended-upgrades fehlgeschlagen"
                return 1
         _   fi
            
            # Backup der bestehenden Konfiguration
         _   create_backup "/etc/apt/apt.conf.d/20auto-upgrades"
            
            # Erweiterte Konfiguration für automatische Updates
 _           debug "Erstelle erweiterte unattended-upgrades Konfiguration"
            cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
// Automatische Updates - Konfiguriert durch Server-Setup-Skript
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            
            # Unattended-Upgrades Hauptkonfiguration anpassen
 _           if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
                create_backup "/etc/apt/apt.conf.d/50unattended-upgrades"
                
   _             # Sicherheitsupdates aktivieren und Reboot-Handling konfigurieren
                debug "Konfiguriere unattended-upgrades Optionen"
             _   sed -i 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "false";|g' /etc/apt/apt.conf.d/50unattended-upgrades
                sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies "false";|Unattended-Upgrade::Remove-Unused-Dependencies "true";|g' /etc/apt/apt.conf.d/50unattended-upgrades
    _           
                # Mail-Benachrichtigungen deaktivieren (da kein Mail-Server)
                sed -i 's|//Unattended-Upgrade::Mail "";|//Unattended-Upgrade::Mail "";|g' /etc/apt/apt.conf.d/50unattended-upgrades
     _       fi
            
            # Service aktivieren
            systemctl enable unattended-upgrades
 _           systemctl start unattended-upgrades
            ;;
            
        centos|rhel|rocky|almalinux)
      _       info "Installiere und konfiguriere yum-cron..."
            
            if ! install_package "yum-cron"; then
 _               error "Installation von yum-cron fehlgeschlagen"
                return 1
        _     fi
            
            # yum-cron Konfiguration für automatische Sicherheitsupdates
 _           if [ -f /etc/yum/yum-cron.conf ]; then
                create_backup "/etc/yum/yum-cron.conf"
                
      _           debug "Konfiguriere yum-cron für automatische Sicherheitsupdates"
                sed -i 's|update_cmd = default|update_cmd = security|g' /etc/yum/yum-cron.conf
     _           sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/yum/yum-cron.conf
                sed -i 's|emit_via = stdio|emit_via = stdio|g' /etc/yum/yum-cron.conf
            fi
 _           
        S   systemctl enable yum-cron
            systemctl start yum-cron
        _     ;;
            
        fedora)
         _   info "Installiere und konfiguriere dnf-automatic..."
            
            if ! install_package "dnf-automatic"; then
      _         error "Installation von dnf-automatic fehlgeschlagen"
                return 1
       _     fi
            
            # dnf-automatic Konfiguration
     _       if [ -f /etc/dnf/automatic.conf ]; then
                create_backup "/etc/dnf/automatic.conf"
         _       
                debug "Konfiguriere dnf-automatic für Sicherheitsupdates"
       _         sed -i 's|upgrade_type = default|upgrade_type = security|g' /etc/dnf/automatic.conf
                sed -i 's|apply_updates = no|apply_updates = yes|g' /etc/dnf/automatic.conf
            fi
            
            systemctl enable dnf-automatic.timer
            systemctl start dnf-automatic.timer
            ;;
     _       
        opensuse*|sles)
            info "Konfiguriere SUSE automatische Updates..."
     _       
            if ! install_package "yast2-online-update-configuration"; then
       _         warning "YaST Online-Update-Konfiguration nicht verfügbar"
            fi
         _   
            # Zypper auto-update konfigurieren
            debug "Konfiguriere zypper für automatische Updates"
 _           if command -v zypper >/dev/null 2>&1; then
                # Automatic refresh aktivieren
                zypper modifyrepo --refresh --all 2>/dev/null || true
 _           fi
            ;;
