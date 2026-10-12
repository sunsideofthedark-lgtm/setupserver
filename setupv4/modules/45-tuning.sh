#!/bin/bash
# ==============================================================================
# Modul: tuning
# ==============================================================================
# Konservative System-Tuning-Einstellungen fuer Docker-Hosts:
#
#   A) sysctl - nur Werte, die nirgends sonst gesetzt sind
#   B) Swap   - nur wenn ueberhaupt kein Swap aktiv ist
#   C) journald - Groessenbegrenzung der Systemlogs
#
# Jeder Teil hat einen eigenen Schalter und ist einzeln idempotent: ein zweiter
# Lauf ueberschreibt die eigene Datei, ohne doppelte Eintraege in sysctl.conf
# oder fstab zu erzeugen und ohne einen bereits aktiven Swap anzufassen.
#
# Config:
#   TUNING_SYSCTL            - sysctl-Werte setzen (Default true)
#   TUNING_SWAP              - Swapdatei anlegen, falls kein Swap aktiv (Default true)
#   TUNING_SWAP_SIZE         - Groesse der Swapdatei (Default 2G, max. halbes RAM)
#   TUNING_JOURNALD          - journald begrenzen (Default true)
#   TUNING_JOURNALD_MAXUSE   - SystemMaxUse des Journal (Default 200M)
# ==============================================================================

MODULE_ID="tuning"
MODULE_NAME="System-Tuning"
MODULE_DESC="sysctl-Werte, Swapdatei und journald-Groessenbegrenzung setzen"
MODULE_ORDER=45
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("performance" "system")

TUNING_SYSCTL_FILE="/etc/sysctl.d/99-serversetup.conf"
TUNING_JOURNALD_DIR="/etc/systemd/journald.conf.d"
TUNING_JOURNALD_FILE="${TUNING_JOURNALD_DIR}/99-serversetup.conf"
TUNING_SWAP_FILE="/swapfile"

# Zielwerte "key = value". Bewusst konservativ: sie sind der von Docker
# empfohlene Untere Rand und verhalten sich auch ohne Docker unauffaellig.
TUNING_SYSCTL_DEFAULTS=(
    "vm.swappiness = 1"
    "vm.max_map_count = 262144"
    "fs.file-max = 2097152"
    "fs.inotify.max_user_instances = 8192"
    "fs.inotify.max_user_watches = 524288"
    "net.core.somaxconn = 1024"
    "net.ipv4.tcp_syncookies = 1"
)

# ==============================================================================
# A) sysctl
# ==============================================================================

# Ist der Schluessel in einer bestehenden sysctl-Datei gesetzt?
# Unsere eigene Datei wird absichtlich uebergangen: sie wird bei jedem Lauf
# komplett neu geschrieben und wuerde sich sonst selbst "setzen".
tuning_sysctl_set_elsewhere() {
    local key="$1" file
    for file in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        [ -f "$file" ] || continue
        [ "$file" = "$TUNING_SYSCTL_FILE" ] && continue
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Erzeugt die Liste der Zeilen, die in unsere Datei gehoeren - ohne Kommentar,
# damit sie sowohl gezaehlt als auch geschrieben werden kann.
tuning_sysctl_plan() {
    local line key value

    for line in "${TUNING_SYSCTL_DEFAULTS[@]}"; do
        key="${line%%=*}"
        key="${key// /}"
        value="${line#*=}"
        value="${value// /}"
        tuning_sysctl_set_elsewhere "$key" && continue
        echo "${key} = ${value}"
    done

    # IP-Forwarding nur, wenn Docker vorhanden ist - ohne Docker ist es eine
    # Firewall-Aenderung, die niemand bestellt hat.
    if command -v docker >/dev/null 2>&1; then
        tuning_sysctl_set_elsewhere "net.ipv4.ip_forward" \
            || echo "net.ipv4.ip_forward = 1"
    fi

    return 0
}

tuning_apply_sysctl() {
    local plan count=0 line

    plan="$(tuning_sysctl_plan)"

    if [ -z "$plan" ]; then
        info "Alle Zielwerte sind bereits in anderen sysctl-Dateien gesetzt."
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] && count=$((count + 1))
    done <<< "$plan"

    if [ "$DRY_RUN" = "1" ]; then
        info "[Trockenlauf] würde ${TUNING_SYSCTL_FILE} mit $count Werten schreiben:"
        while IFS= read -r line; do
            [ -n "$line" ] && info "    $line"
        done <<< "$plan"
        run_cmd sysctl --system
        return 0
    fi

    mkdir -p /etc/sysctl.d 2>/dev/null || true
    create_backup "$TUNING_SYSCTL_FILE"

    {
        echo "# Von setupv4 (Modul tuning) erzeugt - conservative Docker-Werte."
        echo "# Werte, die anderswo gesetzt sind, werden hier bewusst nicht wiederholt."
        echo "$plan"
    } > "$TUNING_SYSCTL_FILE" || {
        error "sysctl-Datei konnte nicht geschrieben werden: $TUNING_SYSCTL_FILE"
        return 1
    }

    chmod 0644 "$TUNING_SYSCTL_FILE" 2>/dev/null || true
    log_action "TUNING" "sysctl-Werte geschrieben: $TUNING_SYSCTL_FILE ($count)"

    if ! run_cmd sysctl --system; then
        warning "sysctl --system meldet einen Fehler - Werte gelten erst nach dem naechsten Boot."
    else
        success "$count sysctl-Werte gesetzt und aktiviert."
    fi

    return 0
}

# ==============================================================================
# B) Swap
# ==============================================================================

# Ist der Swap bereits aktiv? Leerer swapon-Ausgabe = kein Swap.
tuning_swap_active() {
    swapon --show 2>/dev/null | grep -q "$TUNING_SWAP_FILE"
}

# Ist ueberhaupt irgendein Swap aktiv? Das Modul fasst keinen bestehenden
# Swap an - also ist das der Zustand, den der Audit bewerten muss.
tuning_any_swap_active() {
    swapon --show 2>/dev/null | grep -q .
}

tuning_ram_mb() {
    local mb
    mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    case "$mb" in
        ''|*[!0-9]*) mb=0 ;;
    esac
    echo "$mb"
}

# "2G" / "512M" / "1048576" (Bytes) -> Megabyte
tuning_size_to_mb() {
    local size="$1" num unit

    case "$size" in
        ''|*[!0-9KMGkmg]*) return 1 ;;
    esac

    num="${size%%[KMGkmg]*}"
    unit="${size#"$num"}"
    [ -n "$num" ] || return 1

    case "${unit^^}" in
        G)  echo $((num * 1024)) ;;
        M)  echo "$num" ;;
        K)  echo $((num / 1024)) ;;
        "") echo $((num / 1048576)) ;;
        *)  return 1 ;;
    esac
    return 0
}

# Gewuenschte Groesse, aber nie mehr als die Haelfte des RAM
# (bei sehr kleinem RAM bleibt es bei 1G).
tuning_swap_size_mb() {
    local wanted ram_mb half
    local configured

    configured="$(config_get TUNING_SWAP_SIZE 2G)"
    if ! wanted="$(tuning_size_to_mb "$configured")" || [ "$wanted" -le 0 ]; then
        warning "Ungueltige TUNING_SWAP_SIZE: '$configured' - verwende 2G."
        wanted=2048
    fi

    ram_mb="$(tuning_ram_mb)"
    if [ "$ram_mb" -gt 0 ]; then
        half=$((ram_mb / 2))
        [ "$half" -lt 1024 ] && half=1024
        if [ "$wanted" -gt "$half" ]; then
            warning "TUNING_SWAP_SIZE ($wantedMB) ist groesser als die Haelfte des RAM - verwende ${half}MB."
            wanted="$half"
        fi
    fi

    echo "$wanted"
}

tuning_apply_swap() {
    local size_mb size_arg created=0

    if swapon --show 2>/dev/null | grep -q .; then
        info "Swap bereits vorhanden - keine Aktion."
        debug "$(swapon --show 2>/dev/null | tr '\n' ';')"
        return 1
    fi

    size_mb="$(tuning_swap_size_mb)"
    size_arg="${size_mb}M"
    info "Kein Swap aktiv - lege ${TUNING_SWAP_FILE} mit ${size_arg} an."

    if [ -f "$TUNING_SWAP_FILE" ]; then
        info "Swapdatei existiert bereits - wird nur neu formatiert."
    elif command -v fallocate >/dev/null 2>&1; then
        if run_cmd fallocate -l "$size_arg" "$TUNING_SWAP_FILE"; then
            created=1
        fi
    fi

    # Auf Dateisystemen ohne fallocate-Unterstuetzung (z. B. btrfs) oder nach
    # einem fehlgeschlagenen Aufruf bleibt dd als Rueckfall.
    if [ "$created" = "0" ] && [ ! -f "$TUNING_SWAP_FILE" ]; then
        run_cmd dd if=/dev/zero of="$TUNING_SWAP_FILE" bs=1M count="$size_mb"
    fi

    if [ "$DRY_RUN" != "1" ] && [ ! -f "$TUNING_SWAP_FILE" ]; then
        error "Swapdatei $TUNING_SWAP_FILE konnte nicht angelegt werden."
        return 1
    fi

    run_cmd chmod 600 "$TUNING_SWAP_FILE"
    run_cmd mkswap "$TUNING_SWAP_FILE"

    # fstab: genau eine Zeile, und nur wenn /swapfile dort noch nicht steht
    if grep -qE "^${TUNING_SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
        debug "fstab enthaelt bereits einen Eintrag fuer $TUNING_SWAP_FILE."
    else
        [ "$DRY_RUN" != "1" ] && create_backup /etc/fstab
        run_eval "printf '${TUNING_SWAP_FILE} none swap sw 0 0\n' >> /etc/fstab"
    fi

    if tuning_swap_active; then
        info "Swap ist bereits aktiv - kein erneutes swapon."
    else
        run_cmd swapon "$TUNING_SWAP_FILE"
    fi

    # swappiness nur hier setzen, wenn Teil A nicht sowieso laeuft
    if ! config_bool TUNING_SYSCTL; then
        run_cmd sysctl -w vm.swappiness=1
    fi

    if [ "$DRY_RUN" != "1" ] && ! tuning_swap_active; then
        warning "Swap wurde angelegt, ist aber nicht aktiv - siehe 'swapon --show'."
        return 1
    fi

    success "Swap eingerichtet: ${TUNING_SWAP_FILE} (${size_arg})"
    return 0
}

# ==============================================================================
# C) journald
# ==============================================================================

# Laeuft systemd als PID 1? Ohne das ist journald nicht konfigurierbar.
tuning_systemd_running() {
    [ -d /run/systemd/system ]
}

tuning_apply_journald() {
    local maxuse

    if ! tuning_systemd_running; then
        info "systemd laeuft nicht - journald wird nicht konfiguriert."
        return 1
    fi

    maxuse="$(config_get TUNING_JOURNALD_MAXUSE 200M)"

    run_cmd mkdir -p "$TUNING_JOURNALD_DIR"

    if [ "$DRY_RUN" = "1" ]; then
        info "[Trockenlauf] würde ${TUNING_JOURNALD_FILE} schreiben:"
        info "    [Journal] SystemMaxUse=${maxuse} RuntimeMaxUse=50M MaxRetentionSec=2week ForwardToSyslog=yes"
    else
        create_backup "$TUNING_JOURNALD_FILE"

        cat > "$TUNING_JOURNALD_FILE" << EOF
# Von setupv4 (Modul tuning) erzeugt - begrenzt den Platz fuer Systemlogs.
[Journal]
SystemMaxUse=${maxuse}
RuntimeMaxUse=50M
MaxRetentionSec=2week
ForwardToSyslog=yes
EOF

        chmod 0644 "$TUNING_JOURNALD_FILE" 2>/dev/null || true
        log_action "TUNING" "journald konfiguriert: $TUNING_JOURNALD_FILE"
    fi

    manage_service restart systemd-journald
    # --flush schreibt die noch nicht persistierten Logs in /var/log/journal
    run_cmd journalctl --flush

    if [ "$DRY_RUN" != "1" ]; then
        success "journald auf SystemMaxUse=${maxuse} begrenzt."
    fi

    return 0
}

# ==============================================================================
# Modulschnittstelle
# ==============================================================================

module_main() {
    local do_sysctl=0 do_swap=0 do_journald=0 done_count=0
    local done_parts=""

    config_bool TUNING_SYSCTL && do_sysctl=1
    config_bool TUNING_SWAP && do_swap=1
    config_bool TUNING_JOURNALD && do_journald=1

    if [ "$do_sysctl" = "0" ] && [ "$do_swap" = "0" ] && [ "$do_journald" = "0" ]; then
        skip "Weder TUNING_SYSCTL noch TUNING_SWAP noch TUNING_JOURNALD gesetzt."
        return 1
    fi

    if [ "$do_sysctl" = "1" ]; then
        info "Setze sysctl-Werte..."
        if tuning_apply_sysctl; then
            done_count=$((done_count + 1))
            done_parts="${done_parts:+$done_parts, }sysctl"
        fi
    fi

    if [ "$do_swap" = "1" ]; then
        echo ""
        info "Pruefe Swap..."
        if tuning_apply_swap; then
            done_count=$((done_count + 1))
            done_parts="${done_parts:+$done_parts, }Swap"
        fi
    fi

    if [ "$do_journald" = "1" ]; then
        echo ""
        info "Begrenze journald..."
        if tuning_apply_journald; then
            done_count=$((done_count + 1))
            done_parts="${done_parts:+$done_parts, }journald"
        fi
    fi

    echo ""
    if [ "$done_count" -eq 3 ]; then
        success "System-Tuning abgeschlossen - alle 3 Teile eingerichtet (sysctl, Swap, journald)."
    else
        success "System-Tuning abgeschlossen - $done_count von 3 Teilen eingerichtet: $done_parts"
        [ "$done_count" -eq 0 ] && info "Kein Teil wurde eingerichtet."
    fi
    return 0
}

module_status() {
    local parts=""

    if [ -f "$TUNING_SYSCTL_FILE" ]; then
        parts="${parts}sysctl"
    fi
    if tuning_any_swap_active; then
        parts="${parts:+, }Swap aktiv"
    fi
    if [ -f "$TUNING_JOURNALD_FILE" ]; then
        local maxuse
        maxuse=$(awk -F= '/^SystemMaxUse=/ {print $2}' "$TUNING_JOURNALD_FILE" 2>/dev/null)
        [ -n "$maxuse" ] || maxuse="?"
        parts="${parts:+, }journald ${maxuse}"
    fi

    if [ -z "$parts" ]; then
        echo "nichts eingerichtet"
    else
        echo "${parts# }"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|IST|SOLL" aus und sonst nichts.
# Bewertet wird nur, was die Konfiguration anfordert - ein nicht gesetzter
# Schalter ist kein Ziel und damit keine Abweichung.
module_audit() {
    local do_sysctl=0 do_swap=0 do_journald=0 missing=""

    config_bool TUNING_SYSCTL && do_sysctl=1
    config_bool TUNING_SWAP && do_swap=1
    config_bool TUNING_JOURNALD && do_journald=1

    if [ "$do_sysctl" = "1" ] && [ ! -f "$TUNING_SYSCTL_FILE" ]; then
        missing="sysctl-Datei"
    fi

    if [ "$do_swap" = "1" ] && ! tuning_any_swap_active; then
        missing="${missing}${missing:+, }aktiver Swap"
    fi

    if [ "$do_journald" = "1" ]; then
        if [ ! -f "$TUNING_JOURNALD_FILE" ]; then
            missing="${missing}${missing:+, }journald-Limit"
        elif ! grep -q '^SystemMaxUse=' "$TUNING_JOURNALD_FILE" 2>/dev/null; then
            missing="${missing}${missing:+, }SystemMaxUse"
        fi
    fi

    if [ "$do_sysctl" = "0" ] && [ "$do_swap" = "0" ] && [ "$do_journald" = "0" ]; then
        echo "info|kein Tuning angefordert|TUNING_SYSCTL, TUNING_SWAP und TUNING_JOURNALD sind nicht gesetzt"
        return 0
    fi

    if [ -n "$missing" ]; then
        echo "abweichung|fehlt: ${missing}|sysctl-Datei, aktiver Swap und journald-Limit gesetzt"
        return 0
    fi

    echo "ok|sysctl, Swap und journald-Limit eingerichtet"
    return 0
}