#!/bin/bash
# ==============================================================================
# Modul: monitoring-tools
# ==============================================================================
# Bündelt die klassischen Werkzeuge, die auf einem Server praktisch immer
# gebraucht werden: Prozess-/I/O-/Netzwerk-Monitoring, Terminal-Multiplexer,
# Datenbank-Clients sowie git und zip/unzip.
#
# Jedes Werkzeug hat seinen eigenen Config-Schalter - nicht gesetzte Schalter
# werden stillschweigend übersprungen. Ohne einen einzigen aktiven Schalter ist
# das Modul nicht anwendbar.
#
# Config:
#   INSTALL_HTOP       - htop        (Default false)
#   INSTALL_IOTOP      - iotop       (Default false)
#   INSTALL_NETHOGS    - nethogs     (Default false)
#   INSTALL_NCUDU      - ncdu        (Default false)
#   INSTALL_TMUX       - tmux        (Default false)
#   INSTALL_DB_CLIENTS - DB-Clients  (Default false)
#   INSTALL_GIT        - git         (Default false)
#   INSTALL_ZIP        - zip/unzip   (Default false)
# ==============================================================================

MODULE_ID="monitoring-tools"
MODULE_NAME="Monitoring- und Alltagswerkzeuge"
MODULE_DESC="Installiert htop, iotop, nethogs, ncdu, tmux, DB-Clients, git und zip"
MODULE_ORDER=91
MODULE_REQUIRED_KEYS=()
MODULE_TAGS=("monitoring" "tools")

# key|paket(e)|Kommando zur Prüfung
#   key     - Config-Schalter
#   paket   - was an install_package übergeben wird
#   kommando - Binary, mit dem im Status geprüft wird (darf leer sein)
MONTOOLS_LIST=(
    "INSTALL_HTOP|htop|htop"
    "INSTALL_IOTOP|iotop|iotop"
    "INSTALL_NETHOGS|nethogs|nethogs"
    "INSTALL_NCUDU|ncdu|ncdu"
    "INSTALL_TMUX|tmux|tmux"
    "INSTALL_DB_CLIENTS|mariadb-client postgresql-client|"
    "INSTALL_GIT|git|git"
    "INSTALL_ZIP|zip unzip|zip"
)

module_main() {
    local entry key packages installed=0 failed=0

    if ! config_bool INSTALL_HTOP && ! config_bool INSTALL_IOTOP &&
       ! config_bool INSTALL_NETHOGS && ! config_bool INSTALL_NCUDU &&
       ! config_bool INSTALL_TMUX && ! config_bool INSTALL_DB_CLIENTS &&
       ! config_bool INSTALL_GIT && ! config_bool INSTALL_ZIP; then
        skip "Kein Werkzeug-Schalter gesetzt - nichts zu installieren."
        return 1
    fi

    echo ""

    for entry in "${MONTOOLS_LIST[@]}"; do
        IFS='|' read -r key packages _ <<< "$entry"

        if ! config_bool "$key"; then
            debug "${key} ist nicht gesetzt - wird übersprungen."
            continue
        fi

        if install_package "$packages"; then
            success "${key#INSTALL_} installiert."
            installed=$((installed + 1))
        else
            error "${key#INSTALL_} Installation fehlgeschlagen."
            failed=$((failed + 1))
        fi
    done

    echo ""
    info "Installiert: ${installed} | Fehlgeschlagen: ${failed}"

    # Nur wenn gar nichts geklappt hat, ist das ein echter Fehler
    if [ "$failed" -gt 0 ] && [ "$installed" -eq 0 ]; then
        return 2
    fi

    return 0
}

module_status() {
    local entry key _ command present=0
    local total="${#MONTOOLS_LIST[@]}"
    local missing=""

    for entry in "${MONTOOLS_LIST[@]}"; do
        IFS='|' read -r key _ command <<< "$entry"
        [ -n "$command" ] || continue

        if command -v "$command" >/dev/null 2>&1; then
            present=$((present + 1))
        else
            missing="${missing} ${key#INSTALL_}"
        fi
    done

    if [ "$present" -eq 0 ]; then
        echo "nichts installiert"
        return 0
    fi

    if [ -n "$missing" ]; then
        echo "${present}/${total} vorhanden, fehlt:${missing}"
    else
        echo "${present}/${total} vorhanden"
    fi
}

# --- Audit ---
# Gibt genau eine Zeile "ZUSTAND|ZIELZUSTAND|BEGRUENDUNG" aus und sonst nichts:
# show_audit ruft diese Funktion per $( ) auf, jedes zusaetzliche Output wuerde
# die Tabelle zerreissen.
# Geprueft wird nur, was die Konfiguration auch wirklich anfordert - ein
# nicht gesetzter Schalter ist kein Ziel und damit keine Abweichung.
module_audit() {
    local entry key _ command
    local wanted=0 missing=""

    for entry in "${MONTOOLS_LIST[@]}"; do
        IFS='|' read -r key _ command <<< "$entry"

        config_bool "$key" || continue
        wanted=$((wanted + 1))

        # Ohne Pruefkommando (DB-Clients) gibt es nichts zu bewerten
        if [ -z "$command" ]; then
            continue
        fi

        command -v "$command" >/dev/null 2>&1 || missing="${missing}${key#INSTALL_} "
    done

    if [ "$wanted" -eq 0 ]; then
        echo "info|Keine Werkzeuge angefordert|kein INSTALL_*-Schalter dieses Moduls ist gesetzt"
        return 0
    fi

    if [ -n "$missing" ]; then
        echo "abweichung|die angeforderten Werkzeuge sind nicht alle installiert|fehlt: ${missing% }"
        return 0
    fi

    echo "ok|alle ${wanted} angeforderten Werkzeuge vorhanden"
    return 0
}