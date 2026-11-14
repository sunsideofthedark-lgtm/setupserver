#!/bin/bash
# ==============================================================================
# Modul: clamav
# ==============================================================================
# Installiert den ClamAV-Virenschutz und aktualisiert die Viren-Datenbank.
#
# Wie in setupv3 werden bewusst KEINE Dienste gestartet oder aktiviert: der
# clamav-daemon bleibt unangetastet. Das Einbinden eines laufenden Scanners in
# einen bestehenden Mail- oder Dateifluss ist eine bewusste Entscheidung des
# Betreibers und wird hier nicht vorweggenommen.
#
# Config:
#   INSTALL_CLAMAV  - ClamAV einrichten (Default false)
#
# Das Modul läuft, wenn INSTALL_CLAMAV gesetzt ist ODER wenn es vom Benutzer
# gesondert benannt wurde (--modules oder eine Nummer in der interaktiven
# Auswahl). Bei einer Sammelauswahl ("Komplettes Setup", "alle", MODULES aus
# der Config) entscheidet allein der Schalter - sonst liefe das Modul ohne
# gewünschte Einrichtung und scheiterte an der Paketinstallation.
# ==============================================================================

MODULE_ID="clamav"
MODULE_NAME="ClamAV Antivirus"
MODULE_DESC="ClamAV installieren und Viren-Datenbank aktualisieren"
MODULE_ORDER=95
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "virenschutz")

# "base" gehoert zum System und laeuft immer mit, "software" ist
# installierbare Software und im Auswahlmenue waehlbar.
MODULE_CATEGORY="software"
MODULE_SWITCH="INSTALL_CLAMAV"

# Prüft, ob ClamAV schon auf dem System liegt. Der zweite Parameter ist der
# Kommandoname, falls das Paket anders heisst als das Binary.
clamav_installed() {
    is_package_installed "clamav" "freshclam"
}

module_main() {
    # Der Schalter entscheidet, ob das Modul bei einer Sammelauswahl läuft.
    # Wurde das Modul gesondert benannt (--modules oder Nummer in der
    # interaktiven Auswahl), läuft es auch ohne gesetzten Schalter.
    if ! module_switch_enabled INSTALL_CLAMAV; then
        skip "INSTALL_CLAMAV ist nicht gesetzt - ClamAV wird nicht eingerichtet."
        return 1
    fi

    echo ""
    info "Installiere ClamAV Antivirus..."

    if ! install_package "clamav clamav-daemon"; then
        error "ClamAV Installation fehlgeschlagen."
        return 2
    fi

    # Viren-Datenbank einmalig aktualisieren. freshclam meldet einen Fehler,
    # wenn der Daemon schon läuft - das ist kein Grund für einen Abbruch.
    if ! run_cmd freshclam; then
        warning "Viren-Datenbank konnte nicht aktualisiert werden."
        warning "Das lässt sich später jederzeit mit 'freshclam' nachholen."
    fi

    success "ClamAV installiert und Viren-Datenbank aktualisiert."
    return 0
}

module_status() {
    if clamav_installed; then
        echo "installiert"
    else
        echo "nicht installiert"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    if ! module_switch_enabled INSTALL_CLAMAV; then
        echo "info|ClamAV nicht angefordert|INSTALL_CLAMAV ist nicht gesetzt"
        return 0
    fi

    if ! clamav_installed; then
        echo "abweichung|Modul wurde ausgewählt, aber weder Paket noch freshclam gefunden|ClamAV fehlt"
        return 0
    fi

    if ! command -v clamscan >/dev/null 2>&1; then
        echo "abweichung|ClamAV ist installiert, aber der Scanner liegt nicht im PATH|clamscan fehlt"
        return 0
    fi

    echo "ok|ClamAV installiert, clamscan verfügbar"
    return 0
}
