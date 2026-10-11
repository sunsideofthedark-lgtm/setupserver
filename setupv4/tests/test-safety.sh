#!/bin/bash
# ==============================================================================
# setupv4/tests/test-safety.sh - Sicherheitsgarantien
# ==============================================================================
# Prüft die Zusagen, die setupv4 macht: --dry-run verändert nichts, Secrets
# landen nicht im Klartext im Log, ein zweiter Lauf ist unschädlich.
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

# Pfade, die ein Lauf niemals anlegen dürfte
PROTECTED_PATHS=(
    "/etc/docker"
    "/etc/sudoers.d/92-sftp-nopasswd-sugo"
    "/etc/fail2ban"
    "/etc/crowdsec"
    "/opt/komodo"
    "/opt/pangolin"
    "/usr/local/bin/disk-space-monitor.sh"
    "/etc/systemd/system/node_exporter.service"
    "/var/backups/serversetup"
)

section "1. Dry-Run legt keine Systemdateien an"
existing_before=""
for p in "${PROTECTED_PATHS[@]}"; do
    [ -e "$p" ] && existing_before="$existing_before $p"
done

cat > "$SANDBOX_DIR/full.conf" << 'EOF'
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SSH_PORT=2222
SFTP_SUDOERS=true
ZOT_MIRRORS=true
MAINTENANCE_LOGROTATE=true
MAINTENANCE_DISK_MONITOR=true
MODULES=(system-update auto-updates hostname timezone users sftp-sudoers
        ssh-hardening firewall docker zfs-arc nodejs zot-mirrors netbird
        fail2ban crowdsec nginx node-exporter monitoring-tools
        komodo pangolin github-ssh clamav omnisight
        maintenance root-disable verify)
EOF

run_setup --config full.conf --non-interactive --dry-run --yes
assert_exit 0 "$EXIT_CODE" "Trockenlauf mit allen Schaltern endet mit Exit 0"

created=0
for p in "${PROTECTED_PATHS[@]}"; do
    case " $existing_before " in
        *" $p "*) continue ;;  # existierte vorher, nicht unser Verdienst
    esac
    if [ -e "$p" ]; then
        fail "Trockenlauf hat Systempfad angelegt: $p"
        created=1
    fi
done
[ $created -eq 0 ] && pass "Trockenlauf legt keine Systemdateien an"

section "2. Keine Secrets im Klartext"
ZOT_API_KEY="SUPERGEHEIMES_TOKEN_1234" \
KOMODO_PASSKEY="PASSKEY_SUPERGEHEIM_5678" \
PANGOLIN_SPK="spk_GEHEIMES_SPK_9999" \
    run_setup --config full.conf --non-interactive --dry-run --yes

logfile="$SANDBOX_HOME/logs/setup.log"
logtext=""
[ -f "$logfile" ] && logtext=$(cat "$logfile")
combined="$OUTPUT
$logtext"

leak=0
for secret in "SUPERGEHEIMES_TOKEN_1234" "PASSKEY_SUPERGEIM_5678" "spk_GEHEIMES_SPK_9999"; do
    if [[ "$combined" == *"$secret"* ]]; then
        fail "Secret im Klartext gefunden: $secret"
        leak=1
    fi
done
[ $leak -eq 0 ] && pass "Keine Secrets im Klartext (Ausgabe + Log)"

if [ -n "$logtext" ]; then
    assert_eq "600" "$(stat -c '%a' "$logfile" 2>/dev/null)" "Logfile hat Modus 600"
else
    fail "Logfile wurde nicht erzeugt"
fi

section "3. Idempotenz: zweiter Lauf ist unschädlich"
run_setup --config full.conf --non-interactive --dry-run --yes
first_exit="$EXIT_CODE"

timeout 180 bash -c "cd '$SANDBOX_DIR' && SETUP_HOME='$SANDBOX_HOME' bash ./setup.sh --config full.conf --non-interactive --dry-run --yes >/dev/null 2>&1"
second_exit=$?
assert_exit 0 "$second_exit" "Zweiter Lauf endet ebenfalls mit Exit 0"
assert_exit "$first_exit" "$second_exit" "Beide Läufe liefern denselben Exit-Code"

section "4. Keine Hängerei ohne TTY"
echo 'SERVER_HOSTNAME="su-test"' > "$SANDBOX_DIR/only.conf"
timeout 30 bash -c "cd '$SANDBOX_DIR' && SETUP_HOME='$SANDBOX_HOME' bash ./setup.sh --config only.conf --dry-run </dev/null >/dev/null 2>&1"
nontty_exit=$?
assert_exit 1 "$nontty_exit" "Ohne TTY bricht der Lauf ab statt zu hängen"
assert_ne 124 "$nontty_exit" "Kein Timeout - es wird nicht auf Eingabe gewartet"

section "5. Log-Rotation"
rot_dir="$SANDBOX_DIR/rottest"
mkdir -p "$rot_dir"
dd if=/dev/zero of="$rot_dir/setup.log" bs=1K count=4096 2>/dev/null
(cd "$SANDBOX_DIR" && LOG_MAX_KB=1024 LOGFILE="$rot_dir/setup.log" \
    SETUP_DIR="$SANDBOX_DIR" bash -c '. lib/core.sh; setup_logging' >/dev/null 2>&1)
if [ -f "$rot_dir/setup.log.1" ]; then
    pass "Logfile wird bei Überschreitung rotiert"
else
    fail "Logfile wurde nicht rotiert"
fi

section "6. Keine Secrets im Repository"
GITIGNORE="$SANDBOX_DIR/.gitignore"
if [ -f "$GITIGNORE" ]; then
    assert_contains "$(cat "$GITIGNORE")" "*.log" ".gitignore schließt Logdateien generell aus"
    assert_contains "$(cat "$GITIGNORE")" "config/setup.conf" ".gitignore schließt echte setup.conf aus"
    assert_contains "$(cat "$GITIGNORE")" "config/servers/*.conf" ".gitignore schließt Server-Profile aus"
else
    fail ".gitignore fehlt in setupv4"
fi

test_summary