#!/bin/bash
# ==============================================================================
# Modul: komodo
# ==============================================================================
# Richtet den Komodo Periphery Agent v2 als Docker-Container ein. Compose-Datei,
# Repos und Stack-Dateien liegen unter /opt/komodo, der Container läuft mit dem
# Namen komodo-periphery.
#
# SICHERHEIT: Der Onboarding Key steht im Klartext in der compose.yml - so
# verlangt es Komodo. Deshalb gilt hier:
#   * die compose.yml wird mit Modus 600 erzeugt
#   * der Key wird NIE ausgegeben und NIE protokolliert (mask_secret)
#   * bewusst KEIN Backup der compose.yml - eine Kopie im Backup-Verzeichnis
#     wäre eine zweite, schlechter geschützte Ablage des Schlüssels
#   * im Dry-Run bleibt das Platzhalter-Wort stehen, es wird nichts geschrieben
#
# Netz: Läuft NetBird, wird Port 8120 nur an die NetBird-IP gebunden und der
# Agent ist ausschliesslich im VPN erreichbar. Ohne NetBird greift der
# Rückfall auf 0.0.0.0 - dann ist der Agent auf allen Interfaces erreichbar und
# die Firewall muss ihn bewusst freigeben.
#
# Config:
#   INSTALL_KOMODO   - Periphery einrichten (Default false)
#   KOMODO_ENDPOINT  - Core-Adresse, z. B. komodo.example.com oder 192.168.1.100:9120
#   KOMODO_PASSKEY   - Onboarding Key; besser über Umgebung oder --set setzen
#
# Hinweis: FIREWALL_HOSTS_KOMODO wird hier bewusst NICHT ausgewertet - die
# Firewall-Regeln gehören dem Firewall-Modul, nicht diesem hier.
# ==============================================================================

MODULE_ID="komodo"
MODULE_NAME="Komodo Periphery Agent"
MODULE_DESC="Komodo Periphery v2 als Docker-Container in /opt/komodo einrichten"
MODULE_ORDER=92
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("monitoring" "docker" "vpn")

KOMODO_DEFAULT_ROOT_DIR="/opt/komodo"
KOMODO_DEFAULT_ENDPOINT="komodo.example.com"

# Ermittelt die IP, an die Port 8120 gebunden wird. Ohne NetBird wird 0.0.0.0
# verwendet - dann hört der Agent auf allen Interfaces.
komodo_bind_ip() {
    local nb_ip=""

    if command -v netbird >/dev/null 2>&1; then
        # Erst das Tunnel-Interface, dann der Fallback über die Statusausgabe
        nb_ip=$(ip -o -4 addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        if [ -z "$nb_ip" ]; then
            nb_ip=$(netbird status 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | cut -d/ -f1 | head -n1)
        fi

        if [ -n "$nb_ip" ]; then
            echo "$nb_ip"
            return 0
        fi

        warning "NetBird installiert aber keine IPv4 gefunden. Verwende 0.0.0.0"
    else
        warning "NetBird nicht erkannt. Komodo wird an 0.0.0.0 gebunden."
    fi

    echo "0.0.0.0"
}

komodo_running() {
    docker ps 2>/dev/null | grep -q "komodo-periphery"
}

module_main() {
    local core_address server_name root_dir bind_ip passkey compose_file content

    echo ""
    info "Installiere Komodo Periphery Agent (v2)..."
    debug "Starte Komodo Periphery v2 Installation"
    log_action "KOMODO" "Starting Komodo Periphery v2 installation"

    if ! config_bool INSTALL_KOMODO; then
        debug "INSTALL_KOMODO ist nicht gesetzt - das Modul wurde aber explizit ausgewählt."
    fi

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker ist für Komodo Periphery erforderlich!"
        error "Bitte zuerst das Modul 'docker' ausführen und danach dieses erneut starten."
        log_action "KOMODO" "Docker not installed"
        return 2
    fi

    if komodo_running; then
        success "Komodo Periphery Agent läuft bereits."
        info "Führe Konfiguration erneut aus..."
    fi

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  Komodo Periphery Agent v2 Konfiguration${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""

    # --- NetBird IP ermitteln für Port-Bindung ---
    bind_ip="$(komodo_bind_ip)"
    if [ "$bind_ip" != "0.0.0.0" ]; then
        success "NetBird IP erkannt: $bind_ip"
    fi

    # --- Komodo Core Address ---
    core_address="$KOMODO_ENDPOINT"
    if [ -z "$core_address" ]; then
        echo ""
        info "Die Komodo Core Adresse ist die URL Ihrer Komodo Core Instanz."
        info "Beispiel: komodo.example.com oder 192.168.1.100:9120"
        if [ "$NON_INTERACTIVE" = "1" ]; then
            warning "KOMODO_ENDPOINT ist nicht gesetzt - nicht-interaktiver Modus ohne Eingabe."
            skip "Komodo Periphery wird übersprungen."
            return 1
        fi
        if ! ask_value "Komodo Core Adresse" "$KOMODO_DEFAULT_ENDPOINT" core_address; then
            return 2
        fi
    fi

    # --- Server Name = Hostname ---
    server_name="$(hostname)"
    info "Server-Name (connect_as): $server_name"

    # --- Onboarding Key (Pflicht) ---
    passkey="$KOMODO_PASSKEY"
    if [ -z "$passkey" ]; then
        echo ""
        info "Der Onboarding Key wird in der Komodo Core UI erstellt."
        info "Er ermöglicht die automatische Server-Erstellung und die Authentifizierung."
        if [ "$NON_INTERACTIVE" = "1" ]; then
            warning "KOMODO_PASSKEY ist nicht gesetzt - nicht-interaktiver Modus ohne Secret."
            skip "Komodo Periphery wird übersprungen."
            return 1
        fi
        if ! ask_secret "Onboarding Key (bleibt verborgen)" passkey; then
            return 2
        fi
    fi

    if ! validate_passkey "$passkey"; then
        warning "Der Onboarding Key ist auffällig kurz (${#passkey} Zeichen) - bitte prüfen."
    fi
    debug "Onboarding Key empfangen: $(mask_secret "$passkey")"

    # --- Root Directory ---
    root_dir="$KOMODO_DEFAULT_ROOT_DIR"
    if [ "$NON_INTERACTIVE" != "1" ]; then
        info "Das Root Directory enthält alle Komodo-Dateien (Compose, Repos, etc.)."
        if ! ask_value "Root Directory" "$KOMODO_DEFAULT_ROOT_DIR" root_dir; then
            return 2
        fi
    fi

    info "Erstelle Komodo Verzeichnis: $root_dir"
    run_cmd mkdir -p "$root_dir"

    # --- Docker Compose Datei (v2 Format) ---
    # Der Key bleibt hier als Platzhalter stehen. Eingesetzt wird er erst beim
    # echten Schreiben - so landet er weder in der Dry-Run-Ausgabe noch in
    # einer Prozessliste.
    info "Erstelle Docker Compose Konfiguration..."

    content=$(cat << EOF
####################################
# 🦎 KOMODO COMPOSE - PERIPHERY 🦎 #
####################################

services:
  periphery:
    image: ghcr.io/moghtech/komodo-periphery:2
    init: true
    restart: unless-stopped
    container_name: komodo-periphery
    environment:
      PERIPHERY_CORE_ADDRESS: $core_address
      PERIPHERY_CONNECT_AS: $server_name
      PERIPHERY_ONBOARDING_KEY: __KOMODO_PASSKEY__
      PERIPHERY_CORE_PUBLIC_KEYS: file:/config/keys/core.pub
      PERIPHERY_ROOT_DIRECTORY: $root_dir
      PERIPHERY_DISABLE_TERMINALS: false
      PERIPHERY_DISABLE_CONTAINER_EXEC: false
      PERIPHERY_INCLUDE_DISK_MOUNTS: /etc/hostname
    volumes:
      - keys:/config/keys
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      - $root_dir:$root_dir
    ports:
      - $bind_ip:8120:8120

volumes:
  keys:
EOF
)
    compose_file="$root_dir/compose.yml"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${compose_file} (Modus 600)${C_RESET}" >&2
        echo "             Inhalt - der Onboarding Key bleibt hier bewusst ein Platzhalter:"
        printf '%s\n' "$content" | sed 's/^/             /'
    else
        # Ersetzung rein in Bash: der Key darf nicht als Kommandoargument
        # auftauchen und so in einer Prozessliste sichtbar werden.
        content="${content//__KOMODO_PASSKEY__/$passkey}"
        umask 077
        printf '%s\n' "$content" > "$compose_file"
        chmod 600 "$compose_file"
        success "Docker Compose Datei erstellt: $compose_file"
    fi

    # --- Komodo starten ---
    echo ""
    info "Starte Komodo Periphery Agent v2..."

    if run_cmd docker compose -f "$compose_file" up -d; then
        if [ "$DRY_RUN" = "1" ]; then
            success "✅ Komodo Periphery Agent v2 würde jetzt laufen."
        else
            success "✅ Komodo Periphery Agent v2 erfolgreich gestartet!"
            log_action "KOMODO" "Periphery agent v2 started successfully"

            # Kurz warten und Status prüfen
            sleep 3
            if komodo_running; then
                success "Container läuft: $(docker ps --filter name=komodo-periphery --format '{{.Status}}')"
            fi
        fi
    else
        error "Komodo Periphery Agent konnte nicht gestartet werden."
        log_action "KOMODO" "Failed to start container"
        return 2
    fi

    # --- Status anzeigen ---
    echo ""
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_GREEN}  Komodo Periphery v2 Status${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}Verbindungsdetails:${C_RESET}"
    echo "  Core Address: $core_address"
    echo "  Server Name: $server_name"
    echo "  Bind IP: $bind_ip:8120"
    echo "  Root Directory: $root_dir"
    echo "  Konfiguration: $compose_file"
    echo ""

    if [ "$bind_ip" != "0.0.0.0" ]; then
        echo -e "${C_GREEN}Komodo ist nur über VPN (NetBird) erreichbar.${C_RESET}"
    else
        echo -e "${C_YELLOW}WARNUNG: Komodo ist an allen Interfaces erreichbar!${C_RESET}"
    fi

    echo -e "${C_YELLOW}Nächste Schritte:${C_RESET}"
    echo "  1. Periphery verbindet automatisch zu Komodo Core"
    echo "  2. Prüfen Sie in Komodo Core ob der Server erscheint"
    echo "  3. Bei Problemen: docker logs komodo-periphery"
    echo ""

    unset passkey
    log_action "KOMODO" "Installation completed"
    return 0
}

module_status() {
    local compose_file="${KOMODO_DEFAULT_ROOT_DIR}/compose.yml"

    if komodo_running; then
        echo "Container läuft"
    elif [ -f "$compose_file" ]; then
        echo "konfiguriert, Container nicht aktiv"
    else
        echo "nicht eingerichtet"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local compose_file="${KOMODO_DEFAULT_ROOT_DIR}/compose.yml"

    if ! command -v docker >/dev/null 2>&1; then
        echo "info|Komodo nicht bewertbar|Docker ist nicht installiert - ohne Docker laeuft kein Periphery-Agent"
        return 0
    fi

    if komodo_running; then
        echo "ok|Container komodo-periphery laeuft"
        return 0
    fi

    if [ -f "$compose_file" ]; then
        echo "abweichung|${compose_file} ist vorhanden, komodo-periphery ist aber nicht aktiv|Container laeuft nicht"
        return 0
    fi

    echo "abweichung|${compose_file} wurde noch nicht erzeugt|Compose-Datei fehlt"
    return 0
}