#!/bin/bash
# ==============================================================================
# setupv4/lib/tui.sh - Terminal-UI für das Setup
# ==============================================================================
# Vollbild-Oberfläche für das Setup: eine Checkliste für die Software und ein
# Live-Dashboard während der Ausführung (Modulfortschritt + Logfenster).
#
# Bewusst OHNE externe Abhängigkeit: kein ncurses, kein dialog, kein Python.
# Die Steuerzeichen werden direkt gesendet - das funktioniert über SSH in
# MobaXterm, PuTTY, tmux und jedem xterm-kompatiblen Terminal.
#
# Aufbau des Ablaufs:
#   1. Auswahl    Vollbild-Checkliste (Pfeiltasten, Leertaste, Enter, q)
#   2. Ausführung Der Elternprozess startet das Setup als KINDPROZESS
#                 (stdout+stderr gehen in eine Logdatei) und rendert das
#                 Dashboard. Das Kind liest seine Rückfragen direkt vom
#                 Terminal - es gibt nur einen Tastatur-Leser, deshalb
#                 entsteht kein Konflikt.
#   3. Abschluss  Ergebniskarte mit dem Ergebnis je Modul.
#
# Ohne TTY (cron, Ansible, CI) wird dieses Modul nie verwendet - dort läuft
# der klassische Textpfad.
# ==============================================================================

TUI_LINES=24
TUI_COLS=80
TUI_KEY=""
TUI_CHILD_PID=""
TUI_ENTERED=0

# Die Pfade vom Elternprozess uebernehmen. Das Kindprozess erbt sie aus der
# Umgebung - sie duerfen hier NICHT auf leer gesetzt werden, sonst verliert
# das Kind seine Fortschrittsdatei, bevor es die Module startet.
TUI_LOG="${TUI_LOG:-}"
TUI_PROGRESS="${TUI_PROGRESS:-}"

# UTF-8-Zeichen für den Fortschrittsbalken. Auf einer Nicht-UTF-8-Konsole
# werden ASCII-Zeichen genommen - sonst wird der Balken unlesbar.
TUI_BAR_FULL="▓"
TUI_BAR_EMPTY="░"
TUI_MARK_OK="✓"
TUI_MARK_RUN="▸"
TUI_MARK_WAIT="○"
TUI_MARK_SKIP="−"
TUI_MARK_ERR="✗"

# --- Umgebung ---
tui_init_env() {
    local charmap
    charmap="$(locale charmap 2>/dev/null)"

    case "$charmap" in
        UTF-8|utf8|utf-8)
            : # Unicode-Zeichen sind erlaubt
            ;;
        *)
            TUI_BAR_FULL="#"
            TUI_BAR_EMPTY="-"
            TUI_MARK_OK="+"
            TUI_MARK_RUN=">"
            TUI_MARK_WAIT="."
            TUI_MARK_SKIP="-"
            TUI_MARK_ERR="x"
            ;;
    esac

    [ -n "${C_RESET:-}" ] || C_RESET='\033[0m'
    [ -n "${C_RED:-}" ] || C_RED='\033[31m'
    [ -n "${C_GREEN:-}" ] || C_GREEN='\033[32m'
    [ -n "${C_YELLOW:-}" ] || C_YELLOW='\033[33m'
    [ -n "${C_BLUE:-}" ] || C_BLUE='\033[34m'
    [ -n "${C_MAGENTA:-}" ] || C_MAGENTA='\033[35m'
    [ -n "${C_CYAN:-}" ] || C_CYAN='\033[36m'
    [ -n "${C_WHITE:-}" ] || C_WHITE='\033[37m'
    [ -n "${C_BOLD:-}" ] || C_BOLD='\033[1m'
    [ -n "${C_DIM:-}" ] || C_DIM='\033[2m'
}

# Kann die TUI überhaupt laufen? Ein Terminal auf beiden Seiten ist Pflicht.
tui_available() {
    [ -t 0 ] || return 1
    [ -t 1 ] || return 1
    [ -z "${TERM:-}" ] && return 1
    case "${TERM:-}" in
        dumb|unknown) return 1 ;;
    esac
    return 0
}

# Terminalgröße ermitteln. Ohne tput fallen 80x24 an.
tui_size() {
    local lines cols

    lines="$(tput lines 2>/dev/null)"
    cols="$(tput cols 2>/dev/null)"

    case "$lines" in
        ''|*[!0-9]*) lines=24 ;;
    esac
    case "$cols" in
        ''|*[!0-9]*) cols=80 ;;
    esac

    [ "$lines" -lt 12 ] && lines=12
    [ "$cols" -lt 60 ] && cols=60

    TUI_LINES="$lines"
    TUI_COLS="$cols"
}

# --- Bildschirmsteuerung ---
tui_alt_on() {
    printf '\033[?1049h'   # alternativer Bildschirmpuffer
    printf '\033[?25l'     # Cursor ausblenden
    printf '\033[2J\033[H'  # Bildschirm leeren, Cursor nach oben links
    TUI_ENTERED=1
}

tui_alt_off() {
    [ "$TUI_ENTERED" = "1" ] || return 0
    printf '\033[?25h'     # Cursor wieder einblenden
    printf '\033[?1049l'   # zurueck in den normalen Bildschirmpuffer
    TUI_ENTERED=0
}

# Cursor an eine Position setzen (Zeile, Spalte - beide 1-basiert)
tui_at() {
    printf '\033[%d;%dH' "$1" "$2"
}

tui_clear_line() {
    printf '\033[2K'
}

# Eine Zeile an der aktuellen Cursorposition schreiben (ohne Zeilenumbruch)
tui_put() {
    printf '%s' "$1"
}

# --- Tastatur ---
# Liest eine Taste. Pfeiltasten werden als UP/DOWN/LEFT/RIGHT geliefert,
# Enter als leerer String, Esc als ESC.
tui_read_key() {
    local key="" rest=""

    if ! IFS= read -rsn1 -t "${TUI_KEY_TIMEOUT:-0.25}" key 2>/dev/null; then
        TUI_KEY=""
        return 1
    fi

    if [ "$key" = $'\033' ]; then
        # Escape-Sequenz: die zwei Folgezeichen lesen.
        IFS= read -rsn1 -t 0.05 rest 2>/dev/null || rest=""
        if [ "$rest" = "[" ]; then
            IFS= read -rsn1 -t 0.05 rest 2>/dev/null || rest=""
            case "$rest" in
                A) TUI_KEY="UP" ;;
                B) TUI_KEY="DOWN" ;;
                C) TUI_KEY="RIGHT" ;;
                D) TUI_KEY="LEFT" ;;
                *) TUI_KEY="ESC" ;;
            esac
            return 0
        fi
        TUI_KEY="ESC"
        return 0
    fi

    TUI_KEY="$key"
    return 0
}

# --- Rahmen ---
tui_rule() {
    local width="$1" line="" i

    for ((i = 0; i < width; i++)); do
        line+="─"
    done
    printf '%s' "$line"
}

# Eine Zeile innerhalb eines Rahmens zeichnen (Text links, Rest Füllung).
tui_box_line() {
    local text="$1" width="$2" fill_len text_len

    text_len="${#text}"
    fill_len=$((width - text_len - 3))
    [ "$fill_len" -lt 0 ] && fill_len=0

    printf '│ %s' "$text"
    local i
    for ((i = 0; i < fill_len; i++)); do
        printf ' '
    done
    printf '│'
}

# --- Software-Checkliste (Phase 1) ---
# Schreibt die Auswahl direkt in die Schalter-Variablen. Rückgabe:
#   0 - Auswahl bestätigt
#   1 - abgebrochen
tui_select_software() {
    local -a ids=() names=() switches=()
    local entry id name sw cursor=0 count=0
    local row line hint selected=0
    local base_count=0 m

    # Die Software-Module einsammeln
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        id="$(echo "$entry" | cut -d'|' -f1)"
        name="$(echo "$entry" | cut -d'|' -f2)"
        sw="$(echo "$entry" | cut -d'|' -f3)"
        ids+=("$id")
        names+=("$name")
        switches+=("$sw")
    done < <(software_module_list)

    count=${#ids[@]}
    if [ "$count" -eq 0 ]; then
        return 0
    fi

    # Wie viele Module laufen immer mit (ohne Schalter)?
    for m in "${AVAILABLE_MODULES[@]}"; do
        [ "$(echo "$m" | cut -d'|' -f6)" = "software" ] || base_count=$((base_count + 1))
    done

    tui_size
    tui_alt_on

    while true; do
        # --- Bild zeichnen ---
        tui_at 1 1
        printf '%s%s%s' "$C_CYAN" "╔$(tui_rule $((TUI_COLS - 2)))╗" "$C_RESET"
        tui_at 2 1
        tui_box_line "$(printf '%ssetupv4 · Software-Auswahl%s   Host: %s   %s' \
            "$C_BOLD$C_WHITE" "$C_RESET" "${HOSTNAME_SHORT:-$(hostname -s 2>/dev/null)}" "$(date +%H:%M)")" "$((TUI_COLS - 2))"
        tui_at 3 1
        printf '%s%s%s' "$C_CYAN" "╚$(tui_rule $((TUI_COLS - 2)))╝" "$C_RESET"

        tui_at 4 1
        printf '  Welche Software soll eingerichtet werden?  %s(Enter = bestätigen)%s' "$C_DIM" "$C_RESET"

        row=6
        for ((m = 0; m < count; m++)); do
            [ "$row" -ge $((TUI_LINES - 3)) ] && break
            tui_at "$row" 1
            printf ' '

            # Cursor-Markierung
            if [ "$m" = "$cursor" ]; then
                printf '%s>%s' "$C_CYAN" "$C_RESET"
            else
                printf ' '
            fi

            printf ' %2d) ' "$((m + 1))"

            if software_switch_state "${switches[$m]}"; then
                printf '%s[%s]%s' "$C_GREEN" "$TUI_MARK_OK" "$C_RESET"
            else
                printf '%s[%s]%s' "$C_DIM" " " "$C_RESET"
            fi

            printf ' %-34s %s%s%s' "${names[$m]}" "$C_DIM" "${ids[$m]}" "$C_RESET"
            row=$((row + 1))
        done

        # Statuszeile
        selected=0
        for ((m = 0; m < count; m++)); do
            software_switch_state "${switches[$m]}" && selected=$((selected + 1))
        done

        tui_at $((TUI_LINES - 2)) 1
        tui_clear_line
        hint="$(printf '%d von %d Paketen ausgewählt%s  ·  %d Systemmodule laufen immer mit' \
            "$selected" "$count" "$C_RESET" "$base_count")"
        printf '  %s' "$hint"

        tui_at "$TUI_LINES" 1
        tui_clear_line
        printf '  %s↑↓ bewegen · Leertaste umschalten · Enter bestätigen · q abbrechen%s' \
            "$C_DIM" "$C_RESET"

        # --- Eingabe ---
        tui_read_key || continue

        case "$TUI_KEY" in
            UP)
                cursor=$((cursor - 1))
                [ "$cursor" -lt 0 ] && cursor=$((count - 1))
                ;;
            DOWN)
                cursor=$((cursor + 1))
                [ "$cursor" -ge "$count" ] && cursor=0
                ;;
            " ")
                # Umschalten: ist die Gruppe an, geht sie aus, sonst an.
                if software_switch_state "${switches[$cursor]}"; then
                    software_set_switches "${switches[$cursor]}" "false"
                else
                    software_set_switches "${switches[$cursor]}" "true"
                fi
                ;;
            "")
                # Enter: bestätigen.
                tui_alt_off
                return 0
                ;;
            q|Q)
                tui_alt_off
                return 1
                ;;
            ESC)
                tui_alt_off
                return 1
                ;;
        esac
    done
}

# --- Fortschrittsbalken ---
tui_progress_bar() {
    local done="$1" total="$2" width="$3"
    local filled empty i

    [ "$total" -gt 0 ] || total=1
    filled=$(( done * width / total ))
    [ "$filled" -gt "$width" ] && filled="$width"
    [ "$filled" -lt 0 ] && filled=0
    empty=$(( width - filled ))

    for ((i = 0; i < filled; i++)); do
        printf '%s' "$TUI_BAR_FULL"
    done
    for ((i = 0; i < empty; i++)); do
        printf '%s' "$TUI_BAR_EMPTY"
    done
}

# --- Dashboard (Phase 2) ---
# Startet das Setup als Kindprozess und rendert währenddessen das Dashboard.
tui_run_child() {
    local -a child_args=()
    local arg
    local done=0 total=0
    local mod_rows log_lines fixed row
    local -a mod_ids=() mod_names=() mod_status=() mod_time=()
    local entry m id name
    local started elapsed
    local plan_line plan pid
    local -a plan_ids=()

    # Die Argumente ohne --tui an das Kind weitergeben.
    for arg in "$@"; do
        [ "$arg" = "--tui" ] && continue
        child_args+=("$arg")
    done

    TUI_LOG="$SETUP_DIR/logs/tui-stream.log"
    TUI_PROGRESS="$SETUP_DIR/logs/tui-progress.log"
    mkdir -p "$SETUP_DIR/logs" 2>/dev/null || true
    : > "$TUI_LOG" 2>/dev/null
    : > "$TUI_PROGRESS" 2>/dev/null

    # Das Kind erbt die Umgebung - damit stehen die Schalter der Auswahl
    # aus Phase 1 zur Verfuegung.
    export TUI_LOG TUI_PROGRESS
    export SETUPV4_TUI_CHILD=1

    bash "$SETUP_HOME/setup.sh" "${child_args[@]}" > "$TUI_LOG" 2>&1 &
    TUI_CHILD_PID=$!

    tui_size
    tui_alt_on

    started="$(date +%s)"

    while kill -0 "$TUI_CHILD_PID" 2>/dev/null; do
        # --- Modulplan des Kindes uebernehmen ---
        # Das Kind entscheidet, welche Module laufen - der Elternprozess
        # kennt diese Liste erst, wenn sie im Plan steht.
        if [ ${#mod_ids[@]} -eq 0 ] && [ -f "$TUI_PROGRESS" ]; then
            plan_line="$(grep -m1 '^plan|' "$TUI_PROGRESS" 2>/dev/null)"
            if [ -n "$plan_line" ]; then
                plan="${plan_line#plan|}"
                IFS='|' read -ra plan_ids <<< "$plan"
                for pid in "${plan_ids[@]}"; do
                    [ -z "$pid" ] && continue
                    mod_ids+=("$pid")
                    mod_names+=("$(module_name_for "$pid")")
                    mod_status+=("wait")
                    mod_time+=("")
                done
            fi
        fi

        # --- Fortschritt aus der Fortschrittsdatei lesen ---
        if [ -f "$TUI_PROGRESS" ]; then
            while IFS='|' read -r event mid mstatus mtime; do
                [ -z "$event" ] && continue
                [ "$event" = "plan" ] && continue
                for ((m = 0; m < ${#mod_ids[@]}; m++)); do
                    [ "${mod_ids[$m]}" = "$mid" ] || continue
                    if [ "$event" = "start" ]; then
                        mod_status[$m]="run"
                        mod_time[$m]="0s"
                    else
                        mod_status[$m]="$mstatus"
                        mod_time[$m]="${mtime}s"
                    fi
                    break
                done
            done < <(grep -v '^plan|' "$TUI_PROGRESS" 2>/dev/null)
        fi

        # --- Fertige Module zaehlen ---
        done=0
        for ((m = 0; m < ${#mod_ids[@]}; m++)); do
            case "${mod_status[$m]}" in
                ok|skip|fehler) done=$((done + 1)) ;;
            esac
        done
        total=${#mod_ids[@]}

        # --- Anordnung berechnen ---
        fixed=10
        mod_rows=$(( TUI_LINES - fixed - 6 ))
        [ "$mod_rows" -gt 10 ] && mod_rows=10
        [ "$mod_rows" -lt 3 ] && mod_rows=3
        log_lines=$(( TUI_LINES - fixed - mod_rows ))
        [ "$log_lines" -lt 4 ] && log_lines=4

        # --- Kopf ---
        tui_at 1 1
        printf '%s%s%s' "$C_CYAN" "╔$(tui_rule $((TUI_COLS - 2)))╗" "$C_RESET"
        tui_at 2 1
        elapsed=$(( $(date +%s) - started ))
        tui_box_line "$(printf '%ssetupv4 · Ausführung%s   %s   %s   %s' \
            "$C_BOLD$C_WHITE" "$C_RESET" "${HOSTNAME_SHORT:-$(hostname -s 2>/dev/null)}" \
            "$(date +%H:%M:%S)" "$(printf '%dm%02ds' $((elapsed / 60)) $((elapsed % 60)))")" \
            "$((TUI_COLS - 2))"
        tui_at 3 1
        printf '%s%s%s' "$C_CYAN" "╚$(tui_rule $((TUI_COLS - 2)))╝" "$C_RESET"

        # --- Fortschrittsbalken ---
        tui_at 5 1
        tui_clear_line
        printf '  %s' "$C_CYAN"
        tui_progress_bar "$done" "$total" $((TUI_COLS - 26))
        printf '%s %d/%d Module' "$C_RESET" "$done" "$total"

        # --- Modultabelle ---
        row=7
        tui_at "$row" 1
        tui_clear_line
        printf '  %s%-20s %-30s %-8s %6s%s' "$C_DIM" "MODUL" "NAME" "STATUS" "ZEIT" "$C_RESET"
        row=$((row + 1))

        # Nur die letzten mod_rows Module zeigen - der aktuelle ist unten.
        local first=$(( ${#mod_ids[@]} - mod_rows ))
        [ "$first" -lt 0 ] && first=0

        if [ ${#mod_ids[@]} -eq 0 ]; then
            # Der Plan des Kindes steht noch nicht - das Kind startet gerade.
            tui_at "$row" 1
            tui_clear_line
            printf '  %s%s Startet ...%s' "$C_DIM" "$TUI_MARK_WAIT" "$C_RESET"
            row=$((row + 1))
        fi

        for ((m = first; m < ${#mod_ids[@]}; m++)); do
            tui_at "$row" 1
            tui_clear_line
            case "${mod_status[$m]}" in
                ok)   printf '  %s%s%s %-20s %-30s %s%-8s%s %6s' \
                          "$C_GREEN" "$TUI_MARK_OK" "$C_RESET" "${mod_ids[$m]}" "${mod_names[$m]}" \
                          "$C_GREEN" "OK" "$C_RESET" "${mod_time[$m]}" ;;
                skip) printf '  %s%s%s %-20s %-30s %s%-8s%s %6s' \
                          "$C_DIM" "$TUI_MARK_SKIP" "$C_RESET" "${mod_ids[$m]}" "${mod_names[$m]}" \
                          "$C_DIM" "SKIP" "$C_RESET" "${mod_time[$m]}" ;;
                fehler) printf '  %s%s%s %-20s %-30s %s%-8s%s %6s' \
                          "$C_RED" "$TUI_MARK_ERR" "$C_RESET" "${mod_ids[$m]}" "${mod_names[$m]}" \
                          "$C_RED" "FEHLER" "$C_RESET" "${mod_time[$m]}" ;;
                run)  printf '  %s%s%s %-20s %-30s %s%-8s%s %6s' \
                          "$C_YELLOW" "$TUI_MARK_RUN" "$C_RESET" "${mod_ids[$m]}" "${mod_names[$m]}" \
                          "$C_YELLOW" "läuft" "$C_RESET" "${mod_time[$m]}" ;;
                *)    printf '  %s%s%s %-20s %-30s %s%-8s%s %6s' \
                          "$C_DIM" "$TUI_MARK_WAIT" "$C_RESET" "${mod_ids[$m]}" "${mod_names[$m]}" \
                          "$C_DIM" "wartet" "$C_RESET" "" ;;
            esac
            row=$((row + 1))
        done

        # --- Logfenster ---
        tui_at "$row" 1
        tui_clear_line
        printf '  %s── Log %s' "$C_DIM" "$C_RESET"

        local logline
        local lrow=$((row + 1))
        while IFS= read -r logline; do
            [ "$lrow" -ge $((TUI_LINES - 1)) ] && break
            tui_at "$lrow" 1
            tui_clear_line
            # Sehr lange Zeilen kuerzen, damit sie das Layout nicht sprengen.
            printf '  %s' "${logline:0:$((TUI_COLS - 4))}"
            lrow=$((lrow + 1))
        done < <(tail -n "$log_lines" "$TUI_LOG" 2>/dev/null)

        # Restliche Logzeilen leeren (das Log kann kuerzer werden)
        while [ "$lrow" -lt $((TUI_LINES - 1)) ]; do
            tui_at "$lrow" 1
            tui_clear_line
            lrow=$((lrow + 1))
        done

        # --- Fusszeile ---
        tui_at "$TUI_LINES" 1
        tui_clear_line
        printf '  %sEs laeuft - die Rueckfragen des Setups stehen unten im Log.%s' \
            "$C_DIM" "$C_RESET"

        # Der Cursor sitzt am Ende des Logfensters: eine getippte Antwort
        # erscheint dort und wird beim naechsten Zeichnen ueberschrieben.
        tui_at $((TUI_LINES - 1)) 1

        sleep 0.4
    done

    wait "$TUI_CHILD_PID" 2>/dev/null
    local rc=$?
    TUI_CHILD_PID=""

    # Den Fortschritt ein letztes Mal einlesen, damit die Abschlusskarte
    # vollstaendig ist.
    if [ -f "$TUI_PROGRESS" ]; then
        while IFS='|' read -r event mid mstatus mtime; do
            [ -z "$event" ] && continue
            for ((m = 0; m < ${#mod_ids[@]}; m++)); do
                [ "${mod_ids[$m]}" = "$mid" ] || continue
                mod_status[$m]="$mstatus"
                mod_time[$m]="${mtime}s"
                break
            done
        done < "$TUI_PROGRESS"
    fi

    tui_alt_off

    # Abschlusskarte
    printf '\n'
    printf '%s' "$C_CYAN"
    printf '╔%s╗\n' "$(tui_rule $((TUI_COLS - 2)))"
    printf '%s' "$C_RESET"
    printf '%s' "$C_CYAN"
    tui_box_line "$(printf '%ssetupv4 · Ergebnis%s' "$C_BOLD$C_WHITE" "$C_RESET")" "$((TUI_COLS - 2))"
    printf '%s' "$C_RESET"
    printf '%s' "$C_CYAN"
    printf '╚%s╝\n' "$(tui_rule $((TUI_COLS - 2)))"
    printf '%s' "$C_RESET"

    local ok=0 skip=0 err=0
    for ((m = 0; m < ${#mod_ids[@]}; m++)); do
        case "${mod_status[$m]}" in
            ok) ok=$((ok + 1)) ;;
            skip) skip=$((skip + 1)) ;;
            fehler) err=$((err + 1)) ;;
        esac
    done

    printf '\n  %s%sOK%s %d   %s%sÜBERSPRUNGEN%s %d   %s%sFEHLER%s %d\n' \
        "$C_GREEN" "$TUI_MARK_OK" "$C_RESET" "$ok" \
        "$C_DIM" "$TUI_MARK_SKIP" "$C_RESET" "$skip" \
        "$C_RED" "$TUI_MARK_ERR" "$C_RESET" "$err"

    if [ "$err" -gt 0 ]; then
        printf '\n  %sFehlgeschlagene Module:%s\n' "$C_RED" "$C_RESET"
        for ((m = 0; m < ${#mod_ids[@]}; m++)); do
            [ "${mod_status[$m]}" = "fehler" ] || continue
            printf '    %s%s%s  %s\n' "$C_RED" "$TUI_MARK_ERR" "$C_RESET" "${mod_ids[$m]}"
        done
    fi

    printf '\n  Log: %s\n' "$LOGFILE"
    printf '  %sNeustart prüfen: sudo bash setup.sh --check-reboot%s\n\n' "$C_DIM" "$C_RESET"

    return $rc
}

# --- Gesamtablauf (TUI) ---
tui_main() {
    local rc=0

    tui_init_env

    if ! tui_available; then
        warning "Kein Terminal für die Oberfläche - der klassische Textpfad läuft."
        return 1
    fi

    # Phase 1: Software auswählen
    if ! tui_select_software; then
        skip "Abgebrochen - es wurde nichts geändert."
        return 0
    fi

    # Phase 2: Setup als Kindprozess starten und das Dashboard zeigen
    tui_run_child "$@"
    rc=$?

    return $rc
}
