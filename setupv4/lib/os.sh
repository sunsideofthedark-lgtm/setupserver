#!/bin/bash
# ==============================================================================
# setupv4/lib/os.sh - Betriebssystem, Paketmanager, Services
# ==============================================================================
# Stellt die distributionsabhängigen Funktionen bereit. Alle Module, die Pakete
# installieren oder Services steuern, greifen ausschliesslich auf diese Datei zu.
# ==============================================================================

# Führt einen Befehl aus - im Dry-Run-Modus wird nur angezeigt.
run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] $*${C_RESET}" >&2
        log_action "DRY-RUN" "$*"
        return 0
    fi
    "$@"
}

# Wie run_cmd, aber für Zeichenketten (wird intern evaluiert)
run_eval() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] $1${C_RESET}" >&2
        log_action "DRY-RUN" "$1"
        return 0
    fi
    eval "$1"
}

detect_os() {
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
        fatal "Betriebssystem konnte nicht erkannt werden"
    fi

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
            FIREWALL_CMD="ufw"
            SSH_CONFIG="/etc/ssh/sshd_config"
            SSH_SERVICE="sshd"
            ;;
        *)
            error "Nicht unterstützte Distribution: $OS_ID"
            info "Unterstützt: Ubuntu, Debian, CentOS, RHEL, Rocky, Alma, Fedora, openSUSE, SLES, Arch"
            exit 1
            ;;
    esac

    debug "Paketmanager: $PKG_MANAGER"
    debug "Service-Manager: $SERVICE_MANAGER"
    debug "Firewall: $FIREWALL_CMD"
    debug "SSH-Service: $SSH_SERVICE"

    success "Betriebssystem erkannt: $OS_NAME"
}

manage_service() {
    local action=$1
    local service=$2

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] $SERVICE_MANAGER $action $service${C_RESET}" >&2
        log_action "DRY-RUN" "$SERVICE_MANAGER $action $service"
        return 0
    fi

    case "$SERVICE_MANAGER" in
        systemctl) systemctl $action $service ;;
        service)   service $service $action ;;
        *)
            error "Unbekannter Service-Manager: $SERVICE_MANAGER"
            return 1
            ;;
    esac
}

# Prüft, ob ein Paket installiert ist. Zweites Argument ist eine alternative
# Prüfmethode (z. B. ein Kommandoname), falls das Paket anders heißt.
is_package_installed() {
    local package="$1"
    local alternative_check="$2"

    debug "Prüfe Installation von: $package"

    case "$PKG_MANAGER" in
        apt)
            dpkg -l 2>/dev/null | grep -q "^ii.*$package " && return 0
            ;;
        yum|dnf)
            $PKG_MANAGER list installed "$package" >/dev/null 2>&1 && return 0
            ;;
        zypper)
            zypper se -i "$package" 2>/dev/null | grep -q "^i " && return 0
            ;;
        pacman)
            pacman -Q "$package" >/dev/null 2>&1 && return 0
            ;;
    esac

    if [ -n "$alternative_check" ] && command -v "$alternative_check" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Paket-Installation mit OS-spezifischen Besonderheiten und Wiederholungsversuchen
install_package() {
    local package="$1"
    local alt_package="$2"
    local max_retries=3
    local retry_count=0

    debug "Installiere Paket: $package"
    log_action "INSTALL" "Starting installation of package: $package"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] $PKG_INSTALL ${alt_package:-$package}${C_RESET}" >&2
        log_action "DRY-RUN" "$PKG_INSTALL ${alt_package:-$package}"
        return 0
    fi

    while [ $retry_count -lt $max_retries ]; do
        case "$OS_ID" in
            ubuntu|debian)
                if eval "$PKG_INSTALL $package"; then
                    log_action "INSTALL" "Successfully installed: $package"
                    return 0
                fi
                ;;
            centos|rhel|rocky|almalinux)
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
                            log_action "INSTALL" "Successfully installed: yum-cron"
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
                            log_action "INSTALL" "Successfully installed: dnf-automatic"
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
                            log_action "INSTALL" "Successfully installed: yast2-online-update-configuration"
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
                        warning "Automatische Updates sind unter Arch nicht verfügbar. Überspringe."
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
            warning "Installation fehlgeschlagen. Neuer Versuch ($retry_count/$max_retries)..."
            sleep 2
        fi
    done

    log_action "ERROR" "Failed to install package after $max_retries attempts: $package"
    error "Paket '$package' konnte nicht installiert werden."
    return 1
}