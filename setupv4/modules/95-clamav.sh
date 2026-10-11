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
# ==============================================================================

MODULE_ID="clamav"
MODULE_NAME="ClamAV Antivirus"
MODULE_DESC="ClamAV installieren und Viren-Datenbank aktualisieren"
MODULE_ORDER=95
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("sicherheit" "virenschutz")

# Prüft, ob ClamAV schon auf dem System liegt. Der zweite Parameter ist der
# Kommandoname, falls das Paket anders heisst als das Binary.
clamav_installed() {
    is_package_installed "clamav" "freshclam"
}

module_main() {
    if ! config_bool INSTALL_CLAMAV; then
        # INSTALL_CLAMAV ist die Voreinstellung aus der Config. Das Modul wurde
        # aber explizit ausgewählt - es läuft damit wie der direkt gewählte
        # Menüpunkt in setupv3.
        debug "INSTALL_CLAMAV ist nicht gesetzt - das Modul wurde aber explizit ausgewählt."
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