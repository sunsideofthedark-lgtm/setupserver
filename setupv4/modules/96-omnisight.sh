#!/bin/bash
# ==============================================================================
# Modul: omnisight
# ==============================================================================
# Installiert den Omnisight Agent. Das Installationsskript kommt von der
# Omnisight-Instanz selbst und wird direkt ausgeführt.
#
# Config:
#   INSTALL_OMNISIGHT      - Agent installieren (Default false)
#   OMNISIGHT_URL          - URL der Omnisight-Instanz
#                            (Default https://omnisight.sunriseing.dev)
#   OMNISIGHT_INSTALL_URL  - URL des Installationsskripts. Leer = aus
#                            OMNISIGHT_URL abgeleitet (<url>/agent/install.sh)
#   OMNISIGHT_TOKEN        - Agent-Token (Secret, Default leer)
#   OMNISIGHT_ROLE         - Rolle des Agenten (Default linux)
#
# Das Token ist ein Secret und wird bewusst NICHT in die Config-Datei
# geschrieben - es wird zur Laufzeit über die Umgebung, --set oder die
# verdeckte Abfrage gesetzt.
#
# Das Modul läuft, wenn INSTALL_OMNISIGHT gesetzt ist ODER wenn es vom Benutzer
# gesondert benannt wurde (--modules oder eine Nummer in der interaktiven
# Auswahl). Bei einer Sammelauswahl ("Komplettes Setup", "alle", MODULES aus
# der Config) entscheidet allein der Schalter.
#
# Die Installations-URL wird vor der Installation geprüft: antwortet der
# Server mit einem Fehlerstatus (z. B. 404), wird nicht installiert, sondern
# sauber übersprungen - mit der geprüften URL in der Meldung.
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

# "base" gehoert zum System und laeuft immer mit, "software" ist
# installierbare Software und im Auswahlmenue waehlbar.
MODULE_CATEGORY="software"
MODULE_SWITCH="INSTALL_OMNISIGHT"

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

# Ermittelt die URL des Installationsskripts.
#
# Ist OMNISIGHT_INSTALL_URL gesetzt, wird sie verwendet - sonst wird sie aus
# der Instanz-URL abgeleitet (<url>/agent/install.sh).
omnisight_install_url() {
    local base_url="$1" explicit_url="${2:-}"

    if [ -n "$explicit_url" ]; then
        printf '%s' "${explicit_url%/}"
        return 0
    fi

    printf '%s/agent/install.sh' "${base_url%/}"
}

# Liefert den HTTP-Statuscode der Installations-URL.
# Leer = keine Antwort (DNS, Verbindung oder TLS schlägt fehl).
omnisight_http_status() {
    local url="$1" status=""

    status="$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null)" || status=""

    printf '%s' "$status"
}

# Ist der Statuscode für die Installation brauchbar? 2xx und 3xx ja.
omnisight_status_usable() {
    local status="${1:-}"

    [ -n "$status" ] || return 1
    case "$status" in
        2*|3*) return 0 ;;
    esac
    return 1
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
    local install_url="$1" url="$2" token="$3" role="$4"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] curl -fsSL ${install_url} | OMNISIGHT_URL=${url} OMNISIGHT_TOKEN=$(mask_secret "$token") OMNISIGHT_AGENT_ROLE=${role} bash${C_RESET}" >&2
        log_action "DRY-RUN" "curl -fsSL ${install_url} | bash (Rolle: ${role})"
        return 0
    fi

    curl -fsSL "$install_url" \
        | OMNISIGHT_URL="$url" OMNISIGHT_TOKEN="$token" OMNISIGHT_AGENT_ROLE="$role" bash
}

module_main() {
    local url token role install_url status

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  Omnisight Agent Konfiguration${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""

    # --- Schalter ---
    # Der Schalter entscheidet, ob das Modul bei einer Sammelauswahl läuft.
    # Wurde das Modul gesondert benannt (--modules oder Nummer in der
    # interaktiven Auswahl), läuft es auch ohne gesetzten Schalter.
    if ! module_switch_enabled INSTALL_OMNISIGHT; then
        skip "INSTALL_OMNISIGHT ist nicht gesetzt - Omnisight Agent wird nicht eingerichtet."
        return 1
    fi

    # --- URL ---
    url="${OMNISIGHT_URL:-$OMNISIGHT_DEFAULT_URL}"
    if [ "$NON_INTERACTIVE" != "1" ]; then
        # Die Vorgabe der Abfrage ist der aktuell gesetzte Wert - sonst
        # überschriebe die Abfrage einen in der Config gesetzten Wert.
        if ! ask_value "Omnisight URL" "$url" url; then
            return 2
        fi
    fi
    url="$(omnisight_normalize_url "$url")"
    info "Verwende Omnisight URL: $url"

    # --- Installations-URL ---
    install_url="$(omnisight_install_url "$url" "${OMNISIGHT_INSTALL_URL:-}")"
    info "Verwende Installations-URL: $install_url"

    # --- Erreichbarkeit prüfen ---
    # Ohne diese Prüfung endete die Installation mit einem nackten
    # "curl: (22) ... 404" - ohne Hinweis darauf, was zu tun ist.
    status="$(omnisight_http_status "$install_url")"
    if ! omnisight_status_usable "$status"; then
        skip "Omnisight-Installer unter ${install_url} nicht erreichbar (HTTP ${status:-keine Antwort}). Bitte OMNISIGHT_INSTALL_URL in der Config auf die korrekte Installations-URL setzen und das Modul erneut starten."
        log_action "OMNISIGHT" "Install URL not usable (HTTP ${status:-keine Antwort}): ${install_url}"
        return 1
    fi
    success "Installations-URL erreichbar (HTTP $status)."

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
        # Wie bei der URL: die Vorgabe ist der aktuell gesetzte Wert.
        if ! ask_value "Omnisight Agent Rolle" "$role" role; then
            return 2
        fi
    fi
    info "Verwende Agent Rolle: $role"

    # --- Installation ---
    echo ""
    info "Installiere Omnisight Agent..."
    # Der Token wird hier bewusst nicht mitprotokolliert - nur URL und Rolle.
    log_action "OMNISIGHT" "Installing Omnisight Agent with URL: $url, Role: $role"

    if omnisight_run_installer "$install_url" "$url" "$token" "$role"; then
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

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local active="inaktiv"

    if ! module_switch_enabled INSTALL_OMNISIGHT; then
        echo "info|Omnisight Agent nicht angefordert|INSTALL_OMNISIGHT ist nicht gesetzt"
        return 0
    fi

    if ! omnisight_installed; then
        echo "abweichung|Unit ${OMNISIGHT_UNIT} ist nicht vorhanden - der Omnisight Agent wurde nicht installiert|Agent fehlt"
        return 0
    fi

    systemctl is-active --quiet "$OMNISIGHT_UNIT" 2>/dev/null && active="aktiv"

    if [ "$active" != "aktiv" ]; then
        echo "abweichung|${OMNISIGHT_UNIT} laeuft nicht|Agent installiert, Dienst inaktiv"
        return 0
    fi

    echo "ok|Agent aktiv (${OMNISIGHT_UNIT})"
    return 0
}
