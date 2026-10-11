#!/bin/bash
# ==============================================================================
# Modul: zot-mirrors
# ==============================================================================
# Leitet Docker-Pulls so um, dass sie zuerst über die eigene Zot-Instanz laufen
# und bei deren Ausfall auf das jeweilige Original-Registry zurückfallen.
#
# VORAUSSETZUNG: Docker wertet die hosts.toml-Dateien nur mit dem containerd
# Image Store aus ("features": {"containerd-snapshotter": true} in daemon.json).
# Ohne ihn bleibt die gesamte Konfiguration wirkungslos.
#
# Config:
#   ZOT_MIRRORS     - Mirrors einrichten (Default false)
#   ZOT_ENDPOINT    - URL der Zot-Instanz
#   ZOT_USERNAME    - Benutzername oder API-Key-ID
#   ZOT_API_KEY     - API-Key; besser über Umgebung oder --set übergeben
#   ZOT_DOCKER_LOGIN - docker login ausführen
# ==============================================================================

MODULE_ID="zot-mirrors"
MODULE_NAME="Zot-Registry-Mirrors"
MODULE_DESC="Docker-Pulls über die eigene Zot-Registry leiten (hosts.toml)"
MODULE_ORDER=85
MODULE_REQUIRED_KEYS=(ZOT_ENDPOINT)
MODULE_TAGS=("docker" "performance")

# Registry-Mappings: domain|upstream-server|zot-prefix
#   domain   - Name, wie er im Image-Pfad steht (z. B. ghcr.io/linuxserver/nginx)
#   upstream - Echter Endpunkt im Internet (Fallback, falls Zot nicht antwortet)
#   prefix   - Ziel-Praefix unter dem Zot die Images ablegt (sync-Sektion config.json)
ZOT_REGISTRIES=(
    "docker.io|https://registry-1.docker.io|docker-images"
    "ghcr.io|https://ghcr.io|ghcr"
    "quay.io|https://quay.io|quay"
    "mcr.microsoft.com|https://mcr.microsoft.com|mcr"
    "registry.k8s.io|https://registry.k8s.io|k8s"
    "gcr.io|https://gcr.io|gcr"
    "public.ecr.aws|https://public.ecr.aws|ecr"
)

ZOT_CERTS_DIR="/etc/docker/certs.d"
ZOT_DAEMON_JSON="/etc/docker/daemon.json"

# Entfernt führende/abschließende Schrägstriche. Das http(s)://-Schema bleibt
# erhalten, da es in der hosts.toml zwingend benötigt wird.
zot_normalize_endpoint() {
    local url="$1"
    url="${url#/}"
    url="${url%/}"
    echo "$url"
}

# Entfernt das http(s):// für Aufrufe, die nur den Hostnamen erwarten
zot_strip_scheme() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    echo "$url"
}

zot_validate_endpoint() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]] || return 1
    local host
    host="$(zot_strip_scheme "$url")"
    host="${host%%/*}"
    host="${host%%:*}"
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
    return 0
}

zot_validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
    return 0
}

zot_containerd_store_active() {
    local driver_status
    driver_status=$(docker info -f '{{ .DriverStatus }}' 2>/dev/null || true)
    debug "Docker DriverStatus: $driver_status"
    [[ "$driver_status" == *"io.containerd.snapshotter.v1"* ]]
}

# Aktiviert den containerd Image Store, ohne bestehende Einstellungen zu verlieren
zot_enable_containerd_store() {
    # Wichtig: Im Dry-Run darf hier nichts geschrieben werden - das Python
    # darunter würde die echte daemon.json sonst wirklich verändern.
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde \"containerd-snapshotter\": true in ${ZOT_DAEMON_JSON} eintragen${C_RESET}" >&2
        log_action "DRY-RUN" "enable containerd-snapshotter in ${ZOT_DAEMON_JSON}"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        warning "python3 ist nicht installiert - '$ZOT_DAEMON_JSON' wird nicht automatisch geändert."
        echo "     Bitte von Hand in '$ZOT_DAEMON_JSON' ergänzen:"
        echo '     { "features": { "containerd-snapshotter": true } }'
        echo "     Danach: systemctl restart docker"
        return 1
    fi

    info "Aktiviere containerd Image Store in '$ZOT_DAEMON_JSON' ..."
    if python3 - "$ZOT_DAEMON_JSON" << 'ZOTPYEOF'
import json, os, shutil, sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    print(f"FEHLER: {path} enthaelt kein gueltiges JSON: {e}")
    sys.exit(1)

if not isinstance(data, dict):
    print("FEHLER: unerwarteter Aufbau in daemon.json")
    sys.exit(1)

features = data.get("features")
if not isinstance(features, dict):
    features = {}
features["containerd-snapshotter"] = True
data["features"] = features

tmp = path + ".zot-tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o644)
shutil.move(tmp, path)
ZOTPYEOF
    then
        success "daemon.json aktualisiert (bestehende Einstellungen erhalten)."
        return 0
    fi

    error "Aktualisierung von '$ZOT_DAEMON_JSON' fehlgeschlagen."
    return 1
}

module_main() {
    local endpoint hostname username api_key item domain upstream prefix
    local target_dir target_file do_login=0

    if ! command -v docker >/dev/null 2>&1; then
        skip "Docker ist nicht installiert - Zot-Mirrors können nicht eingerichtet werden."
        return 1
    fi

    # --- containerd Image Store prüfen (Voraussetzung) ---
    echo ""
    info "Prüfe containerd Image Store..."
    if zot_containerd_store_active; then
        success "containerd Image Store ist aktiv - hosts.toml wird ausgewertet."
    else
        warning "containerd Image Store ist NICHT aktiv."
        warning "Ohne ihn ignoriert Docker die hosts.toml-Dateien komplett."
        if ! ask_yes_no "Soll der containerd Image Store jetzt aktiviert werden? (erfordert Docker-Neustart)" "y"; then
            skip "Zot-Mirrors werden übersprungen."
            return 1
        fi
        if ! zot_enable_containerd_store; then
            return 2
        fi
        warning "Docker muss neu gestartet werden - laufende Container werden dabei unterbrochen."
        if ! ask_yes_no "Docker jetzt neu starten?" "y"; then
            warning "Docker wurde nicht neu gestartet."
            echo "     Ohne Neustart bleibt die Mirror-Konfiguration ohne Wirkung."
            return 1
        fi
        run_cmd systemctl restart docker
        sleep 3
        if [ "$DRY_RUN" = "1" ]; then
            success "containerd Image Store würde nach dem Neustart aktiv sein."
        elif zot_containerd_store_active; then
            success "containerd Image Store ist jetzt aktiv."
        else
            error "containerd Image Store ist nach dem Neustart nicht aktiv."
            return 2
        fi
    fi

    # --- Zielwerte bestimmen ---
    endpoint="$ZOT_ENDPOINT"

    if ! zot_validate_endpoint "$endpoint"; then
        warning "ZOT_ENDPOINT aus der Config ist ungültig: '$endpoint'"
        if ! ask_value "Zot-Endpoint" "https://zot.sunriseing.dev" endpoint; then
            return 2
        fi
    fi
    endpoint="$(zot_normalize_endpoint "$endpoint")"
    hostname="$(zot_strip_scheme "$endpoint")"

    username="$ZOT_USERNAME"
    if [ -z "$username" ]; then
        ask_value "Zot-Benutzername" "admin" username || return 2
    fi

    # --- API-Key: aus Config, Umgebung oder interaktiv ---
    if [ -z "$ZOT_API_KEY" ] && config_bool ZOT_DOCKER_LOGIN; then
        warning "Kein Zot-API-Key gesetzt (Config, Umgebung oder --set)."
        if [ "$NON_INTERACTIVE" = "1" ]; then
            skip "docker login wird übersprungen - nicht-interaktiver Modus ohne Secret."
        elif ! ask_secret "Zot-API-Key (bleibt verborgen)" api_key; then
            return 2
        else
            ZOT_API_KEY="$api_key"
        fi
    fi

    if [ -n "$ZOT_API_KEY" ]; then
        debug "API-Key empfangen: $(mask_secret "$ZOT_API_KEY")"
        do_login=1
    else
        warning "docker login wird übersprungen - Anmeldung muss später manuell erfolgen."
    fi

    # --- hosts.toml-Dateien schreiben ---
    echo ""
    info "Erstelle hosts.toml für ${#ZOT_REGISTRIES[@]} Registries..."

    for item in "${ZOT_REGISTRIES[@]}"; do
        IFS="|" read -r domain upstream prefix <<< "$item"

        if ! zot_validate_domain "$domain"; then
            error "Ungültiger Registry-Domain: '$domain' - wird übersprungen."
            continue
        fi
        if [ -z "$upstream" ] || [ -z "$prefix" ]; then
            error "Unvollständiger Registry-Eintrag: '$item' - wird übersprungen."
            continue
        fi

        target_dir="${ZOT_CERTS_DIR}/${domain}"
        target_file="${target_dir}/hosts.toml"

        if [ "$DRY_RUN" = "1" ]; then
            echo -e "${C_MAGENTA}[DRY-RUN] würde schreiben: ${target_file}${C_RESET}" >&2
            continue
        fi

        mkdir -p "$target_dir"
        cat > "$target_file" << EOFZOT
server = "${upstream}"

[host."${endpoint}/v2/${prefix}"]
  capabilities = ["pull", "resolve"]
  override_path = true
EOFZOT
        chmod 644 "$target_file"
        debug "hosts.toml geschrieben: $target_file"
        success "  ${domain} → ${endpoint}/v2/${prefix} (Fallback: ${upstream})"
    done

    # --- docker login ---
    if [ "$do_login" = "1" ]; then
        echo ""
        info "Melde '$hostname' als '$username' an..."
        # Docker kann keine Browser-Weiterleitung fuer OpenID Connect - Zot
        # akzeptiert API-Tokens deshalb direkt via HTTP Basic Authentication.
        # --password-stdin haelt den Key aus Bash-History und Prozessliste heraus.
        if printf '%s' "$ZOT_API_KEY" | run_eval "docker login '$hostname' -u '$username' --password-stdin"; then
            success "docker login erfolgreich."
        else
            error "docker login fehlgeschlagen - Benutzername und API-Key prüfen."
        fi
    fi

    unset api_key

    echo ""
    success "Zot-Registry-Mirrors eingerichtet."
    info "Verifikation: docker pull ghcr.io/linuxserver/nginx:latest"
    return 0
}

module_status() {
    local count=0
    local item domain
    for item in "${ZOT_REGISTRIES[@]}"; do
        IFS="|" read -r domain _ _ <<< "$item"
        if [ -f "${ZOT_CERTS_DIR}/${domain}/hosts.toml" ]; then
            count=$((count + 1))
        fi
    done

    if zot_containerd_store_active; then
        echo "${count}/${#ZOT_REGISTRIES[@]} konfiguriert, containerd aktiv"
    else
        echo "${count}/${#ZOT_REGISTRIES[@]} konfiguriert, containerd INAKTIV"
    fi
}