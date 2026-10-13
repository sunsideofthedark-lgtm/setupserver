#!/bin/bash
# ==============================================================================
# Modul: git-ssh
# ==============================================================================
# Richtet SSH-Keys für beliebige Git-Dienste ein - GitHub, Forgejo, Gitea
# oder jeder andere Dienst, der über SSH erreichbar ist.
#
# Je Dienst mit eigenem Block entsteht ein eigener Key
# ~/.ssh/id_ed25519_<kurzname> mit dem Kommentar
# "<hostname>@<GIT_KEY_COMMENT_DOMAIN>". Der Kommentar wird IMMER aus dem
# lokalen Hostnamen gebildet: ein kopierter Key trägt auf jedem Server den
# Namen des jeweiligen Servers und bleibt in der Weboberfläche des
# Git-Dienstes wiedererkennbar.
#
# Die ~/.ssh/config bekommt je Dienst einen eigenen "Host"-Block. Der Block
# setzt IdentitiesOnly yes - ohne das bietet SSH dem Host alle gefundenen
# Keys an, was bei MaxAuthTries 3 in "Too many authentication failures"
# endet.
#
# WICHTIG: authorized_keys wird nicht angefasst. Diese Keys dienen
# ausschließlich Git-Zugriffen, nicht dem SSH-Login.
#
# Abweichung zu setupv3: dort stand "GITHUB_USER=${NEW_USER:-root}". v4 kennt
# kein NEW_USER mehr, deshalb wird die Ziel-Auflösung über
# GIT_SSH_USER -> ADMIN_USER -> root gebildet.
#
# Config:
#   INSTALL_GIT_SSH        - SSH-Keys einrichten (Default false)
#   GIT_SSH_USER           - lokaler Benutzer, dessen Keys eingerichtet werden
#                            (Default: $ADMIN_USER, sonst root)
#   GIT_KEY_COMMENT_DOMAIN - Domain für den Key-Kommentar (Default sunriseing.dev)
#   GIT_SSH_SERVICES       - ein Eintrag je Zeile, format:
#                            "<hostname>|<kurzname>|<eigener Block>|<Basis-URL>"
#                            z. B. "github.com|github|1|https://github.com"
#                            "eigener Block" 1 = eigener Key mit eigenem
#                            IdentityFile, 0 = generischer Key, kein Block
# ==============================================================================

MODULE_ID="git-ssh"
MODULE_NAME="Git SSH-Keys"
MODULE_DESC="SSH-Keys für Git-Dienste (GitHub, Forgejo, Gitea) erzeugen"
MODULE_ORDER=94
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("git" "ssh" "github" "forgejo")

# GITHUB_HOST - an dieser Stelle ist die GitHub-CLI sinnvoll, weil sie den
# Key für github.com hochladen kann. Forgejo/Gitea bringen keine eigene CLI
# mit, für sie wird dieser Weg komplett übersprungen.
GITS_GITHUB_HOST="github.com"

# Die geparsten Dienste, Format "<hostname>|<kurzname>|<eigener Block>|<URL>"
GITS_SERVICES=()

# Entfernt führende und abschließende Leerzeichen aus $1
gitssh_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Zerlegt GIT_SSH_SERVICES (ein Eintrag je Zeile) in die Einzelservices.
# Ungültige Zeilen werden gemeldet und übersprungen - ein Tippfehler darf
# nicht dazu führen, dass das ganze Modul abbricht.
gitssh_parse_services() {
    GITS_SERVICES=()
    local line host short own url

    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(gitssh_trim "$line")"
        [ -z "$line" ] && continue

        IFS='|' read -r host short own url <<< "$line"
        host="$(gitssh_trim "$host")"
        short="$(gitssh_trim "$short")"
        own="$(gitssh_trim "$own")"
        url="$(gitssh_trim "$url")"

        if [ -z "$host" ] || [ -z "$short" ]; then
            warning "Eintrag in GIT_SSH_SERVICES unvollständig, wird übersprungen: '$line'"
            continue
        fi

        case "$own" in
            1|true|yes|on|y) own=1 ;;
            *)                own=0 ;;
        esac

        GITS_SERVICES+=("${host}|${short}|${own}|${url}")
    done <<< "$GIT_SSH_SERVICES"

    return 0
}

# Ist der Dienst mit diesem Hostnamen eingetragen?
gitssh_has_service() {
    local wanted="$1" entry
    for entry in "${GITS_SERVICES[@]}"; do
        [ "${entry%%|*}" = "$wanted" ] && return 0
    done
    return 1
}

# Löst den Benutzer auf, für den die Keys erzeugt werden. Reihenfolge wie in
# setupv3, wo der neu angelegte Benutzer (NEW_USER) verwendet wurde.
gitssh_resolve_user() {
    local candidate

    for candidate in "$(config_get GIT_SSH_USER "")" "$ADMIN_USER" "root"; do
        [ -z "$candidate" ] && continue
        if [ "$candidate" = "root" ] || id -u "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
        debug "Benutzer '$candidate' existiert nicht - wird übersprungen."
    done

    return 1
}

# Git-Identitaet fuer Commits auf diesem Server. Ohne user.name und
# user.email schlaegt "git commit" fehl, deshalb wird sie mitgesetzt.
# Der Standard ist bewusst stabil: <benutzer> und <hostname>@<domain>.
gitssh_git_name() {
    local configured
    configured="$(config_get GIT_AUTHOR_NAME "")"
    [ -n "$configured" ] && { echo "$configured"; return 0; }

    configured="$(config_get GIT_SSH_USER "")"
    [ -z "$configured" ] && configured="$1"
    [ -z "$configured" ] && configured="root"
    echo "$configured"
}

gitssh_git_email() {
    local configured domain
    configured="$(config_get GIT_AUTHOR_EMAIL "")"
    [ -n "$configured" ] && { echo "$configured"; return 0; }

    domain="$(config_get GIT_KEY_COMMENT_DOMAIN "sunriseing.dev")"
    [ -n "$1" ] && echo "$1@$domain" || echo "root@$domain"
}

# Setzt git config fuer den Zielbenutzer, ohne bestehende Werte zu zerstoeren.
gitssh_set_git_identity() {
    local user="$1" home="$2" short="$3"
    local git_name git_email

    command -v git >/dev/null 2>&1 || {
        debug "git ist nicht installiert - Git-Identität wird nicht gesetzt."
        return 0
    }

    git_name="$(gitssh_git_name "$user")"
    git_email="$(gitssh_git_email "$short")"

    if [ "$user" = "root" ]; then
        run_eval "git config --global user.name '$git_name'"
        run_eval "git config --global user.email '$git_email'"
    else
        run_cmd sudo -u "$user" git config --global user.name "$git_name"
        run_cmd sudo -u "$user" git config --global user.email "$git_email"
    fi

    debug "git-Identität für $user gesetzt: $git_name <$git_email>"
    return 0
}

# Das Home-Verzeichnis des Zielbenutzers. Für Nicht-root kommt es aus der
# passwd-Datenbank, damit auch ein abweichendes Home stimmt.
gitssh_user_home() {
    local user="$1" home=""

    if [ "$user" = "root" ]; then
        echo "/root"
        return 0
    fi

    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [ -z "$home" ] && home="/home/$user"
    echo "$home"
}

# Der Kommentar jedes Keys: <hostname>@<GIT_KEY_COMMENT_DOMAIN>.
# Bewusst immer aus dem lokalen Hostnamen, nie aus der Konfiguration.
gitssh_key_comment() {
    local short_name
    short_name="$(hostname -s 2>/dev/null || hostname)"
    echo "${short_name}@$(config_get GIT_KEY_COMMENT_DOMAIN "sunriseing.dev")"
}

# Setzt Modus und Eigentümer einer Datei im .ssh-Verzeichnis.
# private Keys 600, öffentliche 644, config/known_hosts 600.
gitssh_apply_perms() {
    local target_user="$1" file="$2" mode="$3"

    [ -f "$file" ] || return 0
    run_cmd chmod "$mode" "$file"
    [ "$target_user" != "root" ] && run_cmd chown "$target_user:$target_user" "$file"
    return 0
}

# Installiert die GitHub CLI je nach Distribution - nur für github.com
gitssh_install_cli() {
    install_package "curl" || return 1

    case "$OS_ID" in
        ubuntu|debian)
            run_cmd curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                -o /usr/share/keyrings/githubcli-archive-keyring.gpg || return 1
            run_cmd sh -c "echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list" || return 1
            run_eval "$PKG_UPDATE" || return 1
            install_package "gh" || return 1
            ;;
        centos|rhel|rocky|almalinux|fedora|opensuse*|sles|arch)
            install_package "gh" || return 1
            ;;
        *)
            warning "Automatische Installation für $OS_ID nicht verfügbar."
            echo "Installiere gh manuell: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
            return 1
            ;;
    esac

    command -v gh >/dev/null 2>&1
}

# Verbindungsprobe zum Git-Dienst
gitssh_test_connection() {
    local target_user="$1"
    local host="${2:-$GITS_GITHUB_HOST}"

    # Im Dry-Run wird nichts ausgeführt - run_cmd liefert dann nur die
    # angezeigte Zeile auf stderr, die Pipe-Auswertung ergäbe also einen
    # irreführenden Fehler.
    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] Verbindungstest zu ${host} würde laufen${C_RESET}" >&2
        return 0
    fi

    sudo -u "$target_user" ssh -T "git@${host}" 2>&1 | grep -q "successfully authenticated"
}

# Entfernt den zu <host> gehörenden Block aus einer ssh_config-Datei und
# schreibt das Ergebnis auf stdout: von der "Host <host>"-Zeile bis zur
# nächsten "Host"-Zeile bzw. bis zum Dateiende. Der Aufrufer ersetzt damit
# atomar, statt zu duplizieren.
gitssh_strip_host_block() {
    local config_file="$1"
    local host="$2"

    awk -v want="$host" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line ~ /^Host([ \t]|=)/) {
                sub(/^Host([ \t]|=)[ \t]*/, "", line)
                sub(/[ \t]+$/, "", line)
                skip = 0
                count = split(line, patterns, /[ \t]+/)
                for (i = 1; i <= count; i++) {
                    if (patterns[i] == want) { skip = 1 }
                }
            }
            if (!skip) { print }
        }
    ' "$config_file"
}

# Legt die Blöcke in die ssh_config: je Dienst mit eigenem Block ein
# "Host <hostname>"-Eintrag mit eigenem IdentityFile und IdentitiesOnly yes.
# Ein zum gleichen Host vorhandener Block wird ersetzt, nicht dupliziert.
gitssh_write_ssh_config() {
    local ssh_dir="$1"
    local target_user="$2"
    local key_comment="$3"
    local config_file="$ssh_dir/config"
    local entry host short own url block tmp
    local written=0

    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"

        # "eigener Block" 0 = der Dienst nutzt den generischen Key und
        # bekommt deshalb bewusst keinen Eintrag in die ssh_config.
        [ "$own" = "1" ] || continue

        block="# ${host} - Git-Zugriff, Key-Kommentar: ${key_comment}
Host ${host}
    HostName ${host}
    User git
    IdentityFile ~/.ssh/id_ed25519_${short}
    IdentitiesOnly yes"

        if [ "$DRY_RUN" = "1" ]; then
            echo -e "${C_MAGENTA}[DRY-RUN] würde in ${config_file} den Block für ${host} setzen:${C_RESET}"
            echo "${block}"
            echo ""
            written=1
            continue
        fi

        create_backup "$config_file"

        tmp="$(mktemp "${config_file}.XXXXXX" 2>/dev/null)" || tmp=""
        if [ -z "$tmp" ]; then
            error "Temporärdatei für die ssh_config konnte nicht angelegt werden."
            return 2
        fi

        if [ -f "$config_file" ]; then
            gitssh_strip_host_block "$config_file" "$host" > "$tmp" || {
                rm -f "$tmp"
                error "ssh_config konnte nicht gelesen werden: ${config_file}"
                return 2
            }
        fi

        printf '\n%s\n' "$block" >> "$tmp"
        if ! cat "$tmp" > "$config_file"; then
            rm -f "$tmp"
            error "ssh_config konnte nicht geschrieben werden: ${config_file}"
            return 2
        fi
        rm -f "$tmp"

        gitssh_apply_perms "$target_user" "$config_file" 600
        success "ssh_config: Block für ${host} gesetzt (IdentitiesOnly yes)"
        log_action "GIT_SSH" "ssh_config block written for $host"
        written=1
    done

    if [ "$written" = "0" ]; then
        debug "Kein Dienst mit eigenem Block - die ssh_config bleibt unverändert."
    fi
    return 0
}

# Die Weboberfläche, in der der öffentliche Key eingetragen wird.
gitssh_settings_url() {
    local host="$1" url="$2"

    if [ "$host" = "$GITS_GITHUB_HOST" ]; then
        echo "https://github.com/settings/keys"
    elif [ -n "$url" ]; then
        echo "${url%/}/user/settings/keys"
    else
        echo "die SSH-Key-Einstellungen von ${host}"
    fi
}

# Ergänzt known_hosts um den Host-Key des Dienstes, falls dort noch keiner
# steht. Vertrauen auf erstes Mal ist eine Entscheidung, deshalb ist die
# Vorgabe "n".
gitssh_known_hosts_add() {
    local ssh_dir="$1"
    local target_user="$2"
    local host="$3"
    local known_hosts="$ssh_dir/known_hosts"

    if [ -f "$known_hosts" ] && grep -qF "$host" "$known_hosts" 2>/dev/null; then
        debug "known_hosts enthält bereits einen Eintrag für ${host}."
        return 0
    fi

    if ! ask_yes_no "Host-Key von ${host} per ssh-keyscan übernehmen?" "n"; then
        warning "known_hosts bleibt für ${host} unverändert - der erste Verbindungsversuch fragt dann nach."
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde 'ssh-keyscan -H ${host}' an ${known_hosts} anhängen${C_RESET}"
        return 0
    fi

    create_backup "$known_hosts"
    run_cmd mkdir -p "$ssh_dir"
    run_eval "ssh-keyscan -H ${host} >> '${known_hosts}' 2>/dev/null"
    gitssh_apply_perms "$target_user" "$known_hosts" 600
    return 0
}

# Erzeugt einen Key, sofern noch keiner existiert. Ein vorhandener Key wird
# nur auf ausdrückliche Zustimmung ersetzt und vorher gesichert - sonst
# hätte der Benutzer seinen Schlüssel wörtlich nicht mehr.
gitssh_ensure_key() {
    local ssh_dir="$1"
    local target_user="$2"
    local key_file="$3"
    local key_comment="$4"
    local generate=0

    if [ -f "$key_file" ]; then
        if ask_yes_no "SSH-Key ${key_file} existiert bereits - neu erzeugen?" "n"; then
            info "Sichere den vorhandenen Key..."
            create_backup "$key_file"
            [ -f "${key_file}.pub" ] && create_backup "${key_file}.pub"
            generate=1
        else
            info "Vorhandener Key bleibt unverändert: ${key_file}"
            log_action "GIT_SSH" "existing key kept: $key_file"
        fi
    else
        generate=1
    fi

    if [ "$generate" != "1" ]; then
        return 0
    fi

    info "Generiere ed25519 SSH-Key: ${key_comment}"
    echo "  Datei: ${key_file}"

    run_cmd mkdir -p "$ssh_dir"
    run_cmd chmod 700 "$ssh_dir"

    if ! run_cmd ssh-keygen -t ed25519 -C "$key_comment" -f "$key_file" -N ""; then
        error "SSH-Key konnte nicht erzeugt werden: ${key_file}"
        return 2
    fi

    gitssh_apply_perms "$target_user" "$key_file" 600
    gitssh_apply_perms "$target_user" "${key_file}.pub" 644
    [ "$target_user" != "root" ] && run_cmd chown "$target_user:$target_user" "$ssh_dir"

    if [ "$DRY_RUN" = "1" ]; then
        info "[DRY-RUN] Key-Kommentar: ${key_comment}"
        info "[DRY-RUN] Key-Datei:    ${key_file}"
    else
        success "✅ SSH-Key erzeugt: ${key_comment} (${key_file})"
    fi
    log_action "GIT_SSH" "SSH key generated: $key_comment ($key_file)"
    return 0
}

# ==============================================================================
# API-Upload-Helfer (Top-Level, damit sie in module_main() verfuegbar sind)
# ==============================================================================
    # ==============================================================================
# API-Upload: öffentlichen Schlüssel beim Dienst registrieren
# ==============================================================================
# Löst das Token für einen Dienst auf. Reihenfolge:
#   1. GIT_SSH_TOKEN_<KURZNAME> aus der Umgebung oder --set
#   2. interaktive verdeckte Abfrage
# Gibt das Token auf stdout aus, legt den Status in $GITS_TOKEN_STATE ab
# (found / asked / missing).
GITS_TOKEN_STATE=""
GITS_RESOLVED_TOKEN=""

gitssh_resolve_token() {
    local short="$1"
    # Grossschreibung: der Dienst heisst "github", die Variable
    # GIT_SSH_TOKEN_GITHUB. Ohne ${short^^} wuerde nie ein Token gefunden.
    local var_name="GIT_SSH_TOKEN_${short^^}"
    GITS_RESOLVED_TOKEN="${!var_name:-}"
    GITS_TOKEN_STATE="missing"

    if [ -n "$GITS_RESOLVED_TOKEN" ]; then
        GITS_TOKEN_STATE="found"
        return 0
    fi

    if [ "$NON_INTERACTIVE" = "1" ]; then
        debug "Kein Token fuer $short ($var_name) gesetzt - nicht-interaktiv."
        return 1
    fi

    echo ""
    if ask_yes_no "Soll der Key automatisch über die API bei $short registriert werden? (Token erforderlich)" "n"; then
        if ! ask_secret "API-Token für $short" GITS_RESOLVED_TOKEN; then
            GITS_RESOLVED_TOKEN=""
            return 1
        fi
        GITS_TOKEN_STATE="asked"
        return 0
    fi

    GITS_RESOLVED_TOKEN=""
    return 1
}

# Baut API-Endpunkt und Auth-Header für einen Dienst.
# GitHub: eigenes API-Host, Bearer. Forgejo/Gitea: <basis>/api/v1, "token".
gitssh_api_endpoint() {
    local host="$1" base_url="$2"
    if [ "$host" = "github.com" ]; then
        echo "https://api.github.com/user/keys"
    else
        echo "${base_url%/}/api/v1/user/keys"
    fi
}

# Listen-Endpunkt zum Auflisten vorhandener Keys (GET ohne ID)
gitssh_list_endpoint() {
    local host="$1" base_url="$2"
    gitssh_api_endpoint "$host" "$base_url"
}

gitssh_auth_header() {
    local host="$1" token="$2"
    # Forgejo verlangt historisch das Wort "token" vor dem Wert; GitHub
    # erwartet Bearer. Beides wird von den jeweiligen Diensten akzeptiert.
    if [ "$host" = "github.com" ]; then
        echo "Authorization: Bearer $token"
    else
        echo "Authorization: token $token"
    fi
}

# Registriert den öffentlichen Key per API beim Dienst.
#
# WICHTIG: curl wird hier bewusst direkt aufgerufen und NICHT über run_eval.
# run_eval protokolliert sein Argument im Logfile - ein Token im Argument
# würde dort im Klartext landen.
gitssh_upload_key_via_api() {
    local host="$1" short="$2" base_url="$3"
    local pub_file="$4" comment="$5" token="$6"
    local endpoint auth payload title code body response_file

    endpoint="$(gitssh_api_endpoint "$host" "$base_url")"
    auth="$(gitssh_auth_header "$host" "$token")"
    title="$comment"

    if ! command -v curl >/dev/null 2>&1; then
        warning "curl ist nicht installiert - Key muss manuell hochgeladen werden."
        return 1
    fi

    payload_key="$(tr -d '\n' < "$pub_file" 2>/dev/null || true)"
    [ -n "$payload_key" ] || payload_key="ssh-ed25519 <wird bei der Ausführung erzeugt>"
    payload=$(printf '{"title":"%s","key":"%s"}' "$title" "$payload_key")

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde POST ${endpoint} (Titel: ${title}, Token: $(mask_secret "$token"))${C_RESET}" >&2
        log_action "DRY-RUN" "upload public key to ${endpoint}"
        return 0
    fi

    response_file=$(mktemp)
    code=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -H "$auth" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$payload" \
        "$endpoint" 2>/dev/null || echo "000")

    case "$code" in
        200|201)
            success "Key bei $host registriert (Titel: $title)"
            rm -f "$response_file"
            return 0
            ;;
        422)
            # Key existiert bereits - unkritisch
            success "Key bei $host bereits registriert"
            rm -f "$response_file"
            return 0
            ;;
        401|403)
            error "Token für $host abgelehnt (HTTP $code) - Berechtigung oder Token falsch."
            body=$(head -c 200 "$response_file" 2>/dev/null)
            debug "Antwort: $body"
            rm -f "$response_file"
            return 1
            ;;
        *)
            error "Key-Upload zu $host fehlgeschlagen (HTTP $code)"
            body=$(head -c 200 "$response_file" 2>/dev/null)
            debug "Antwort: $body"
            rm -f "$response_file"
            return 1
            ;;
    esac
}
# ============================================================================
# API-Rotation: veraltete Keys desselben Titels aufspueren und entfernen
# ============================================================================
# Gibt die IDs von Keys aus, die zwar denselben Titel tragen, aber ein anderes
# Key-Material haben als das, was lokal gerade benutzt wird. Das sind genau die
# Reste aus frueheren Laeufen - die werden beim Rotieren entsorgt.
#
# Der aktuelle Key wird NIE geloescht: waere er weg, waere der Zugang weg.
gitssh_find_stale_key_ids() {
    local host="$1" base_url="$2" token="$3"
    local comment="$4" current_key="$5"
    local endpoint auth listing

    if ! command -v python3 >/dev/null 2>&1; then
        debug "python3 fehlt - veraltete Keys koennen nicht erkannt werden."
        return 1
    fi

    endpoint="$(gitssh_list_endpoint "$host" "$base_url")"
    auth="$(gitssh_auth_header "$host" "$token")"

    listing=$(curl -sS --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "$auth" \
        "$endpoint" 2>/dev/null) || return 1

    printf '%s' "$listing" | python3 -c '
import json, sys
current = sys.argv[1]
comment = sys.argv[2]

def key_material(value):
    """Nur Typ und Base64-Anteil vergleichen.

    Der Teil hinter dem Key ist ein Kommentar ("ssh-ed25519 AAAA... mein-host")
    und wird von manchen Diensten gar nicht zurueckgegeben. Wurde der ganze
    String verglichen, gaebe der Dienst einen Key ohne Kommentar zurueck und
    der gerade benutzte Key wuerde als "fremd" eingestuft und geloescht.
    """
    return " ".join(str(value).split()[:2])

if not current.strip():
    # Ohne bekannten aktuellen Key wird nichts geloescht - im Zweifel halten.
    sys.exit(0)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if isinstance(data, dict):
    data = [data]

wanted = key_material(current)

for entry in data:
    if not isinstance(entry, dict):
        continue
    if entry.get("title") == comment and key_material(entry.get("key", "")) != wanted:
        key_id = entry.get("id")
        if key_id is not None:
            print(key_id)
' "$current_key" "$comment" 2>/dev/null
}

# Loescht genau einen Key beim Dienst.
gitssh_delete_key() {
    local host="$1" base_url="$2" token="$3" key_id="$4"
    local endpoint auth code

    endpoint="$(gitssh_api_endpoint "$host" "$base_url")"
    auth="$(gitssh_auth_header "$host" "$token")"

    if [ "$DRY_RUN" = "1" ]; then
        echo -e "${C_MAGENTA}[DRY-RUN] würde DELETE ${endpoint}/${key_id}${C_RESET}" >&2
        log_action "DRY-RUN" "delete stale key ${key_id} at ${host}"
        return 0
    fi

    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
        -X DELETE \
        -H "$auth" \
        "${endpoint}/${key_id}" 2>/dev/null || echo "000")

    case "$code" in
        200|204)
            success "  Veralteten Key ${key_id} bei $host entfernt."
            return 0
            ;;
        404)
            debug "Key ${key_id} bei $host existiert nicht mehr."
            return 0
            ;;
        *)
            error "  Löschen von Key ${key_id} bei $host fehlgeschlagen (HTTP $code)."
            return 1
            ;;
    esac
}



module_main() {
    local target_user home_dir ssh_dir key_comment entry host short own url
    local generic_key generic_needed=0 github_authed=0
    local short_name

    echo ""
    info "Richte Git SSH-Keys ein..."
    debug "Starte Git SSH-Key Setup"
    log_action "GIT_SSH" "Starting git ssh key setup"

    if ! config_bool INSTALL_GIT_SSH; then
        debug "INSTALL_GIT_SSH ist nicht gesetzt - das Modul wurde aber explizit ausgewählt."
    fi

    gitssh_parse_services
    if [ ${#GITS_SERVICES[@]} -eq 0 ]; then
        warning "GIT_SSH_SERVICES enthält keinen gültigen Eintrag - es gibt nichts einzurichten."
        return 1
    fi

    # --- git installieren falls nicht vorhanden ---
    if ! command -v git >/dev/null 2>&1; then
        info "Installiere git..."
        if ! install_package "git"; then
            error "git Installation fehlgeschlagen."
            return 2
        fi
    fi

    # --- Ziel-User bestimmen ---
    if ! target_user="$(gitssh_resolve_user)"; then
        error "Kein gültiger Zielbenutzer gefunden - bitte GIT_SSH_USER prüfen."
        return 2
    fi

    home_dir="$(gitssh_user_home "$target_user")"
    ssh_dir="$home_dir/.ssh"
    key_comment="$(gitssh_key_comment)"
    short_name="$(hostname -s 2>/dev/null || hostname)"

    echo ""
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo -e "${C_CYAN}  Git SSH-Key Setup${C_RESET}"
    echo -e "${C_CYAN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}Zielbenutzer:${C_RESET} $target_user"
    echo -e "${C_BLUE}SSH-Key Kommentar:${C_RESET} ${key_comment}"
    echo -e "${C_BLUE}Git-Identitaet:${C_RESET} $(gitssh_git_name "$target_user") <$(gitssh_git_email "$short_name")>"

    # Der Plan steht bewusst auf stdout - so sieht man auch im Dry-Run, wie
    # die Keys auf den Servern heißen.
    echo ""
    echo "Geplante Dienste:"
    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"
        if [ "$own" = "1" ]; then
            echo "  ${host} -> ${ssh_dir}/id_ed25519_${short} (eigener Block)"
        else
            echo "  ${host} -> ${ssh_dir}/id_ed25519 (generischer Key, kein eigener Block)"
            generic_needed=1
        fi
    done
    echo ""

    # --- GitHub CLI: nur für github.com, bei Forgejo/Gitea gibt es sie nicht ---
    if gitssh_has_service "$GITS_GITHUB_HOST"; then
        if command -v gh >/dev/null 2>&1; then
            echo -e "${C_GREEN}GitHub CLI (gh) ist installiert!${C_RESET}"
            echo ""

            # 'gh auth login' ist ein interaktiver Dialog - im Dry-Run und im
            # nicht-interaktiven Modus wird er nicht ausgeführt.
            local do_login=0
            if [ "$NON_INTERACTIVE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
                info "GitHub CLI Login würde jetzt interaktiv gestartet."
            elif ask_yes_no "Möchtest du die GitHub CLI für das Setup verwenden? (Empfohlen - Key wird danach automatisch hochgeladen)" "y"; then
                do_login=1
            fi

            if [ "$do_login" = "1" ]; then
                echo ""
                echo -e "${C_YELLOW}=== GitHub CLI Login ===${C_RESET}"
                echo ""
                echo "Wähle im folgenden Dialog:"
                echo "  1. Account: GitHub.com"
                echo "  2. Protocol: SSH"
                echo "  3. Generate new SSH key: No   (der Key wird unten mit dem Namen dieses Servers erzeugt)"
                echo "  4. Authenticate: Login with a web browser"
                echo ""

                if sudo -u "$target_user" gh auth login; then
                    success "✅ GitHub CLI Authentifizierung erfolgreich!"
                    log_action "GIT_SSH" "GitHub CLI auth successful"
                    github_authed=1
                else
                    warning "GitHub CLI Login fehlgeschlagen - der Key wird manuell eingetragen."
                fi
            fi
        else
            echo -e "${C_YELLOW}GitHub CLI (gh) ist nicht installiert.${C_RESET}"
            echo ""

            local install_cli=0
            if [ "$NON_INTERACTIVE" = "1" ] || [ "$DRY_RUN" = "1" ]; then
                info "GitHub CLI würde jetzt installiert."
                install_cli=1
            elif ask_yes_no "Möchtest du die GitHub CLI installieren? (Empfohlen für einfachere Einrichtung)" "y"; then
                install_cli=1
            fi

            if [ "$install_cli" = "1" ]; then
                info "Installiere GitHub CLI..."
                if gitssh_install_cli && command -v gh >/dev/null 2>&1; then
                    success "GitHub CLI installiert."
                else
                    warning "GitHub CLI konnte nicht installiert werden."
                fi
            fi
        fi
    fi

    # --- Keys erzeugen ---
    echo ""
    echo -e "${C_YELLOW}=== SSH-Key Einrichtung ===${C_RESET}"
    echo ""

    run_cmd mkdir -p "$ssh_dir"
    run_cmd chmod 700 "$ssh_dir"
    [ "$target_user" != "root" ] && run_cmd chown "$target_user:$target_user" "$ssh_dir"

    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"
        [ "$own" = "1" ] || continue

        if ! gitssh_ensure_key "$ssh_dir" "$target_user" \
                "${ssh_dir}/id_ed25519_${short}" "$key_comment"; then
            return 2
        fi
    done

    # Dienste ohne eigenen Block brauchen den generischen Key - sonst gäbe es
    # für sie gar keinen verwendbaren Schlüssel.
    if [ "$generic_needed" = "1" ]; then
        if ! gitssh_ensure_key "$ssh_dir" "$target_user" "${ssh_dir}/id_ed25519" "$key_comment"; then
            return 2
        fi
    fi

    # --- Öffentliche Keys anzeigen ---
    if [ "$DRY_RUN" != "1" ]; then
        for entry in "${GITS_SERVICES[@]}"; do
            IFS='|' read -r host short own url <<< "$entry"
            [ "$own" = "1" ] || continue

            if [ -f "${ssh_dir}/id_ed25519_${short}.pub" ]; then
                echo ""
                echo -e "${C_GREEN}=== ${host}: öffentlicher SSH-Key ===${C_RESET}"
                echo ""
                cat "${ssh_dir}/id_ed25519_${short}.pub"
                echo ""
                echo -e "${C_YELLOW}Bei ${host} unter den SSH-Keys eintragen:${C_RESET}"
                echo -e "  ${C_BLUE}$(gitssh_settings_url "$host" "$url")${C_RESET}"
                echo ""
            fi
        done
    fi

    # --- ~/.ssh/config ---
    gitssh_write_ssh_config "$ssh_dir" "$target_user" "$key_comment" || return 2

    # --- known_hosts ---
    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"
        gitssh_known_hosts_add "$ssh_dir" "$target_user" "$host"
    done

# --- GitHub CLI: fertigen Key hochladen ---
    if [ "$github_authed" = "1" ] && [ -f "${ssh_dir}/id_ed25519_github.pub" ]; then
        echo ""
        info "Lade den Key über die GitHub CLI hoch..."
        run_cmd sudo -u "$target_user" gh ssh-key add \
            "${ssh_dir}/id_ed25519_github.pub" -t "$key_comment"

        if gitssh_test_connection "$target_user" "$GITS_GITHUB_HOST"; then
            success "✅ SSH-Verbindung zu $GITS_GITHUB_HOST funktioniert!"
        else
            warning "Verbindung zu $GITS_GITHUB_HOST nicht bestätigt - bitte den Key in der Weboberfläche prüfen."
        fi
    fi

    # --- Key über die API registrieren ---
    # Ohne Token bleibt der manuelle Weg: der öffentliche Key wird ausgegeben
    # und muss in der Weboberfläche hinterlegt werden.
    echo ""
    local uploaded=0 manual=0
    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"
        [ "$own" = "1" ] || continue

        local pub_file="${ssh_dir}/id_ed25519_${short}.pub"
        if [ ! -f "$pub_file" ] && [ "$DRY_RUN" != "1" ]; then
            debug "Kein oeffentlicher Key fuer $host vorhanden - Upload uebersprungen."
            manual=$((manual + 1))
            continue
        fi

        if ! gitssh_resolve_token "$short"; then
            manual=$((manual + 1))
            continue
        fi

        if gitssh_upload_key_via_api "$host" "$short" "$url" \
                "$pub_file" "$key_comment" "$GITS_RESOLVED_TOKEN"; then
            uploaded=$((uploaded + 1))

            # Erst jetzt - wo der aktuelle Key sicher registriert ist - werden
            # Reste aus frueheren Laeufen entfernt. Die Reihenfolge ist
            # bewusst: ansonsten gaebe es zwischen DELETE und POST kein
            # Fenster mit irgendeinem gueltigen Key.
            stale_ids=$(gitssh_find_stale_key_ids "$host" "$url" \
                "$GITS_RESOLVED_TOKEN" "$key_comment" \
                "$(tr -d '\n' < "$pub_file" 2>/dev/null || echo '')")
            for stale_id in $stale_ids; do
                gitssh_delete_key "$host" "$url" "$GITS_RESOLVED_TOKEN" "$stale_id"
            done
        else
            manual=$((manual + 1))
        fi
        GITS_RESOLVED_TOKEN=""
    done

    if [ "$uploaded" -gt 0 ]; then
        success "✅ $uploaded Schlüssel per API registriert."
    fi
    if [ "$manual" -gt 0 ]; then
        info "$manual Schlüssel müssen noch von Hand in der Weboberfläche hinterlegt werden."
        for entry in "${GITS_SERVICES[@]}"; do
            IFS='|' read -r host short own url <<< "$entry"
            [ "$own" = "1" ] || continue
            pub_file="${ssh_dir}/id_ed25519_${short}.pub"
            [ -f "$pub_file" ] || continue
            echo ""
            echo -e "  ${host} (Titel: ${key_comment}):"
            echo "    $(cat "$pub_file")"
        done
    fi

    # --- Git-Identität ---
    # Ohne user.name/user.email schlägt "git commit" auf dem Server fehl.
    gitssh_set_git_identity "$target_user" "$home_dir" "$short_name"

    # --- Zusammenfassung ---
    echo ""
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo -e "${C_GREEN}  Setup abgeschlossen!${C_RESET}"
    echo -e "${C_GREEN}===========================================${C_RESET}"
    echo ""
    echo -e "${C_BLUE}SSH-Key Kommentar:${C_RESET} ${key_comment} (${short_name})"
    echo -e "${C_BLUE}Git-Dienste:${C_RESET}"
    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own url <<< "$entry"
        if [ "$own" = "1" ]; then
            echo "  git clone git@${host}:<benutzer>/<repository>.git"
        else
            echo "  git clone git@${host}:<benutzer>/<repository>.git   (generischer Key)"
        fi
    done
    echo ""
    echo "authorized_keys wurde nicht verändert - diese Keys gelten nur für Git-Zugriffe."
    echo ""

    log_action "GIT_SSH" "Setup completed for ${#GITS_SERVICES[@]} service(s): $key_comment"
    return 0
}

module_status() {
    local target_user ssh_dir entry host short own
    local have=0 total=0

    if ! target_user="$(gitssh_resolve_user)"; then
        echo "kein Zielbenutzer ermittelbar"
        return 0
    fi

    ssh_dir="$(gitssh_user_home "$target_user")/.ssh"
    gitssh_parse_services

    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own _ <<< "$entry"
        [ "$own" = "1" ] || continue
        total=$((total + 1))
        [ -f "${ssh_dir}/id_ed25519_${short}" ] && have=$((have + 1))
    done

    if [ "$total" -eq 0 ]; then
        echo "kein Dienst mit eigenem Block konfiguriert"
    else
        echo "${have}/${total} eigene Git-Keys für '${target_user}'"
    fi
    return 0
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|IST|SOLL" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
module_audit() {
    local target_user ssh_dir entry host short own missing=""
    local have=0 total=0

    if ! config_bool INSTALL_GIT_SSH; then
        echo "info|Keine Git-SSH-Keys angefordert|INSTALL_GIT_SSH ist nicht gesetzt"
        return 0
    fi

    if ! target_user="$(gitssh_resolve_user)"; then
        echo "info|SSH-Keys nicht bewertbar|kein Zielbenutzer ermittelbar - GIT_SSH_USER, ADMIN_USER und root passen nicht"
        return 0
    fi

    ssh_dir="$(gitssh_user_home "$target_user")/.ssh"
    gitssh_parse_services

    for entry in "${GITS_SERVICES[@]}"; do
        IFS='|' read -r host short own _ <<< "$entry"
        [ "$own" = "1" ] || continue
        total=$((total + 1))
        if [ -f "${ssh_dir}/id_ed25519_${short}" ]; then
            have=$((have + 1))
        else
            missing="${missing:+$missing, }id_ed25519_${short} (${host})"
        fi
    done

    if [ "$total" -eq 0 ]; then
        echo "info|Keine Dienste mit eigenem Block|GIT_SSH_SERVICES enthält keinen Eintrag mit 'eigener Block'=1"
        return 0
    fi

    if [ "$have" -eq "$total" ]; then
        echo "ok|${have}/${total} Git-Keys für '${target_user}'"
    else
        echo "abweichung|${have}/${total} Git-Keys für '${target_user}'|${total}/${total} Git-Keys: ${missing}"
    fi
    return 0
}