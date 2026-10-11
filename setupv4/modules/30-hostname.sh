#!/bin/bash
# ==============================================================================
# Modul: hostname
# ==============================================================================
# Setzt den Server-Hostnamen und pflegt den passenden Eintrag in /etc/hosts nach.
# Ohne diesen Abgleich löst der Server nach einem Neustart seinen eigenen Namen
# unter Umständen nicht mehr sauber auf.
#
# Config:
#   SET_HOSTNAME     - Hostname setzen (Default true)
#   SERVER_HOSTNAME  - Ziel-Hostname; leer = nachfragen bzw. Hostname behalten
# ==============================================================================

MODULE_ID="hostname"
MODULE_NAME="Server-Hostname"
MODULE_DESC="Hostname setzen und /etc/hosts entsprechend anpassen"
MODULE_ORDER=30
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("system")

# Ziel-Hostname - von der Hilfsfunktion gesetzt (bewusst global, damit kein
# Command-Substitution die Ausgaben der Fragefunktionen verschluckt).
NEW_HOSTNAME=""

# Fragt interaktiv nach einem neuen Hostnamen. Die Schleife entspricht dem
# Original: leere Eingabe und ungültige Namen werden erneut nachgefragt.
hostname_ask_new() {
    local current="$1"

    while true; do
        if ! ask_value "Bitte geben Sie den neuen Hostname ein" "" NEW_HOSTNAME; then
            return 1
        fi
        debug "Benutzer-Eingabe für neuen Hostname: '$NEW_HOSTNAME'"

        if [ -z "$NEW_HOSTNAME" ]; then
            warning "Hostname darf nicht leer sein."
            continue
        fi

        if [ "$NEW_HOSTNAME" = "$current" ]; then
            warning "Neuer Hostname ist identisch mit dem aktuellen Hostname."
            return 0
        fi

        if validate_hostname "$NEW_HOSTNAME"; then
            return 0
        fi

        error "Ungültiger Hostname: '$NEW_HOSTNAME'"
        warning "Hostname-Regeln:"
        warning "• Nur Buchstaben (a-z), Zahlen (0-9) und Bindestriche (-)"
        warning "• Muss mit Buchstabe oder Zahl beginnen und enden"
        warning "• Maximal 63 Zeichen lang"
        warning "• Keine aufeinanderfolgenden Bindestriche"
    done
}

hostname_apply() {
    local current="$1"
    local new="$2"

    info "Ändere Hostname von '$current' zu '$new'..."

    # Backup von /etc/hosts erstellen
    create_backup "/etc/hosts"

    debug "Ausführung: hostnamectl set-hostname '$new'"
    if ! run_cmd hostnamectl set-hostname "$new"; then
        error "Hostname-Änderung fehlgeschlagen"
        return 1
    fi

    # /etc/hosts aktualisieren
    debug "Aktualisiere /etc/hosts"
    run_eval "sed -i 's/127.0.1.1.*${current}/127.0.1.1\\t${new}/' /etc/hosts"

    # Falls keine 127.0.1.1 Zeile existiert, hinzufügen
    if ! grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        debug "Füge 127.0.1.1 Eintrag zu /etc/hosts hinzu"
        run_eval "echo '127.0.1.1 $new' >> /etc/hosts"
    fi

    success "Hostname wurde erfolgreich auf '$new' geändert."
    warning "Neustart erforderlich, damit alle Änderungen wirksam werden."
    return 0
}

module_main() {
    local current

    if ! config_bool SET_HOSTNAME; then
        skip "SET_HOSTNAME ist nicht gesetzt - Hostname bleibt unverändert."
        return 1
    fi

    current=$(hostname)
    info "Aktueller Hostname: $current"
    debug "Aktueller Hostname: $current"

    # Aus der Config gesetzter Hostname hat Vorrang vor der Rückfrage
    NEW_HOSTNAME="$(config_get SERVER_HOSTNAME "")"

    if [ -z "$NEW_HOSTNAME" ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "SERVER_HOSTNAME ist nicht gesetzt - nicht-interaktiver Modus ohne Ziel-Hostname."
            return 1
        fi

        if ! ask_yes_no "Soll der Server-Hostname geändert werden?" "n"; then
            warning "Hostname-Konfiguration übersprungen."
            return 0
        fi

        hostname_ask_new "$current" || return 2
    else
        if ! validate_hostname "$NEW_HOSTNAME"; then
            error "Ungültiger Hostname aus der Config: '$NEW_HOSTNAME'"
            return 2
        fi
    fi

    if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$current" ]; then
        hostname_apply "$current" "$NEW_HOSTNAME" || return 2
    else
        warning "Kein gültiger Hostname eingegeben oder Hostname unverändert."
    fi

    return 0
}

module_status() {
    local current target
    current="$(hostname 2>/dev/null || echo unbekannt)"
    target="$(config_get SERVER_HOSTNAME "")"

    if [ -z "$target" ]; then
        echo "aktuell: $current"
    elif [ "$target" = "$current" ]; then
        echo "aktuell: $current"
    else
        echo "aktuell: $current, Ziel: $target"
    fi
}

# Ziel: der gesetzte Hostname entspricht SERVER_HOSTNAME aus der Config.
module_audit() {
    local current target
    current="$(hostname 2>/dev/null || echo unbekannt)"
    target="$(config_get SERVER_HOSTNAME "")"

    if [ -z "$target" ]; then
        echo "info|Hostname $current|SERVER_HOSTNAME ist nicht in der Config gesetzt"
        return 0
    fi

    if [ "$target" = "$current" ]; then
        echo "ok|Hostname $target"
    else
        echo "abweichung|aktuell: $current|Hostname $target"
    fi
    return 0
}