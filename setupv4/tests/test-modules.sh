#!/bin/bash
# ==============================================================================
# setupv4/tests/test-modules.sh - Modulkonventionen und Modulverhalten
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

section "1. Moduldateien und Metadaten"
module_count=0
missing_meta=0
id_mismatch=0
no_main=0
declare -a seen_ids=()

while IFS= read -r file; do
    rel=$(basename "$file")
    module_count=$((module_count + 1))

    # Metadaten in einem Subshell auslesen - so bleibt die Test-Shell sauber
    meta=$(bash -c '
        # shellcheck disable=SC1090
        source "$1" || exit 1
        printf "%s|%s|%s|%s\n" \
            "${MODULE_ID:-}" "${MODULE_NAME:-}" \
            "${MODULE_DESC:-}" "${MODULE_ORDER:-}"
    ' _ "$file" 2>/dev/null)

    if [ -z "$meta" ]; then
        fail "Modul nicht ladbar: $rel"
        missing_meta=1
        continue
    fi

    mod_id="${meta%%|*}"
    mod_name=$(echo "$meta" | cut -d'|' -f2)
    mod_desc=$(echo "$meta" | cut -d'|' -f3)
    mod_order=$(echo "$meta" | cut -d'|' -f4)

    [ -z "$mod_id" ]  && { fail "MODULE_ID fehlt: $rel"; missing_meta=1; }
    [ -z "$mod_name" ] && { fail "MODULE_NAME fehlt: $rel"; missing_meta=1; }
    [ -z "$mod_desc" ] && { fail "MODULE_DESC fehlt: $rel"; missing_meta=1; }
    [ -z "$mod_order" ] && { fail "MODULE_ORDER fehlt: $rel"; missing_meta=1; }

    # Dateiname (ohne Ordnernummer) muss zur MODULE_ID passen
    expect_id="${rel#*-}"; expect_id="${expect_id%.sh}"
    if [ "$expect_id" != "$mod_id" ]; then
        fail "Dateiname und MODULE_ID stimmen nicht überein: $rel -> '$mod_id'"
        id_mismatch=1
    fi

    seen_ids+=("$mod_id")

    if ! grep -qE '^[[:space:]]*module_main[[:space:]]*\(\)' "$file"; then
        fail "module_main fehlt: $rel"
        no_main=1
    fi
done < <(find "$SANDBOX_DIR/modules" -name '*.sh' -type f | sort)

if [ "$module_count" -ge 20 ]; then
    pass "$module_count Module gefunden"
else
    fail "Nur $module_count Module gefunden"
fi
[ $missing_meta -eq 0 ] && pass "Alle Module haben vollständige Metadaten"
[ $id_mismatch -eq 0 ] && pass "Dateiname und MODULE_ID stimmen überall überein"
[ $no_main -eq 0 ] && pass "Alle Module definieren module_main()"

section "2. Keine doppelten Modul-IDs"
dupes=$(printf '%s\n' "${seen_ids[@]}" | sort | uniq -d)
if [ -z "$dupes" ]; then
    pass "Keine doppelten MODULE_IDs"
else
    fail "Doppelte MODULE_IDs: $(echo $dupes)"
fi

section "3. Sortierung nach MODULE_ORDER"
run_setup --list
prev=0
order_ok=1
while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    case "$id" in ''|ID) continue ;; esac
    file=$(find "$SANDBOX_DIR/modules" -name "*-${id}.sh" -type f | head -n1)
    [ -z "$file" ] && continue
    num="${file##*/}"; num="${num%%-*}"
    if [ "$num" -lt "$prev" ]; then
        fail "Reihenfolge stimmt nicht: '$id' ($num) nach $prev"
        order_ok=0
    fi
    prev=$num
done <<< "$(echo "$OUTPUT" | tail -n +3)"
[ $order_ok -eq 1 ] && pass "Module sind aufsteigend nach Ordnernummer sortiert"

section "4. Alle Module im Dry-Run ausführbar"
ALL_IDS=$(printf '%s\n' "${seen_ids[@]}" | tr '\n' ' ')
cat > "$SANDBOX_DIR/all.conf" << EOF
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SSH_PORT=2222
MODULES=($ALL_IDS)
EOF
run_setup --config all.conf --non-interactive --dry-run
assert_exit 0 "$EXIT_CODE" "Gesamtlauf über alle Module endet mit Exit 0"
assert_not_contains "$OUTPUT" "FEHLER" "Kein Modul meldet im Dry-Run einen Fehler"
assert_contains "$OUTPUT" "Erfolgreich:" "Zusammenfassung wird ausgegeben"

section "5. module_status liefert genau eine Zeile"
# Regression: mehrzeilige Ausgaben zerreißen die Statustabelle.
# Geprüft wird deshalb nicht die Wortzahl (Statustexte enthalten selbst
# Leerzeichen), sondern dass jede Zeile mit einer bekannten Modul-ID beginnt.
status_out=$(cd "$SANDBOX_DIR" && SETUP_HOME="$SANDBOX_HOME" \
    bash ./setup.sh --config all.conf --status --non-interactive 2>/dev/null)
bad_lines=0
seen_rows=0
while IFS= read -r line; do
    # Nur echte Tabellenzeilen betrachten: sie beginnen mit zwei Leerzeichen
    # gefolgt von der Modul-ID. Kopfzeilen wie "[INFO] Modulstatus:" nicht.
    [[ "$line" =~ ^[[:space:]]{2}[a-z0-9-]+[[:space:]] ]] || continue
    row_id=$(echo "$line" | awk '{print $1}')
    if ! printf '%s\n' "${seen_ids[@]}" | grep -qx "$row_id"; then
        fail "Ungültige Statuszeile (unbekannte ID): '$line'"
        bad_lines=$((bad_lines + 1))
        continue
    fi
    seen_rows=$((seen_rows + 1))
done <<< "$status_out"

if [ "$bad_lines" -eq 0 ]; then
    pass "Statustabelle enthält $seen_rows gültige Zeilen"
else
    fail "$bad_lines Zeilen mit unbekannter Modul-ID"
fi

if [ "$seen_rows" -eq "${#seen_ids[@]}" ]; then
    pass "Jedes Modul hat genau eine Statuszeile"
else
    fail "Erwartet ${#seen_ids[@]} Statuszeilen, gefunden: $seen_rows"
fi

section "6. Modulliste in setup.conf.example ist gültig"
EXAMPLE="$SANDBOX_HOME/config/setup.conf.example"
if [ ! -f "$EXAMPLE" ]; then
    # Vorhandene Vorlage aus dem Repository verwenden
    EXAMPLE="$SANDBOX_DIR/config/setup.conf.example"
fi

if [ -f "$EXAMPLE" ]; then
    bad=0
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if ! printf '%s\n' "${seen_ids[@]}" | grep -qx "$id"; then
            fail "Unbekanntes Modul in setup.conf.example: '$id'"
            bad=1
        fi
    done < <(sed -n '/^MODULES=(/,/^)/p' "$EXAMPLE" | grep -oE '^[[:space:]]+[a-z0-9-]+' | tr -d ' ')
    [ $bad -eq 0 ] && pass "Alle Module aus der Beispielconfig existieren"

    missing_mod=0
    for id in "${seen_ids[@]}"; do
        if ! sed -n '/^MODULES=(/,/^)/p' "$EXAMPLE" | grep -qE "^[[:space:]]+$id\$"; then
            fail "Modul fehlt in der Beispielconfig: '$id'"
            missing_mod=1
        fi
    done
    [ $missing_mod -eq 0 ] && pass "Die Beispielconfig listet jedes Modul"
else
    fail "config/setup.conf.example fehlt - bitte mit --init erzeugen"
fi

section "7. CONFIG_KNOWN_KEYS deckt alle Defaults ab"
# Regression: neue Defaults ohne Eintrag in CONFIG_KNOWN_KEYS würden
# fälschlich als Tippfehler gemeldet.
drift=$(bash -c '
    . "$1/lib/core.sh"
    . "$1/lib/config.sh"
    __snap_before=$(compgen -v | sort -u)
    config_set_defaults
    __snap_after=$(compgen -v | sort -u)
    __snap_new=$(comm -13 <(echo "$__snap_before") <(echo "$__snap_after"))
    for __k in $__snap_new; do
        case "$__k" in __snap_*) continue ;; esac
        config_is_known_key "$__k" || echo "$__k"
    done
' _ "$SANDBOX_DIR" 2>/dev/null)

if [ -z "$drift" ]; then
    pass "Alle Defaults stehen in CONFIG_KNOWN_KEYS"
else
    fail "Nicht in CONFIG_KNOWN_KEYS: $(echo $drift | tr '\n' ' ')"
fi

test_summary