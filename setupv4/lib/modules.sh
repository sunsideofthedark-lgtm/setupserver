#!/bin/bash
# ==============================================================================
# setupv4/lib/modules.sh - Module finden, auswählen, ausführen
# ==============================================================================
# Modulkonvention
# ---------------
# Jede Datei in modules/ definiert NUR Metadaten und Funktionen - beim Laden
# darf kein Code ausgeführt werden:
#
#   MODULE_ID="firewall"          # eindeutig, wird auf der Befehlszeile benutzt
#   MODULE_NAME="Firewall"        # Kurzname für die Ausgabe
#   MODULE_DESC="Beschreibung"    # Einzeiler
#   MODULE_ORDER=70               # Ausführungsreihenfolge (niedrig zuerst)
#   MODULE_REQUIRED_KEYS=()       # Config-Schluessel, die gesetzt sein muessen
#   MODULE_TAGS=("sicherheit")    # Freitext fuer Gruppierung/Filter
#
#   module_main() { ... }         # eigentliche Arbeit
#   module_status() { ... }       # optional: Statusausgabe fuer --status
#
# module_main() nutzt return 0 fuer Erfolg, return 1 fuer "nicht anwendbar"
# (wird als SKIP geloggt) und return 2 fuer einen echten Fehler.
# ==============================================================================

MODULES_DIR="${MODULES_DIR:-}"   # wird vom Hauptscript gesetzt
MODULE_RESULTS=()                # "id|status|dauer"
CURRENT_MODULE=""

# --- Auswahl: gesondert benannte Module ---
# Module, die der Benutzer EINZELN und namentlich benannt hat - entweder über
# "--modules <id>" auf der Kommandozeile oder über eine Nummer in der
# interaktiven Modulauswahl. Diese Module laufen auch dann, wenn ihr eigener
# INSTALL_*-Schalter nicht gesetzt ist: der Benutzer hat sie sich ausdrücklich
# gewünscht.
#
# Bei einer Sammelauswahl ("Komplettes Setup", "alle", die MODULES-Liste aus der
# Config) gilt dagegen der Schalter. Ein Modul ohne gesetzten Schalter wird
# dann übersprungen - sonst liefen beim Komplett-Setup auch Module, die in der
# Config gar nicht aktiviert sind, und schlugen an fehlenden Voraussetzungen
# fehl (Docker, Netzwerk, Zugangsdaten).
EXPLICIT_MODULES=()

# Wurde dieses Modul vom Benutzer gesondert benannt?
module_is_explicit() {
    local module_id="$1" m

    [ ${#EXPLICIT_MODULES[@]} -gt 0 ] || return 1
    for m in "${EXPLICIT_MODULES[@]}"; do
        [ "$m" = "$module_id" ] && return 0
    done
    return 1
}

# Soll das aktuelle Modul laufen?
#
#   module_switch_enabled <SCHALTER>
#
# - Schalter gesetzt                            -> ja
# - Schalter nicht gesetzt, Modul gesondert benannt -> ja
# - sonst                                       -> nein (Modul wird übersprungen)
#
# Aufruf aus einem Modul heraus; das Modul selbst wird über $MODULE_ID erkannt.
module_switch_enabled() {
    local key="$1"

    if config_bool "$key"; then
        return 0
    fi

    if [ -n "${MODULE_ID:-}" ] && module_is_explicit "$MODULE_ID"; then
        return 0
    fi

    return 1
}

# --- Discovery ---
# Liest die Metadaten aller Module. Die Auswertung läuft in einem Subshell,
# damit ein fehlerhaftes Modul den Loader nicht beeinflusst.
discover_modules() {
    AVAILABLE_MODULES=()
    local file meta id name desc order

    for file in "$MODULES_DIR"/*.sh; do
        [ -e "$file" ] || continue

        meta=$(
            MODULE_FILE="$file" bash -c '
                # shellcheck disable=SC1090
                source "$MODULE_FILE" || exit 1
                printf "%s\n%s\n%s\n%s\n%s\n%s\n" \
                    "${MODULE_ID:-}" "${MODULE_NAME:-}" \
                    "${MODULE_DESC:-}" "${MODULE_ORDER:-999}" \
                    "${MODULE_CATEGORY:-base}" "${MODULE_SWITCH:-}"
            ' 2>/dev/null
        ) || {
            warning "Modul konnte nicht gelesen werden: $(basename "$file")"
            continue
        }

        id=$(echo "$meta" | sed -n 1p)
        name=$(echo "$meta" | sed -n 2p)
        desc=$(echo "$meta" | sed -n 3p)
        order=$(echo "$meta" | sed -n 4p)
        category=$(echo "$meta" | sed -n 5p)
        switches=$(echo "$meta" | sed -n 6p)

        if [ -z "$id" ]; then
            warning "Modul ohne MODULE_ID übersprungen: $(basename "$file")"
            continue
        fi

        AVAILABLE_MODULES+=("${order}|${id}|${name}|${desc}|${file}|${category}|${switches}")
        debug "Modul gefunden: $id ($name)"
    done

    # Nach MODULE_ORDER sortieren.
    # Wichtig: mapfile statt $(...) - Beschreibungen enthalten Leerzeichen und
    # würden bei einer Wortzerlegung zerstückelt.
    if [ ${#AVAILABLE_MODULES[@]} -gt 0 ]; then
        mapfile -t AVAILABLE_MODULES < <(printf '%s\n' "${AVAILABLE_MODULES[@]}" | sort -t'|' -k1,1n)
    fi

    debug "${#AVAILABLE_MODULES[@]} Module verfügbar"
}

# --- Auswahl ---
# Ermittelt die auszuführenden Modul-IDs in Ausführungsreihenfolge.
# Quellen in dieser Priorität: --modules > Config MODULES > Interaktion
#
# Rückgabewerte:
#   0  Auswahl erfolgreich ermittelt
#   1  Auswahl war ungültig (z. B. unbekanntes Modul) - aufrufer MUSS abbrechen
#   2  Keine Auswahlquelle angegeben - aufrufer DARF interaktiv nachfragen
resolve_module_selection() {
    local cli_modules="$1"

    if [ -n "$cli_modules" ]; then
        SELECTED_MODULES=()
        EXPLICIT_MODULES=()
        local m
        IFS=',' read -ra m <<< "$cli_modules"
        local id
        for id in "${m[@]}"; do
            id="$(echo "$id" | xargs)"
            [ -z "$id" ] && continue
            if module_exists "$id"; then
                SELECTED_MODULES+=("$id")
                # Auf der Kommandozeile benannt - das Modul laeuft auch ohne
                # gesetzten INSTALL_*-Schalter.
                EXPLICIT_MODULES+=("$id")
            else
                error "Unbekanntes Modul: '$id'"
                error "Verfügbare: $(list_module_ids)"
                return 1
            fi
        done
    elif [ ${#MODULES[@]} -gt 0 ]; then
        SELECTED_MODULES=()
        # Die MODULES-Liste aus der Config ist eine Sammelauswahl - hier
        # entscheidet der INSTALL_*-Schalter, nicht die Nennung in der Liste.
        EXPLICIT_MODULES=()
        local id
        for id in "${MODULES[@]}"; do
            id="$(echo "$id" | xargs)"
            [ -z "$id" ] && continue
            if module_exists "$id"; then
                SELECTED_MODULES+=("$id")
            else
                warning "Modul aus Config nicht verfügbar, wird übersprungen: '$id'"
            fi
        done
    else
        return 2
    fi

    return 0
}

module_exists() {
    local wanted="$1"
    local entry id
    [ ${#AVAILABLE_MODULES[@]} -gt 0 ] || return 1
    for entry in "${AVAILABLE_MODULES[@]}"; do
        id=$(echo "$entry" | cut -d'|' -f2)
        [ "$id" = "$wanted" ] && return 0
    done
    return 1
}

list_module_ids() {
    local entry result=""
    [ ${#AVAILABLE_MODULES[@]} -gt 0 ] || return 0
    for entry in "${AVAILABLE_MODULES[@]}"; do
        result="$result $(echo "$entry" | cut -d'|' -f2)"
    done
    echo "${result# }"
}

module_field() {
    local module_id="$1"
    local field_index="$2"   # 1=order 2=id 3=name 4=desc 5=file 6=category 7=switches
    local entry
    [ ${#AVAILABLE_MODULES[@]} -gt 0 ] || return 1
    for entry in "${AVAILABLE_MODULES[@]}"; do
        if [ "$(echo "$entry" | cut -d'|' -f2)" = "$module_id" ]; then
            echo "$entry" | cut -d'|' -f"$field_index"
            return 0
        fi
    done
    return 1
}

module_file_for() { module_field "$1" 5; }
module_name_for() { module_field "$1" 3; }
module_desc_for() { module_field "$1" 4; }
module_category_for() { module_field "$1" 6; }
module_switches_for() { module_field "$1" 7; }

# --- Anzeige ---
show_module_list() {
    local entry order id name desc category
    printf "  %-22s %-34s %-10s %s\n" "ID" "NAME" "ART" "BESCHREIBUNG"
    printf "  %-22s %-34s %-10s %s\n" "----------------------" "----------------------------------" "----------" "--------------------------------"
    for entry in "${AVAILABLE_MODULES[@]}"; do
        order=$(echo "$entry" | cut -d'|' -f1)
        id=$(echo "$entry" | cut -d'|' -f2)
        name=$(echo "$entry" | cut -d'|' -f3)
        desc=$(echo "$entry" | cut -d'|' -f4)
        category=$(echo "$entry" | cut -d'|' -f6)
        [ "$category" = "software" ] && category="Software" || category="System"
        printf "  %-22s %-34s %-10s %s\n" "$id" "$name" "$category" "$desc"
    done
}

# --- Hauptmenü ---
# Aufbau wie im klassischen setupv3.sh, damit der Bedienweg vertraut bleibt.
# Gibt die gewählte Aktion über stdout aus: 1, 2, 3 oder 4.
# 4 = beenden.
show_main_menu() {
    local module_count=${#AVAILABLE_MODULES[@]}

    echo ""
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e "${C_CYAN}  setupv4 - Modulares Server-Setup${C_RESET}"
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo ""
    echo -e "  ${module_count} Module verfügbar."
    echo ""
    echo -e "  ${C_GREEN}1.${C_RESET} Komplettes Setup      alle Module in Ausführungsreihenfolge"
    echo -e "  ${C_GREEN}2.${C_RESET} Modulare Auswahl    einzelne Schritte selbst wählen"
    echo -e "  ${C_GREEN}3.${C_RESET} Nur prüfen          Zustand prüfen, nichts ändern (Audit)"
    echo -e "  ${C_GREEN}4.${C_RESET} Beenden"
    echo ""
}

# --- Interaktive Auswahl ---
# listet die Module mit Nummer und Status und wertet eine Bereichseingabe aus.
select_modules_interactive() {
    local entry order id name desc status
    local index=1
    local list=""
    local answer

    for entry in "${AVAILABLE_MODULES[@]}"; do
        order=$(echo "$entry" | cut -d'|' -f1)
        id=$(echo "$entry" | cut -d'|' -f2)
        name=$(echo "$entry" | cut -d'|' -f3)
        desc=$(echo "$entry" | cut -d'|' -f4)
        printf "  %2d) %-22s %s\n" "$index" "$id" "$desc"
        list="$list$id "
        index=$((index + 1))
    done

    echo ""
    echo -e "${C_CYAN}Welche Module ausführen?${C_RESET}" >&2
    echo -e "${C_CYAN}  alle | keine | Nummern, z. B. 1-4,7 oder einzelne wie 3,9,15${C_RESET}" >&2
    echo -e "${C_CYAN}  (Enter ohne Eingabe = alle)${C_RESET}" >&2
    read -r answer || answer=""

    if [ -z "$answer" ] || [ "$answer" = "alle" ]; then
        SELECTED_MODULES=($list)
        # Sammelauswahl - hier entscheidet der INSTALL_*-Schalter.
        EXPLICIT_MODULES=()
        return 0
    fi

    if [ "$answer" = "keine" ]; then
        SELECTED_MODULES=()
        EXPLICIT_MODULES=()
        return 0
    fi

    SELECTED_MODULES=()
    EXPLICIT_MODULES=()
    local part start end m selected
    local parts=()
    IFS=',' read -ra parts <<< "$answer"
    for part in "${parts[@]}"; do
        part="$(echo "$part" | xargs)"
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            # Umgekehrter Bereich (11-3) waere sonst stillschweigend
            # wirkungslos - siehe die gleiche Pruefung im Software-Menue.
            if [ "$start" -gt "$end" ]; then
                warning "Ungültiger Bereich: $part - der Start ist größer als das Ende."
                echo "     Beispiel für 11 bis 13: 11-13"
                continue
            fi
            for ((m=start; m<=end; m++)); do
                selected=$(echo "$list" | cut -d' ' -f"$m")
                if [ -n "$selected" ]; then
                    SELECTED_MODULES+=("$selected")
                    # Vom Benutzer namentlich gewaehlt - laeuft auch ohne
                    # gesetzten INSTALL_*-Schalter.
                    EXPLICIT_MODULES+=("$selected")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            selected=$(echo "$list" | cut -d' ' -f"$part")
            if [ -n "$selected" ]; then
                SELECTED_MODULES+=("$selected")
                EXPLICIT_MODULES+=("$selected")
            else
                warning "Ungültige Nummer: $part"
            fi
        else
            warning "Ungültige Eingabe: $part"
        fi
    done
    return 0
}

# --- Software-Auswahl ---
# Die installierbare Software (Kategorie "software") als Checkliste anbieten.
# Die Voreinstellung kommt aus der aktuellen Konfiguration: ein gesetzter
# Schalter ist angehakt. Docker ist standardmaessig aktiv, weil Komodo,
# Pangolin, NetBird und das Docker-Port-Audit es voraussetzen - es bleibt
# aber abwaehlbar.
#
# Die Auswahl setzt die Schalter fuer den laufenden Durchgang. Die Software-
# Module ohne gesetzten Schalter werden beim Komplett-Setup uebersprungen.
#
# Rueckgabe: 0 = Auswahl getroffen, 1 = abgebrochen

# Die Software-Module in Ausfuehrungsreihenfolge, je eine Zeile
# "id|name|schalter".
software_module_list() {
    local entry
    for entry in "${AVAILABLE_MODULES[@]}"; do
        [ "$(echo "$entry" | cut -d'|' -f6)" = "software" ] || continue
        echo "$entry" | cut -d'|' -f2,3,7
    done
}

# Ist die SoftwareGruppe angehakt? "Angehakt" heisst: mindestens einer ihrer
# Schalter ist gesetzt.
software_switch_state() {
    local switches="$1" sw

    for sw in $switches; do
        if config_bool "$sw"; then
            return 0
        fi
    done
    return 1
}

# Setzt alle Schalter einer Softwaregruppe auf true oder false.
software_set_switches() {
    local switches="$1" value="$2" sw

    for sw in $switches; do
        printf -v "$sw" '%s' "$value"
        export "$sw"
    done
}

# Die Software-Auswahl als Menü. Nach der Auswahl stehen die Schalter in
# SOFTWARE_SELECTION (je "KEY=VALUE"), damit der Aufrufer sie in die
# Konfigurationsdatei zurückschreiben kann.
SOFTWARE_SELECTION=()

select_software() {
    local -a ids=() names=() switches=()
    local entry id name sw answer="" idx=0
    local part start end m n
    local -a nums=() parts=()

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        id="$(echo "$entry" | cut -d'|' -f1)"
        name="$(echo "$entry" | cut -d'|' -f2)"
        sw="$(echo "$entry" | cut -d'|' -f3)"
        ids+=("$id")
        names+=("$name")
        switches+=("$sw")
    done < <(software_module_list)

    if [ ${#ids[@]} -eq 0 ]; then
        debug "Keine Software-Module gefunden - Auswahl entfaellt."
        return 0
    fi

    echo ""
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e "${C_CYAN}  Software-Auswahl${C_RESET}"
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo ""
    echo "  Welche Software soll eingerichtet werden?"
    echo ""

    for ((idx = 0; idx < ${#ids[@]}; idx++)); do
        local mark=" "
        if software_switch_state "${switches[$idx]}"; then
            mark="x"
        fi
        printf "  %2d) [%s] %-34s %s\n" "$((idx + 1))" "$mark" "${names[$idx]}" "${ids[$idx]}"
    done

    echo ""
    echo -e "${C_CYAN}  Nummern zum Umschalten (z. B. 2,5,7-9) | alle | keine${C_RESET}"
    echo -e "${C_CYAN}  (Enter ohne Eingabe = Auswahl unveraendert lassen)${C_RESET}"
    printf "  > "
    read -r answer || answer=""

    # "Alle", "KEINE" und "Alle bitte" sollen genauso funktionieren wie die
    # kleingeschriebenen Varianten.
    answer="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"

    if [ -z "$answer" ]; then
        echo "  Auswahl unveraendert."
    else
        case "$answer" in
            alle)
                for ((idx = 0; idx < ${#ids[@]}; idx++)); do
                    software_set_switches "${switches[$idx]}" "true"
                done
                ;;
            keine)
                for ((idx = 0; idx < ${#ids[@]}; idx++)); do
                    software_set_switches "${switches[$idx]}" "false"
                done
                ;;
            *)
                IFS=',' read -ra parts <<< "$answer"
                for part in "${parts[@]}"; do
                    part="$(echo "$part" | xargs)"
                    [ -z "$part" ] && continue
                    if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start="${BASH_REMATCH[1]}"
                        end="${BASH_REMATCH[2]}"
                        # Ein umgekehrter Bereich (11-3) waere sonst
                        # stillschweigend wirkungslos - der Benutzer wuerde
                        # denken, er haette etwas umgeschaltet.
                        if [ "$start" -gt "$end" ]; then
                            warning "Ungültiger Bereich: $part - der Start ist größer als das Ende."
                            echo "     Beispiel für 11 bis 13: 11-13"
                            continue
                        fi
                        for ((m = start; m <= end; m++)); do
                            nums+=("$m")
                        done
                    elif [[ "$part" =~ ^[0-9]+$ ]]; then
                        nums+=("$part")
                    else
                        warning "Ungültige Eingabe: $part"
                    fi
                done

                if [ ${#nums[@]} -gt 0 ]; then
                    for n in "${nums[@]}"; do
                        if [ "$n" -lt 1 ] || [ "$n" -gt "${#ids[@]}" ]; then
                            warning "Ungültige Nummer: $n"
                            continue
                        fi
                        idx=$((n - 1))
                        # Die Gruppe schaltet komplett um: ist sie angehakt,
                        # geht sie aus, sonst kommt sie an.
                        if software_switch_state "${switches[$idx]}"; then
                            software_set_switches "${switches[$idx]}" "false"
                        else
                            software_set_switches "${switches[$idx]}" "true"
                        fi
                    done
                fi
                ;;
        esac
    fi

    # Auswahl protokollieren und anzeigen
    SOFTWARE_SELECTION=()
    echo ""
    echo "  Auswahl:"
    for ((idx = 0; idx < ${#ids[@]}; idx++)); do
        local mark=" "
        if software_switch_state "${switches[$idx]}"; then
            mark="x"
        fi
        printf "   [%s] %s\n" "$mark" "${names[$idx]}"

        for sw in ${switches[$idx]}; do
            if config_bool "$sw"; then
                SOFTWARE_SELECTION+=("${sw}=true")
            else
                SOFTWARE_SELECTION+=("${sw}=false")
            fi
        done
    done

    return 0
}

# --- Ausführung ---
load_module() {
    local module_id="$1"
    local file
    file=$(module_file_for "$module_id")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        error "Modul-Datei nicht gefunden für '$module_id'"
        return 1
    fi

    debug "Lade Modul: $file"

    # Die Auswertungsfunktionen des vorigen Moduls entfernen. Ohne das erbt
    # das nächste Modul dessen module_status/module_audit und würde mit
    # dessen Zustand bewertet - ein Modul ohne eigenes module_audit zeigte
    # sonst z. B. den Zustand des vorher geladenen Moduls.
    unset -f module_status module_audit

    # shellcheck disable=SC1090
    . "$file" || {
        error "Modul '$module_id' konnte nicht geladen werden."
        return 1
    }
    return 0
}

# Prüft, ob alle vom Modul geforderten Config-Schlüssel gesetzt sind
validate_module_requirements() {
    local module_id="$1"
    local errors=0
    local key value

    # Wichtig: Die Längenprüfung muss VOR der Schleife stehen. Bei leerem
    # Array liefert "${arr[@]:-}" ein leeres Wort, was zu "invalid indirect
    # expansion" führen und die Shell abbrechen würde.
    [ ${#MODULE_REQUIRED_KEYS[@]} -gt 0 ] || return 0

    for key in "${MODULE_REQUIRED_KEYS[@]}"; do
        value="${!key:-}"
        if [ -z "$value" ]; then
            error "Modul '$module_id' benötigt die Config-Variable $key"
            errors=$((errors + 1))
        fi
    done

    return $errors
}

run_module() {
    local module_id="$1"
    local name desc start_time end_time duration rc

    name=$(module_name_for "$module_id")
    desc=$(module_desc_for "$module_id")

    CURRENT_MODULE="$module_id"
    echo ""
    echo "============================================================"
    info "Modul: $name ($module_id)"
    echo "  $desc"
    echo "------------------------------------------------------------"

    load_module "$module_id" || return 2
    if ! validate_module_requirements "$module_id"; then
        skip "Modul '$module_id' übersprungen (fehlende Konfiguration)"
        MODULE_RESULTS+=("${module_id}|skip|0")
        return 0
    fi

    start_time=$(date +%s)
    # "|| rc=$?" haelt den Aufruf in einem Bedingungskontext - dadurch
    # beendet sich das Setup auch dann nicht, wenn set -e gesetzt waere.
    rc=0
    module_main || rc=$?
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    case $rc in
        0)
            success "Modul '$module_id' abgeschlossen (${duration}s)"
            MODULE_RESULTS+=("${module_id}|ok|${duration}")
            ;;
        1)
            skip "Modul '$module_id' nicht anwendbar (${duration}s)"
            MODULE_RESULTS+=("${module_id}|skip|${duration}")
            ;;
        *)
            error "Modul '$module_id' fehlgeschlagen (Exit $rc, ${duration}s)"
            MODULE_RESULTS+=("${module_id}|fehler|${duration}")
            return 2
            ;;
    esac

    return 0
}

# --- Status ---
show_module_status() {
    local module_id
    info "Modulstatus:"

    for module_id in "${SELECTED_MODULES[@]}"; do
        local name status="nicht geprüft"
        name=$(module_name_for "$module_id")

        if load_module "$module_id" 2>/dev/null; then
            if declare -f module_status >/dev/null 2>&1; then
                # head -n 1 erzwingt EINE Zeile: Module dürfen intern gerne
                # mehrfach ausgeben - die Statustabelle bleibt dadurch intakt.
                status=$( { module_status 2>/dev/null; } | head -n 1 )
                [ -z "$status" ] && status="keine Angabe"
            else
                status="—"
            fi
        else
            status="Ladefehler"
        fi

        printf "  %-22s %-34s %s\n" "$module_id" "$name" "$status"
    done
}

# --- Zusammenfassung ---
show_run_summary() {
    echo ""
    echo "============================================================"
    info "Zusammenfassung"
    echo "------------------------------------------------------------"

    local entry id state duration
    local ok=0 skipped=0 failed=0

    [ ${#MODULE_RESULTS[@]} -gt 0 ] || return 0

    for entry in "${MODULE_RESULTS[@]}"; do
        id=$(echo "$entry" | cut -d'|' -f1)
        state=$(echo "$entry" | cut -d'|' -f2)
        duration=$(echo "$entry" | cut -d'|' -f3)

        case $state in
            ok)     printf "  %-24s %-10s %ss\n" "$id" "OK" "$duration"; ok=$((ok + 1)) ;;
            skip)   printf "  %-24s %-10s\n" "$id" "ÜBERSPRUNGEN"; skipped=$((skipped + 1)) ;;
            fehler) printf "  %-24s %-10s %ss\n" "$id" "FEHLER" "$duration"; failed=$((failed + 1)) ;;
        esac
    done

    echo "------------------------------------------------------------"
    echo "  Erfolgreich: $ok | Übersprungen: $skipped | Fehler: $failed"
    echo "  Log: $LOGFILE"
    echo "============================================================"
}

# --- Audit ---
# Beantwortet die Frage: "Was ist auf diesem Server bereits eingerichtet?"
# Jedes Modul liefert über module_audit() eine Zeile "IST|SOLL" oder
# "IST|SOLL|<Abweichung>". Der Aufrufer wertet das aus.
#
# Erwartetes Format aus module_audit():
#   ok|ZIEL        - Zielzustand erreicht
#   abweichung|IST|SOLL - Zielzustand nicht erreicht
#   info|WAS|WARUM - Zustand nicht bewertbar
show_audit() {
    local module_id name finding state target detail
    local ok=0 abweichung=0 info=0

    echo ""
    echo "============================================================"
    info "Audit: Ist-Zustand gegen Ziel aus der Konfiguration"
    echo "------------------------------------------------------------"

    for module_id in "${SELECTED_MODULES[@]}"; do
        name=$(module_name_for "$module_id")

        if ! load_module "$module_id" 2>/dev/null; then
            printf "  %-22s %-34s %s\n" "$module_id" "$name" "Ladefehler"
            info=$((info + 1))
            continue
        fi

        if ! declare -f module_audit >/dev/null 2>&1; then
            printf "  %-22s %-34s %s\n" "$module_id" "$name" "—"
            info=$((info + 1))
            continue
        fi

        finding=$(module_audit 2>/dev/null | head -n 1)
        state=$(echo "$finding" | cut -d'|' -f1)
        target=$(echo "$finding" | cut -d'|' -f2)
        detail=$(echo "$finding" | cut -d'|' -f3-)

        [ -z "$target" ] && target="—"

        case "$state" in
            ok)
                printf "  %-22s %-34s %s\n" "$module_id" "$name" "$target"
                ok=$((ok + 1))
                ;;
            abweichung)
                printf "  %-22s %-34s %s\n" "$module_id" "$name" "ABWEICHUNG"
                if [ -n "$detail" ]; then
                    printf "  %-22s %-34s   ist:  %s\n" "" "" "$target"
                    printf "  %-22s %-34s   soll: %s\n" "" "" "$detail"
                else
                    printf "  %-22s %-34s   ist:  %s\n" "" "" "$target"
                fi
                abweichung=$((abweichung + 1))
                ;;
            info)
                printf "  %-22s %-34s %s\n" "$module_id" "$name" "nicht prüfbar: $target"
                [ -n "$detail" ] && printf "  %-22s %-34s   %s\n" "" "" "$detail"
                info=$((info + 1))
                ;;
            *)
                printf "  %-22s %-34s %s\n" "$module_id" "$name" "unbekannter Zustand"
                info=$((info + 1))
                ;;
        esac
    done

    echo "------------------------------------------------------------"
    echo "  Im Zielzustand: $ok | Abweichungen: $abweichung | Nicht prüfbar: $info"
    echo "============================================================"

    [ "$abweichung" -gt 0 ] && return 1
    return 0
}