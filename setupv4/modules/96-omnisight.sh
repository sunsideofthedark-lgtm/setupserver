#!/bin/bash
# ==============================================================================
# Modul: omnisight
# ==============================================================================
# Installiert den Omnisight Agent. Das Installationsskript kommt von der
# Omnisight-Instanz selbst und wird direkt ausgeführt.
#
# Für dieses Modul gibt es in lib/config.sh noch KEINE Defaults - die Werte
# werden deshalb defensiv aus der Umgebung gelesen und sind im Kopf dieses
# Moduls dokumentiert:
#
#   OMNISIGHT_URL   - URL der Omnisight-Instanz
#                     (Default https://omnisight.sunriseing.dev)
#   OMNISIGHT_TOKEN - Agent-Token (Pflicht, kein Default)
#   OMNISIGHT_ROLE  - Rolle des Agenten (Default linux)
#
# Wer die Werte dauerhaft setzen will, kann sie in der Config-Datei eintragen;
# bis die Schlüssel dort in CONFIG_KNOWN_KEYS ergänzt sind, meldet das Setup
# sie als unbekannt und verwirft die Zuweisung nicht - sie wirkt nur nicht.
#
# SICHERHEIT: In setupv3 wurde das Token mit einem einfachen 'read -p' im
# Klartext abgefragt - ein Fehler, der hier behoben ist:
#   * das Token wird mit ask_secret abgefragt (kein Echo, keine History)
#   * es wird NIE ausgegeben und NIE im Klartext protokolliert (mask_secret)
#   * es wird nicht als Argument an run_eval übergeben - run_eval schreibt
#     sein Argument ins Log. Der Installer-Aufruf läuft deshalb direkt mit
#     Variablenzuweisung vor dem Kommando.
# ==============================================================================

MODULE_ID="omnisight"
MODULE_NAME="Omnisight Agent"
MODULE_DESC="Omnisight Agent installieren und mit Token registrieren"
MODULE_ORDER=96
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("monitoring" "agent")

OMNISIGHT_DEFAULT_URL="https://omnisight.sunriseing.dev"
OMNISIGHT_DEFAULT_ROLE="linux"
OMNISIGHT_UNIT="omnisight-agent.service"

# Erzwingt https:// und entfernt einen abschliessenden Slash - das Token darf
# nicht im Klartext übertragen werden.
omnisight_normalize_url() {
    local url="$1"

    if [[ "$url" =~ ^http:// ]]; then
        url="https://${url#http://}"
    elif [[ ! "$url" =~ ^https:// ]]; then
        url="https://${url}"
    fi
    url="${url%/}"

    echo "$url"
}

# Prüft, ob der Agent schon installiert ist.
# Wichtig: 'systemctl list-unit-files' liefert auch dann Exit 0, wenn es die
# Unit gar nicht gibt - deshalb wird die Ausgabe geprüft, nicht der Exit-Code.
omnisight_installed() {
    local unit_files

    unit_files=$(systemctl list-unit-files "$OMNISIGHT_UNIT" 2>/dev/null)
    if [[ "$unit_files" == *"$OMNISIGHT_UNIT"* ]]; then
        return 0
    fi

    # Auf Systemen ohne systemd hilft der Unit-Datei-Pfad weiter
    [ -f "/etc/systemd/system/$OMNISIGHT_UNIT" ] || [ -f "/lib/systemd/system/$OMNISIGHT_UNIT" ]
}

# Führt das Installationsskript der Omnisight-Instanz aus. Das Token wird als
# Umgebungsvariable gesetzt und nicht als Teil eines Strings - so erscheint es
# weder im Log noch in der Kommandozeile.
omnisight_run_installer() {
    local url="$1" token="$2" role="$3"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] curl -fsSL ${url}/agent/install.sh | OMNISIGHT_URL=${url} OMNISIGHT_TOKEN=$(mask_secret "$token") OMNISIGHT_AGENT_ROLE=${role} bash${C_RESET}" >&2
        log_action "DRY-RUN" "curl -fsSL ${url}/agent/install.sh | bash (Rolle: ${role})"
        return 0
    fi

    curl -fsSL "${url}/agent/install.sh" \
        | OMNISIGHT_URL="$url" OMNISIGHT_TOKEN="$token" OMNISIGHT_AGENT_ROLE="$role" bash
}

module_main() {
    local url token role

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  Omnisight Agent Konfiguration${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""

    # --- URL ---
    url="${OMNISIGHT_URL:-$OMNISIGHT_DEFAULT_URL}"
    if [ "$NON_INTERACTIVE" != "1" ]; then
        ask_value "Omnisight URL" "$OMNISIGHT_DEFAULT_URL" url
    fi
    url="$(omnisight_normalize_url "$url")"
    info "Verwende Omnisight URL: $url"

    # --- Token (Pflichtfeld) ---
    token="${OMNISIGHT_TOKEN:-}"
    if [ -z "$token" ]; then
        info "Das Token wird in der Omnisight-Oberfläche für diesen Host erzeugt."
        if [ "$NON_INTERACTIVE" = "1" ]; then
            warning "OMNISIGHT_TOKEN ist nicht gesetzt - nicht-interaktiver Modus ohne Secret."
            skip "Omnisight Agent wird übersprungen."
            return 1
        fi
        if ! ask_secret "Omnisight Token (bleibt verborgen)" token; then
            return 2
        fi
    fi
    debug "Omnisight Token empfangen: $(mask_secret "$token")"

    # --- Rolle ---
    role="${OMNISIGHT_ROLE:-$OMNISIGHT_DEFAULT_ROLE}"
    if [ "$NON_INTERACTIVE" != "1" ]; then
        ask_value "Omnisight Agent Rolle" "$OMNISIGHT_DEFAULT_ROLE" role
    fi
    info "Verwende Agent Rolle: $role"

    # --- Installation ---
    echo ""
    info "Installiere Omnisight Agent..."
    # Der Token wird hier bewusst nicht mitprotokolliert - nur URL und Rolle.
    log_action "OMNISIGHT" "Installing Omnisight Agent with URL: $url, Role: $role"

    if omnisight_run_installer "$url" "$token" "$role"; then
        unset token
        success "✅ Omnisight Agent erfolgreich installiert und gestartet!"
        log_action "OMNISIGHT" "Omnisight Agent installed successfully"
    else
        unset token
        error "Omnisight Agent Installation fehlgeschlagen."
        log_action "OMNISIGHT" "Omnisight Agent installation failed"
        return 2
    fi

    # --- Status anzeigen ---
    echo ""
    if omnisight_installed; then
        success "Unit $OMNISIGHT_UNIT ist vorhanden."
    elif [ "$DRY_RUN" = "1" ]; then
        info "Status der Unit $OMNISIGHT_UNIT würde jetzt geprüft."
    else
        warning "Unit $OMNISIGHT_UNIT nicht gefunden - bitte den Agent prüfen."
    fi

    echo -e "${C_YELLOW}Nächste Schritte:${C_RESET}"
    echo "  1. Prüfen, ob der Host in Omnisight erscheint"
    echo "  2. Status: systemctl status $OMNISIGHT_UNIT"
    echo "  3. Logs:   journalctl -u $OMNISIGHT_UNIT -n 50"
    echo ""

    log_action "OMNISIGHT" "Installation completed"
    return 0
}

module_status() {
    if omnisight_installed; then
        echo "Agent installiert ($OMNISIGHT_UNIT)"
    else
        echo "Agent nicht installiert"
    fi
}