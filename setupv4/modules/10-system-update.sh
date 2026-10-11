#!/bin/bash
# ==============================================================================
# Modul: system-update
# ==============================================================================
# Bringt das System auf den neuesten Stand: Paketlisten aktualisieren, alle
# Pakete upgraden und nicht mehr benötigte Pakete entfernen.
#
# Das Modul ist bewusst der erste Schritt - alles Folgende (Pakete, Dienste,
# Module) baut auf einem aktuellen Stand auf.
#
# Config:
#   SYSTEM_UPDATE  - Aktualisierung durchführen (Default true)
# ==============================================================================

MODULE_ID="system-update"
MODULE_NAME="Systemaktualisierung"
MODULE_DESC="Paketlisten aktualisieren und alle Systempakete auf den neuesten Stand bringen"
MODULE_ORDER=10
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("system" "pakete")

module_main() {
    if ! config_bool SYSTEM_UPDATE; then
        skip "SYSTEM_UPDATE ist nicht gesetzt - Systemaktualisierung übersprungen."
        return 1
    fi

    if ! confirm "Sollen alle Systempakete auf den neuesten Stand gebracht werden?" "n"; then
        warning "Systemaktualisierung übersprungen."
        return 0
    fi

    echo ""
    info "Aktualisiere Paketlisten..."
    debug "Ausführung: $PKG_UPDATE"
    if ! run_eval "$PKG_UPDATE"; then
        error "Paketlisten-Update fehlgeschlagen"
        return 2
    fi

    info "Führe Upgrades durch... (Dies kann einige Minuten dauern)"
    debug "Ausführung: $PKG_UPGRADE"
    if ! run_eval "$PKG_UPGRADE"; then
        error "Paket-Upgrade fehlgeschlagen"
        return 2
    fi

    # Autoremove ist nur Kosmetik - ein Fehler darf den Lauf nicht abbrechen
    debug "Ausführung: $PKG_AUTOREMOVE"
    if ! run_eval "$PKG_AUTOREMOVE"; then
        warning "Autoremove fehlgeschlagen (nicht kritisch)"
    fi

    success "System wurde erfolgreich aktualisiert."
    return 0
}

module_status() {
    local today
    today="$(date +%Y-%m-%d)"

    # Prüfe, ob heute schon aktualisiert wurde - das Log ist je nach
    # Distribution ein anderes.
    if [ -f /var/log/apt/history.log ] && grep -q "$today" /var/log/apt/history.log 2>/dev/null; then
        echo "heute aktualisiert (apt)"
    elif [ -f /var/log/yum.log ] && grep -q "$today" /var/log/yum.log 2>/dev/null; then
        echo "heute aktualisiert (yum)"
    elif [ -f /var/log/dnf.log ] && grep -q "$today" /var/log/dnf.log 2>/dev/null; then
        echo "heute aktualisiert (dnf)"
    else
        echo "heute keine Aktualisierung"
    fi
}

# Ziel: es stehen keine Paket-Updates mehr aus. Gezählt wird je nach
# Paketmanager - die Zählung selbst verändert nichts am System (Simulation
# bzw. reine Abfrage).
module_audit() {
    local raw updates rc=0

    if ! config_bool SYSTEM_UPDATE; then
        echo "info|Keine ausstehenden Paket-Updates|SYSTEM_UPDATE ist nicht gesetzt"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            # -s simuliert nur, "Inst"-Zeilen sind aktualisierbare Pakete.
            raw="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)"
            rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "info|Keine ausstehenden Paket-Updates|Paketlisten nicht auswertbar"
                return 0
            fi
            updates="$(printf '%s\n' "$raw" | grep -c '^Inst ')"
            ;;
        yum|dnf)
            # check-update: 0 = aktuell, 100 = Updates vorhanden, sonst Fehler.
            raw="$("$PKG_MANAGER" check-update 2>/dev/null)"
            rc=$?
            if [ "$rc" -ne 0 ] && [ "$rc" -ne 100 ]; then
                echo "info|Keine ausstehenden Paket-Updates|check-update nicht auswertbar"
                return 0
            fi
            updates="$(printf '%s\n' "$raw" | grep -cE '^[^[:space:]]+\.[^[:space:]]+[[:space:]]')"
            ;;
        zypper)
            if ! command -v zypper >/dev/null 2>&1; then
                echo "info|Keine ausstehenden Paket-Updates|zypper fehlt"
                return 0
            fi
            # Erste Spalte von list-updates ist der Status (v = Update vorhanden).
            updates="$(zypper --non-interactive list-updates 2>/dev/null | grep -cE '^[vi][[:space:]]*\|')"
            ;;
        pacman)
            if ! command -v pacman >/dev/null 2>&1; then
                echo "info|Keine ausstehenden Paket-Updates|pacman fehlt"
                return 0
            fi
            # pacman -Qu vergleicht gegen die lokale Sync-Datenbank.
            updates="$(pacman -Qu 2>/dev/null | grep -c .)"
            ;;
        *)
            echo "info|Keine ausstehenden Paket-Updates|unbekannter Paketmanager: ${PKG_MANAGER:-nicht ermittelt}"
            return 0
            ;;
    esac

    if [ "${updates:-0}" -eq 0 ]; then
        echo "ok|Keine ausstehenden Paket-Updates"
    else
        echo "abweichung|$updates Paket(e) über $PKG_MANAGER aktualisierbar|Keine ausstehenden Paket-Updates"
    fi
    return 0
}