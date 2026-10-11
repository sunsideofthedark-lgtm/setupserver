#!/bin/bash
# ==============================================================================
# Modul: pangolin
# ==============================================================================
# Richtet das Pangolin SPK-Provisioning ein: ein Newt-Container registriert die
# Site beim Pangolin-Server und legt die Tunnel-Ressourcen an.
#
# Verzeichnis: /opt/komodo/stacks/newt_<hostname>
# Der Newt-Container selbst läuft im externen Netzwerk newt_talk, das bereits
# durch das Komodo-Modul (Periphery) angelegt sein sollte.
#
# SICHERHEIT: Der Site Provisioning Key (SPK) steht in der compose.yml und wird
# im Klartext an den Container übergeben - so verlangt es die Pangolin/newt-
# Provisionierung. Deshalb:
#   * die compose.yml wird mit Modus 600 erzeugt
#   * der SPK wird NIE ausgegeben und NIE im Klartext protokolliert
#   * im Dry-Run bleibt das Platzhalter-Wort stehen
#
# Config:
#   INSTALL_PANGOLIN  - SPK-Provisioning einrichten (Default false)
#   PANGOLIN_SPK      - Site Provisioning Key (spk-...); besser über Umgebung
#                       oder --set setzen
#
# Der Endpoint wird interaktiv erfragt (Standard
# https://pangolin.sunriseing.dev) und auf https:// normalisiert.
#
# Hinweis: FIREWALL_HOSTS_PANGOLIN wird hier bewusst NICHT ausgewertet - die
# Firewall-Regeln gehören dem Firewall-Modul, nicht diesem hier.
# ==============================================================================

MODULE_ID="pangolin"
MODULE_NAME="Pangolin SPK Provisioning"
MODULE_DESC="Pangolin Newt-Container per Site Provisioning Key einrichten"
MODULE_ORDER=93
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("vpn" "docker" "monitoring")

PANGOLIN_DEFAULT_ENDPOINT="https://pangolin.sunriseing.dev"
PANGOLIN_STACK_BASE="/opt/komodo/stacks"

# Erzwingt https:// und entfernt einen abschliessenden Slash. http:// wird
# bewusst hochgezogen - der Provisioning-Key darf nicht im Klartext übertragen
# werden.
pangolin_normalize_endpoint() {
    local url="$1"

    if [[ "$url" =~ ^http:// ]]; then
        url="https://${url#http://}"
    elif [[ ! "$url" =~ ^https:// ]]; then
        url="https://${url}"
    fi
    url="${url%/}"

    echo "$url"
}

# Prüft, ob die Site bereits provisioniert wurde: newt schreibt nach dem ersten
# Start seine ID in die config.json.
pangolin_provisioned() {
    local config_file="$1"
    [ -f "$config_file" ] && grep -q '"id"' "$config_file" 2>/dev/null
}

# Gibt die Site-ID aus der config.json zurück, maskiert für die Anzeige.
pangolin_masked_site_id() {
    local config_file="$1"
    local site_id
    site_id=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$config_file" 2>/dev/null \
        | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
    [ -z "$site_id" ] && return 1
    mask_secret "$site_id"
}

module_main() {
    local site_name config_dir compose_file config_file spk endpoint content site_id

    echo ""
    info "Richte Pangolin SPK Provisioning ein..."
    debug "Starte Pangolin SPK Provisioning Setup"
    log_action "PANGOLIN_SPK" "Starting Pangolin SPK provisioning setup"

    if ! config_bool INSTALL_PANGOLIN; then
        debug "INSTALL_PANGOLIN ist nicht gesetzt - das Modul wurde aber explizit ausgewählt."
    fi

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker ist für Pangolin SPK Provisioning erforderlich!"
        error "Bitte zuerst das Modul 'docker' ausführen und danach dieses erneut starten."
        log_action "PANGOLIN_SPK" "Docker not installed"
        return 2
    fi

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  Pangolin SPK Provisioning Setup${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""

    # --- Hostname als Site Name verwenden (immer) ---
    site_name="$(hostname)"
    info "Verwende Hostname als Site Name: $site_name"

    config_dir="$PANGOLIN_STACK_BASE/newt_${site_name}"
    config_file="$config_dir/config.json"
    compose_file="$config_dir/compose.yml"

    # --- Bereits konfiguriert? ---
    if pangolin_provisioned "$config_file"; then
        success "Pangolin SPK ist bereits konfiguriert."
        info "Konfiguration: $config_file"
        # Die config.json enthält die Zugangsdaten der Site - sie wird hier
        # bewusst nicht im vollen Umfang ausgegeben.
        if site_id="$(pangolin_masked_site_id "$config_file")"; then
            info "Site ID: $site_id"
        fi
        if ! ask_yes_no "Möchten Sie die Konfiguration erneut durchführen?" "n"; then
            skip "Pangolin SPK ist bereits eingerichtet."
            return 1
        fi
    fi

    # --- Pangolin Endpoint ---
    endpoint="$PANGOLIN_DEFAULT_ENDPOINT"
    if [ "$NON_INTERACTIVE" != "1" ]; then
        echo ""
        info "Pangolin Endpoint-URL:"
        info "  (Standard: ${PANGOLIN_DEFAULT_ENDPOINT})"
        if ! ask_value "Pangolin Endpoint" "$PANGOLIN_DEFAULT_ENDPOINT" endpoint; then
            return 2
        fi
    fi
    endpoint="$(pangolin_normalize_endpoint "$endpoint")"
    info "Verwende Endpoint: $endpoint"

    # --- Site Provisioning Key (SPK) ---
    spk="$PANGOLIN_SPK"
    if [ -z "$spk" ]; then
        echo ""
        info "Erstelle einen SPK Key unter:"
        info "  ${PANGOLIN_DEFAULT_ENDPOINT}/admin/settings/provisioning-keys"
        info "Hinweis: SPK Keys können mit Limits (z. B. max. Verwendungen)"
        info "und Ablaufdatum versehen werden - für bessere Sicherheit."
        if [ "$NON_INTERACTIVE" = "1" ]; then
            warning "PANGOLIN_SPK ist nicht gesetzt - nicht-interaktiver Modus ohne Secret."
            skip "Pangolin SPK Provisioning wird übersprungen."
            return 1
        fi
        if ! ask_secret "Site Provisioning Key (spk-..., bleibt verborgen)" spk; then
            return 2
        fi
    fi

    if [[ ! "$spk" =~ ^spk- ]]; then
        error "Ungültiges Key-Format. Muss mit 'spk-' beginnen."
        log_action "PANGOLIN_SPK" "Invalid SPK key format"
        return 2
    fi
    debug "SPK Key erhalten: $(mask_secret "$spk")"
    log_action "PANGOLIN_SPK" "SPK Key provided: $(mask_secret "$spk")"

    # --- Verzeichnis erstellen ---
    info "Erstelle Pangolin Verzeichnis: $config_dir"
    run_cmd mkdir -p "$config_dir"

    # --- Docker Compose Datei ---
    info "Erstelle Docker Compose Konfiguration..."

    content=$(cat << EOF
######################################
# 🦎 PANGOLIN NEWT COMPOSE 🦎 #
######################################

services:
  newt-${site_name}:
    image: fosrl/newt:latest
    container_name: newt-${site_name}
    restart: unless-stopped
    hostname: newt-${site_name}
    volumes:
      # WICHTIG: Config-Datei bleibt auf dem Host erhalten
      # damit ID/Secret nach dem ersten Start gespeichert werden
      - ./config.json:/etc/newt/config.json
      # Docker Socket für Container-Management
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - newt_talk
    environment:
      MTU: 1200
      DOCKER_SOCKET: /var/run/docker.sock
      NEWT_ACCEPT_CLIENTS: true
    command: >
      --config-file /etc/newt/config.json
      --endpoint ${endpoint}
      --provisioning-key "__PANGOLIN_SPK__"
      --name "${site_name}"

networks:
  newt_talk:
    external: true
EOF
)

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${compose_file} (Modus 600)${C_RESET}" >&2
        echo "             Inhalt - der Provisioning Key bleibt hier bewusst ein Platzhalter:"
        printf '%s\n' "$content" | sed 's/^/             /'
    else
        # Ersetzung rein in Bash: der Key darf nicht als Kommandoargument
        # auftauchen und so in einer Prozessliste sichtbar werden.
        content="${content//__PANGOLIN_SPK__/$spk}"
        umask 077
        printf '%s\n' "$content" > "$compose_file"
        chmod 600 "$compose_file"
        success "Docker Compose Datei erstellt: $compose_file"
    fi

    # --- Leere config.json erstellen (wird von newt befüllt) ---
    if [ ! -f "$config_file" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${config_file} mit '{}' (Modus 600)${C_RESET}" >&2
        else
            echo '{}' > "$config_file"
            chmod 600 "$config_file"
            success "Leere config.json erstellt (wird bei erstem Start befüllt)"
        fi
    fi

    # --- Pangolin starten ---
    echo ""
    info "Starte Pangolin Newt Container..."

    if run_cmd docker compose -f "$compose_file" up -d; then
        if [ "$DRY_RUN" = "1" ]; then
            success "✅ Pangolin Newt Container würde jetzt laufen."
        else
            success "✅ Pangolin Newt Container erfolgreich gestartet!"
            log_action "PANGOLIN_SPK" "Newt container started successfully"

            # Kurz warten und Status prüfen
            sleep 5
            if docker ps | grep -q "newt-${site_name}"; then
                success "Container läuft: $(docker ps --filter name="newt-${site_name}" --format '{{.Status}}')"
            fi

            # Logs anzeigen
            echo ""
            info "Container Logs:"
            run_cmd docker logs "newt-${site_name}" --tail 20
        fi
    else
        error "Pangolin Newt Container konnte nicht gestartet werden."
        log_action "PANGOLIN_SPK" "Failed to start container"
        return 2
    fi

    # --- Status anzeigen ---
    echo ""
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_GREEN}  Pangolin SPK Provisioning Status${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}Konfiguration:${C_RESET}"
    echo "  Endpoint: $endpoint"
    echo "  Site Name: $site_name"
    echo "  Config Directory: $config_dir"
    echo "  Compose File: $compose_file"
    echo "  Config File: $config_file"
    echo ""
    echo -e "${C_YELLOW}Wichtige Hinweise:${C_RESET}"
    echo "  1. Der Provisioning Key wird NUR beim ersten Start verwendet"
    echo "  2. Danach speichert newt ID/Secret in config.json"
    echo "  3. Bei Container-Neustart wird die bestehende Site verwendet"
    echo "  4. OHNE config.json Volume würde bei jedem Neustart eine NEUE Site erstellt!"
    echo ""
    echo -e "${C_YELLOW}Nächste Schritte:${C_RESET}"
    echo "  1. Prüfen Sie im Pangolin Dashboard ob die Site erscheint"
    echo "  2. Bei Problemen: docker logs newt-${site_name}"
    echo "  3. Config prüfen: cat $config_file"
    echo ""

    unset spk
    log_action "PANGOLIN_SPK" "Installation completed"
    return 0
}

module_status() {
    local site_name config_dir config_file
    site_name="$(hostname)"
    config_dir="$PANGOLIN_STACK_BASE/newt_${site_name}"
    config_file="$config_dir/config.json"

    if docker ps 2>/dev/null | grep -q "newt-${site_name}"; then
        echo "Newt-Container läuft"
    elif pangolin_provisioned "$config_file"; then
        echo "provisioniert, Container nicht aktiv"
    elif [ -f "$config_file" ]; then
        echo "config.json vorhanden, noch nicht provisioniert"
    else
        echo "nicht eingerichtet"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local site_name config_dir config_file
    site_name="$(hostname)"
    config_dir="${PANGOLIN_STACK_BASE}/newt_${site_name}"
    config_file="${config_dir}/config.json"

    if ! command -v docker >/dev/null 2>&1; then
        echo "info|Pangolin nicht bewertbar|Docker ist nicht installiert - der Newt-Container setzt Docker voraus"
        return 0
    fi

    if docker ps 2>/dev/null | grep -q "newt-${site_name}"; then
        if pangolin_provisioned "$config_file"; then
            echo "ok|config.json provisioniert, Newt-Container laeuft"
        else
            echo "abweichung|${config_file} enthaelt noch keine Site-ID|Container laeuft, nicht provisioniert"
        fi
        return 0
    fi

    if pangolin_provisioned "$config_file"; then
        echo "abweichung|${config_file} ist provisioniert, newt-${site_name} ist aber nicht aktiv|Newt-Container laeuft nicht"
        return 0
    fi

    if [ -f "$config_file" ]; then
        echo "abweichung|${config_file} ist vorhanden, der erste newt-Start steht aus|Noch nicht provisioniert"
        return 0
    fi

    echo "abweichung|${config_dir} wurde noch nicht angelegt|config.json fehlt"
    return 0
}