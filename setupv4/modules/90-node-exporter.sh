#!/bin/bash
# ==============================================================================
# Modul: node-exporter
# ==============================================================================
# Installiert den Prometheus Node Exporter als systemd-Dienst und öffnet den
# Port 9100/tcp in der Firewall, damit Prometheus ihn abfragen kann.
#
# Das Binary wird NICHT über den Paketmanager bezogen (nur auf Debian/Ubuntu
# verfügbar), sondern als offizielle Release-Datei geladen. Heruntergeladen
# wird in ein mktemp-Verzeichnis - es bleiben keine Reste im aktuellen
# Arbeitsverzeichnis zurück, auch bei einem Abbruch mitten im Download.
#
# Config:
#   INSTALL_NODE_EXPORTER - Node Exporter installieren (Default false)
# ==============================================================================

MODULE_ID="node-exporter"
MODULE_NAME="Prometheus Node Exporter"
MODULE_DESC="Installiert den Prometheus Node Exporter und öffnet Port 9100/tcp"
MODULE_ORDER=90
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("monitoring")

# Version des Node Exporters - hier anpassbar, mehr ist nicht nötig.
NE_VERSION="1.7.0"
NE_ARCH="linux-amd64"
NE_SERVICE_FILE="/etc/systemd/system/node_exporter.service"
NE_USER="node_exporter"
NE_PORT="9100"

# Erzeugt die systemd-Unit für den Node Exporter
nodeexporter_write_service() {
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${NE_SERVICE_FILE}${C_RESET}" >&2
        return 0
    fi

    create_backup "$NE_SERVICE_FILE"

    cat > "$NE_SERVICE_FILE" << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target
[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
[Install]
WantedBy=multi-user.target
EOF

    return 0
}

# Öffnet den Exporter-Port in der aktiven Firewall
nodeexporter_open_firewall() {
    case "$FIREWALL_CMD" in
        ufw)
            run_cmd ufw allow "${NE_PORT}/tcp"
            ;;
        firewall-cmd)
            run_cmd firewall-cmd --permanent --add-port="${NE_PORT}/tcp"
            run_cmd firewall-cmd --reload
            ;;
        *)
            warning "Unbekannte Firewall (${FIREWALL_CMD}) - Port ${NE_PORT}/tcp wurde nicht geöffnet."
            ;;
    esac
}

module_main() {
    local tmpdir url tarball

    if ! config_bool INSTALL_NODE_EXPORTER; then
        skip "INSTALL_NODE_EXPORTER ist nicht gesetzt - Node Exporter wird nicht angefasst."
        return 1
    fi

    echo ""
    info "Installiere Prometheus Node Exporter..."

    if is_package_installed "node_exporter" "node_exporter"; then
        warning "Prometheus Node Exporter ist bereits installiert."
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        url="https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.${NE_ARCH}.tar.gz"
        echo -e "${C_MAGENTA}[DRY-RUN] würde laden: ${url}${C_RESET}" >&2
        echo -e "${C_MAGENTA}[DRY-RUN] würde nach /usr/local/bin/node_exporter installieren${C_RESET}" >&2
        nodeexporter_write_service
        nodeexporter_open_firewall
        success "Prometheus Node Exporter ${NE_VERSION} würde installiert, Port ${NE_PORT}/tcp geöffnet."
        return 0
    fi

    # --- Download in ein temporäres Verzeichnis ---
    tmpdir="$(mktemp -d /tmp/node_exporter.XXXXXX)"
    if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
        error "Temporäres Verzeichnis konnte nicht angelegt werden."
        return 2
    fi

    url="https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.${NE_ARCH}.tar.gz"
    tarball="${tmpdir}/node_exporter-${NE_VERSION}.${NE_ARCH}.tar.gz"

    info "Lade Node Exporter ${NE_VERSION}..."
    if ! run_cmd curl -sSL -o "$tarball" "$url"; then
        rm -rf "$tmpdir"
        error "Download fehlgeschlagen: $url"
        return 2
    fi

    if ! run_cmd tar -xzf "$tarball" -C "$tmpdir"; then
        rm -rf "$tmpdir"
        error "Entpacken des Archivs fehlgeschlagen."
        return 2
    fi

    if [ ! -f "${tmpdir}/node_exporter-${NE_VERSION}.${NE_ARCH}/node_exporter" ]; then
        rm -rf "$tmpdir"
        error "Binary node_exporter im Archiv nicht gefunden - Pfadaufbau hat sich geändert."
        return 2
    fi

    if ! run_cmd mv "${tmpdir}/node_exporter-${NE_VERSION}.${NE_ARCH}/node_exporter" /usr/local/bin/node_exporter; then
        rm -rf "$tmpdir"
        error "node_exporter konnte nicht nach /usr/local/bin installiert werden."
        return 2
    fi

    # Aufräumen, bevor es weitergeht - das Archiv ist nicht mehr gebraucht
    rm -rf "$tmpdir"

    # --- Systembenutzer ---
    # Der Benutzer kann aus einem früheren Lauf schon existieren.
    if ! id -u "$NE_USER" >/dev/null 2>&1; then
        run_cmd useradd --no-create-home --shell /bin/false "$NE_USER"
    else
        debug "Benutzer ${NE_USER} existiert bereits."
    fi
    run_cmd chown "${NE_USER}:${NE_USER}" /usr/local/bin/node_exporter

    # --- systemd ---
    if ! nodeexporter_write_service; then
        return 2
    fi

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable node_exporter
    run_cmd systemctl start node_exporter

    # --- Firewall ---
    nodeexporter_open_firewall

    success "Prometheus Node Exporter installiert. Port ${NE_PORT}/tcp geöffnet."
    return 0
}

module_status() {
    local active="inaktiv"

    if [ ! -x /usr/local/bin/node_exporter ] && ! command -v node_exporter >/dev/null 2>&1; then
        echo "nicht installiert"
        return 0
    fi

    systemctl is-active --quiet node_exporter 2>/dev/null && active="aktiv"

    echo "${NE_VERSION}, ${active} auf Port ${NE_PORT}/tcp"
}