#!/bin/bash
# ==============================================================================
# Modul: timezone
# ==============================================================================
# Stellt die Zeitzone des Servers und die NTP-Synchronisation ein.
#
# Ohne korrekte Zeitzone laufen Logs, Cronjobs und TLS-Ablaufzeiten der
# Dienste (NetBird, Pangolin, ACME) um Stunden daneben.
#
# Config:
#   SET_TIMEZONE - Zeitzone setzen (Default true)
#   TIMEZONE     - Ziel-Zeitzone (z. B. Europe/Vienna); leer = nachfragen
# ==============================================================================

MODULE_ID="timezone"
MODULE_NAME="Zeitzone"
MODULE_DESC="Zeitzone setzen und NTP-Synchronisation aktivieren"
MODULE_ORDER=40
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("system")

# Ziel-Zeitzone - wird von timezone_ask gesetzt (bewusst global).
TARGET_TZ=""

timezone_current() {
    local tz
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null \
         || cat /etc/timezone 2>/dev/null \
         || echo "Unbekannt")
    echo "$tz"
}

# Prüft eine Zeitzone gegen die Liste des Systems und die zoneinfo-Dateien
timezone_is_valid() {
    local tz="$1"

    if [ -z "$tz" ]; then
        return 1
    fi

    if command -v timedatectl >/dev/null 2>&1 && timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
        return 0
    fi

    [ -f "/usr/share/zoneinfo/$tz" ]
}

# Interaktive Auswahl wie im Original (1-6), inkl. freier Eingabe
timezone_ask() {
    local tz_choice="" custom_tz=""

    echo ""
    echo -e "${C_CYAN}Wählen Sie eine Zeitzone aus:${C_RESET}"
    echo "1. Europe/Berlin (Deutschland, Österreich, Schweiz / CET/CEST)"
    echo "2. UTC (Koordinierte Weltzeit)"
    echo "3. Europe/Vienna (Wien)"
    echo "4. Europe/Zurich (Zürich)"
    echo "5. America/New_York (US Eastern Time)"
    echo "6. Eigene Zeitzone eingeben"
    echo ""

    if ! ask_value "Ihre Wahl [1-6]" "1" tz_choice; then
        return 1
    fi

    TARGET_TZ=""
    case "$tz_choice" in
        1) TARGET_TZ="Europe/Berlin" ;;
        2) TARGET_TZ="UTC" ;;
        3) TARGET_TZ="Europe/Vienna" ;;
        4) TARGET_TZ="Europe/Zurich" ;;
        5) TARGET_TZ="America/New_York" ;;
        6)
            ask_value "Bitte geben Sie die Zeitzone ein (z.B. Europe/Amsterdam)" "" custom_tz || return 1
            if [ -n "$custom_tz" ] && timezone_is_valid "$custom_tz"; then
                TARGET_TZ="$custom_tz"
            else
                error "Ungültige Zeitzone: '$custom_tz'"
                TARGET_TZ=""
            fi
            ;;
        *)
            warning "Ungültige Auswahl."
            ;;
    esac

    return 0
}

timezone_apply() {
    local tz="$1"

    info "Setze Zeitzone auf '$tz'..."
    create_backup "/etc/timezone"

    if command -v timedatectl >/dev/null 2>&1; then
        run_cmd timedatectl set-timezone "$tz"
        # NTP-Synchronisation mit aktivieren - ohne sie driftet die Uhr
        run_cmd timedatectl set-ntp true
    else
        # Distributionen ohne timedatectl
        run_cmd ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
        run_eval "echo '$tz' > /etc/timezone"
    fi

    log_action "TIMEZONE" "Zeitzone geändert auf $tz"
    return 0
}

module_main() {
    local current_tz current_time new_time

    if ! config_bool SET_TIMEZONE; then
        skip "SET_TIMEZONE ist nicht gesetzt - Zeitzone bleibt unverändert."
        return 1
    fi

    current_tz="$(timezone_current)"
    current_time=$(date "+%Y-%m-%d %H:%M:%S %Z")

    info "Aktuelle Zeitzone: $current_tz"
    info "Aktuelle Systemzeit: $current_time"

    # Aus der Config gesetzte Zeitzone hat Vorrang vor der Rückfrage
    TARGET_TZ="$(config_get TIMEZONE "")"

    if [ -n "$TARGET_TZ" ]; then
        if ! timezone_is_valid "$TARGET_TZ"; then
            error "Ungültige Zeitzone aus der Config: '$TARGET_TZ'"
            return 2
        fi
    else
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "TIMEZONE ist nicht gesetzt - nicht-interaktiver Modus ohne Zeitzone."
            return 1
        fi

        if ! ask_yes_no "Möchten Sie die Zeitzone des Servers ändern?" "n"; then
            warning "Zeitzonen-Konfiguration übersprungen."
            return 0
        fi

        timezone_ask || return 2
    fi

    if [ -n "$TARGET_TZ" ]; then
        timezone_apply "$TARGET_TZ" || return 2

        new_time=$(date "+%Y-%m-%d %H:%M:%S %Z")
        success "Zeitzone erfolgreich auf '$TARGET_TZ' gesetzt."
        info "Neue Systemzeit: $new_time"
    else
        warning "Zeitzone wurde nicht geändert."
    fi

    return 0
}

module_status() {
    local current target ntp
    current="$(timezone_current)"
    target="$(config_get TIMEZONE "")"
    ntp="$(timedatectl show --property=NTP --value 2>/dev/null || echo unbekannt)"

    if [ -n "$target" ] && [ "$target" != "$current" ]; then
        echo "$current, Ziel: $target (NTP: $ntp)"
    else
        echo "$current (NTP: $ntp)"
    fi
}

# Ziel: Zeitzone aus der Config gesetzt UND NTP-Synchronisation aktiv.
# Beide Teilziele stehen im nächsten Feld, die Abweichung im Detail - so
# bleibt es bei genau einer Zeile.
module_audit() {
    local current target ntp

    current="$(timezone_current)"
    [ -n "$current" ] || current="Unbekannt"
    target="$(config_get TIMEZONE "")"
    ntp="$(timedatectl show --property=NTP --value 2>/dev/null)"
    [ -n "$ntp" ] || ntp="unbekannt"

    if [ -z "$target" ]; then
        echo "info|aktuell: $current|Keine Ziel-Zeitzone in der Config"
        return 0
    fi

    if [ "$current" != "$target" ]; then
        echo "abweichung|aktuell: $current (NTP: $ntp)|Zeitzone $target und NTP aktiv"
        return 0
    fi

    case "$ntp" in
        yes)
            echo "ok|Zeitzone $target, NTP aktiv"
            ;;
        unbekannt)
            echo "info|Zeitzone $target, NTP-Status nicht ermittelbar"
            ;;
        *)
            echo "abweichung|NTP-Synchronisation ist aus|Zeitzone $target und NTP aktiv"
            ;;
    esac
    return 0
}