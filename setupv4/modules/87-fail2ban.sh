#!/bin/bash
# ==============================================================================
# Modul: fail2ban
# ==============================================================================
# Installiert Fail2Ban und aktiviert den Schutz gegen SSH-Bruteforce-Angriffe.
# Der Jail-Block wird in die jail.local geschrieben, die aus der mitgelieferten
# jail.conf erzeugt wird - alle anderen, von Fail2Ban mitgebrachten Jails
# bleiben dadurch erhalten.
#
# Config:
#   INSTALL_FAIL2BAN - Fail2Ban installieren/konfigurieren (Default false)
#   SSH_PORT         - Port, auf dem der SSH-Daemon lauscht (Default 22)
# ==============================================================================

MODULE_ID="fail2ban"
MODULE_NAME="Fail2Ban"
MODULE_DESC="Installiert Fail2Ban und aktiviert den SSH-Bruteforce-Schutz"
MODULE_ORDER=87
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit")

F2B_JAIL_CONF="/etc/fail2ban/jail.conf"
F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

# Schreibt den SSH-Jail nach jail.local.
f2b_write_sshd_jail() {
    local ssh_port="$1"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${F2B_JAIL_LOCAL}${C_RESET}" >&2
        echo "             Inhalt: [sshd] enabled=true port=${ssh_port} maxretry=3 bantime=3600" >&2
        return 0
    fi

    # Die jail.local ist eine Systemdatei und kann eigene Anpassungen enthalten
    create_backup "$F2B_JAIL_LOCAL"

    if ! cp "$F2B_JAIL_CONF" "$F2B_JAIL_LOCAL"; then
        error "jail.conf konnte nicht nach jail.local kopiert werden."
        return 1
    fi

    cat >> "$F2B_JAIL_LOCAL" << EOF
[sshd]
enabled = true
port = ${ssh_port}
maxretry = 3
bantime = 3600
EOF

    return 0
}

module_main() {
    local ssh_port

    if ! config_bool INSTALL_FAIL2BAN; then
        skip "INSTALL_FAIL2BAN ist nicht gesetzt - Fail2Ban wird nicht angefasst."
        return 1
    fi

    echo ""
    info "Installiere oder konfiguriere Fail2Ban..."

    # Ohne gesetzten SSH_PORT aus der Konfiguration auf den Standard zurückfallen
    ssh_port="$(config_get SSH_PORT 22)"

    if ! is_package_installed "fail2ban" "fail2ban-server"; then
        if ! install_package "fail2ban"; then
            return 2
        fi
    else
        debug "Fail2Ban ist bereits installiert - es wird nur konfiguriert."
    fi

    # Im Trockenlauf wurde das Paket nicht wirklich installiert, die jail.conf
    # existiert dann also noch gar nicht. Deshalb hier nur anzeigen, was
    # passieren würde - sonst würde jeder Trockenlauf als Fehler enden.
    if [ "$DRY_RUN" = "1" ]; then
        f2b_write_sshd_jail "$ssh_port"
        manage_service enable fail2ban
        manage_service restart fail2ban
        success "Fail2Ban würde für Port ${ssh_port} konfiguriert."
        return 0
    fi

    # Fehlt die mitgelieferte jail.conf, gibt es keine Grundlage für die
    # Konfiguration - wie im Original wird dann nichts geschrieben.
    if [ ! -f "$F2B_JAIL_CONF" ]; then
        warning "Keine jail.conf unter ${F2B_JAIL_CONF} - Fail2Ban wird nicht konfiguriert."
        return 1
    fi

    if ! f2b_write_sshd_jail "$ssh_port"; then
        return 2
    fi

    manage_service enable fail2ban
    manage_service restart fail2ban
    success "Fail2Ban konfiguriert (sshd, Port ${ssh_port}, 3 Fehlversuche, 1h Sperre)."
    return 0
}

module_status() {
    local jail_port="-"

    if ! command -v fail2ban-server >/dev/null 2>&1 && [ ! -f "$F2B_JAIL_LOCAL" ]; then
        echo "nicht installiert"
        return 0
    fi

    # Den im Jail hinterlegten Port ausgeben, falls ermittelbar
    if [ -f "$F2B_JAIL_LOCAL" ]; then
        jail_port="$(awk '/^\[sshd\]/{f=1;next} /^\[/{f=0} f&&/^port/{print $3;exit}' \
            "$F2B_JAIL_LOCAL" 2>/dev/null)"
        [ -z "$jail_port" ] && jail_port="-"
    fi

    echo "installiert, sshd-Jail auf Port ${jail_port}"
}