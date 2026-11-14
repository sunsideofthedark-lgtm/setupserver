#!/bin/bash
# ==============================================================================
# setupv4/tests/test-users-firewall.sh - Benutzerverwaltung und Firewall
# ==============================================================================
# Prüft die drei Korrekturen aus dem Serverlauf:
#
#   1. Das Modul users gibt ADMIN_USER an die nachfolgenden Module weiter -
#      sonst wird "sftp-sudoers" als "fehlende Konfiguration" übersprungen.
#   2. Die Firewall warnt nur, wenn die Firewall wirklich aktiv ist.
#   3. fw_configure_ufw aktiviert die Firewall VOR dem Reload.
#
# Das Wirtssystem bleibt unberührt: ufw und sshd werden per PATH-Shadowing
# durch Stubs ersetzt, alle Dateipfade zeigen auf die Sandbox, und die
# Benutzerverwaltung läuft mit protokollierten statt ausgeführten Kommandos
# (kein useradd, kein usermod, kein userdel).
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

STUB_DIR="$SANDBOX_DIR/stub"
mkdir -p "$STUB_DIR"

# ==============================================================================
# Hilfsskripte für die Harnessen
# ==============================================================================

# Stubs der Laufzeitumgebung. Die Bibliotheken des Projekts (core.sh, os.sh,
# config.sh) werden zuerst geladen - diese Datei überschreibt danach nur die
# Eingaben und die Systemkommandos.
cat > "$SANDBOX_DIR/harness-stubs.sh" << 'STUBS'
# Rückfragen werden beantwortet, ohne auf die Konsole zu gehen.
ask_yes_no() { return 0; }

ask_value() {
    local prompt="$1" default_value="$2" varname="$3" value="$2"

    case "$prompt" in
        *Benutzernamen*) value="${ASK_USERNAME:-testadmin}" ;;
    esac
    printf -v "$varname" '%s' "$value"
    return 0
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

# Systemkommandos werden nur protokolliert - es wird nichts ausgeführt.
run_cmd() { echo "[CMD] $*" >> "$LOGFILE"; return 0; }
run_eval() { echo "[EVAL] $1" >> "$LOGFILE"; return 0; }
STUBS

# Harness 1: Modul users mit gestubpten Eingaben ausführen.
cat > "$SANDBOX_DIR/harness-users.sh" << 'HARNESS'
#!/bin/bash
# Führt das Modul users aus und gibt den ermittelten Admin-Benutzer aus.
# Zusätzlich wird der Wert ausgegeben, den ein Kindprozess sieht - das
# beweist, dass ADMIN_USER wirklich exportiert wurde.
SBX="$1"

LOGFILE="$SBX/harness-users.log"
: > "$LOGFILE"

DRY_RUN=1
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DEBUG=0
OS_ID=ubuntu

. "$SBX/lib/core.sh"
. "$SBX/lib/os.sh"
. "$SBX/lib/config.sh"
. "$SBX/harness-stubs.sh"

. "$SBX/modules/50-users.sh"

# Der Benutzer existiert nur, wenn USER_EXISTS=1 - so lassen sich beide
# Zweige des Moduls (neu / bestehend) durchspielen.
users_user_exists() { [ "${USER_EXISTS:-0}" = "1" ]; }

module_main >/dev/null 2>&1
rc=$?

echo "RC=$rc"
echo "ADMIN_USER=${ADMIN_USER:-}"
echo "EXPORTED=$(bash -c 'echo "${ADMIN_USER:-}"')"
HARNESS

# Harness 2: Modul users ausführen und danach die Pflichtprüfung des
# Loaders für sftp-sudoers auswerten - genau diese Prüfung hat im Serverlauf
# den Sprung des Moduls ausgelöst.
cat > "$SANDBOX_DIR/harness-modules.sh" << 'HARNESS'
#!/bin/bash
# Simuliert die Modulausführung des Loaders: erst users, danach die
# Pflichtprüfung für sftp-sudoers (lib/modules.sh).
SBX="$1"

LOGFILE="$SBX/harness-modules.log"
: > "$LOGFILE"

DRY_RUN=1
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DEBUG=0
OS_ID=ubuntu

. "$SBX/lib/core.sh"
. "$SBX/lib/os.sh"
. "$SBX/lib/config.sh"
. "$SBX/lib/modules.sh"
. "$SBX/harness-stubs.sh"

# Das Modul users läuft zuerst - es ermittelt den Admin-Benutzer.
. "$SBX/modules/50-users.sh"
users_user_exists() { [ "${USER_EXISTS:-0}" = "1" ]; }
module_main >/dev/null 2>&1

# Danach das Modul sftp-sudoers - es setzt MODULE_REQUIRED_KEYS=(ADMIN_USER).
. "$SBX/modules/55-sftp-sudoers.sh"

if validate_module_requirements "sftp-sudoers"; then
    echo "REQUIREMENT=ok"
else
    echo "REQUIREMENT=skip"
fi

echo "ADMIN_USER=${ADMIN_USER:-}"
HARNESS

# Harness 3: fw_configure_ufw mit einem gefaelschten ufw ausführen.
cat > "$SANDBOX_DIR/harness-firewall.sh" << 'HARNESS'
#!/bin/bash
# Führt fw_configure_ufw aus. Das echte ufw wird per PATH-Shadowing durch
# einen Stub ersetzt - das Wirtssystem bleibt unberührt.
SBX="$1"

LOGFILE="$SBX/harness-firewall.log"
: > "$LOGFILE"

DRY_RUN=0
NON_INTERACTIVE=1
DEBUG=0

. "$SBX/lib/core.sh"
. "$SBX/lib/os.sh"
. "$SBX/lib/config.sh"

. "$SBX/modules/70-firewall.sh"

fw_configure_ufw "${TEST_SSH_PORT:-22}"
HARNESS

# ==============================================================================
# 1. Das Modul users gibt ADMIN_USER weiter
# ==============================================================================
section "1. users setzt ADMIN_USER - sftp-sudoers läuft danach"

# 1a: Der Benutzer wird interaktiv angelegt (ADMIN_USER steht in keiner
# Config) - genau der Fall aus dem Serverlauf.
out_new=$(env -u ADMIN_USER ASK_USERNAME=testadmin USER_EXISTS=0 NON_INTERACTIVE=0 \
    bash "$SANDBOX_DIR/harness-users.sh" "$SANDBOX_DIR" </dev/null 2>&1)

rc_new=$(echo "$out_new" | sed -n 's/^RC=//p')
admin_new=$(echo "$out_new" | sed -n 's/^ADMIN_USER=//p')
exported_new=$(echo "$out_new" | sed -n 's/^EXPORTED=//p')

assert_exit 0 "$rc_new" "Modul users läuft im Zweig 'neu' fehlerfrei durch"
assert_eq "testadmin" "$admin_new" "ADMIN_USER wird auf den neu angelegten Benutzer gesetzt"
assert_eq "testadmin" "$exported_new" "ADMIN_USER wird exportiert (für nachfolgende Module sichtbar)"

# 1b: Der Benutzer existiert bereits und steht in der Config - die Config
# muss gewinnen, der Benutzer darf nicht ersetzt werden.
out_old=$(env ADMIN_USER=cfgadmin USER_EXISTS=1 NON_INTERACTIVE=1 \
    bash "$SANDBOX_DIR/harness-users.sh" "$SANDBOX_DIR" </dev/null 2>&1)

rc_old=$(echo "$out_old" | sed -n 's/^RC=//p')
admin_old=$(echo "$out_old" | sed -n 's/^ADMIN_USER=//p')
exported_old=$(echo "$out_old" | sed -n 's/^EXPORTED=//p')

assert_exit 0 "$rc_old" "Modul users läuft im Zweig 'bestehend' fehlerfrei durch"
assert_eq "cfgadmin" "$admin_old" "ADMIN_USER aus der Config bleibt im Zweig 'bestehend' erhalten"
assert_eq "cfgadmin" "$exported_old" "ADMIN_USER aus der Config wird exportiert"

# 1c: Die Pflichtprüfung des Loaders darf sftp-sudoers nicht mehr überspringen.
out_req=$(env -u ADMIN_USER ASK_USERNAME=testadmin USER_EXISTS=0 NON_INTERACTIVE=0 \
    bash "$SANDBOX_DIR/harness-modules.sh" "$SANDBOX_DIR" </dev/null 2>&1)

req_result=$(echo "$out_req" | sed -n 's/^REQUIREMENT=//p')
req_admin=$(echo "$out_req" | sed -n 's/^ADMIN_USER=//p')

assert_eq "ok" "$req_result" "sftp-sudoers wird nach dem Modul users nicht mehr übersprungen"
assert_eq "testadmin" "$req_admin" "ADMIN_USER steht auch dem Modul sftp-sudoers zur Verfügung"

# 1d: Komplettlauf im Trockenlauf - das Modul sftp-sudoers darf nicht als
# "fehlende Konfiguration" übersprungen werden.
FAKE_SFTP="$SANDBOX_DIR/fake-sftp-server"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_SFTP"
chmod +x "$FAKE_SFTP"

cat > "$STUB_DIR/sshd" << STUB
#!/bin/bash
# Gefaelschtes sshd: liefert nur den Pfad zum SFTP-Server.
echo "subsystem sftp $FAKE_SFTP"
STUB
chmod +x "$STUB_DIR/sshd"

cat > "$SANDBOX_DIR/users.conf" << 'EOF'
SERVER_HOSTNAME="su-test"
TIMEZONE="Europe/Vienna"
ADMIN_USER="sugo"
SFTP_SUDOERS=true
MODULES=(users sftp-sudoers)
EOF

PATH="$STUB_DIR:$PATH" run_setup --config users.conf --non-interactive --dry-run --yes

assert_exit 0 "$EXIT_CODE" "Lauf mit users + sftp-sudoers endet mit Exit 0"
assert_not_contains "$OUTPUT" "benötigt die Config-Variable ADMIN_USER" \
    "Kein Modul meldet eine fehlende Config-Variable ADMIN_USER"
assert_not_contains "$OUTPUT" "übersprungen (fehlende Konfiguration)" \
    "sftp-sudoers wird nicht mehr als fehlende Konfiguration übersprungen"
assert_contains "$OUTPUT" "92-sftp-nopasswd-sugo" \
    "Die Sudoers-Regel zielt auf den Admin-Benutzer aus der Config"

# ==============================================================================
# 2. Die IPv6-Prüfung warnt nur bei aktiver Firewall
# ==============================================================================
section "2. Firewall: keine IPv6-Warnung bei inaktiver Firewall"

cat > "$STUB_DIR/ufw" << 'STUB'
#!/bin/bash
# Gefaelschtes ufw: protokolliert jeden Aufruf und meldet einen
# vorgegebenen Zustand ("active" oder "inactive").
echo "ufw $*" >> "$UFW_CALL_LOG"

case "$1" in
    status)
        if [ "$UFW_FAKE_STATE" = "active" ]; then
            echo "Status: active"
            echo "To                         Action      From"
            echo "--                         ------      ----"
            echo "22/tcp                     ALLOW       IN    Anywhere                   (v6)"
        else
            echo "Status: inactive"
        fi
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/ufw"

# ufw-Defaults in der Sandbox: IPV6 ist aktiv, damit der Reload-Zweig
# überhaupt erreicht wird.
UFW_DEFAULTS="$SANDBOX_DIR/ufw-defaults"
printf 'IPV6=yes\n' > "$UFW_DEFAULTS"

CALL_LOG="$SANDBOX_DIR/ufw-calls.log"
: > "$CALL_LOG"

fw_inactive=$(PATH="$STUB_DIR:$PATH" \
    UFW_CALL_LOG="$CALL_LOG" UFW_FAKE_STATE=inactive \
    FW_UFW_DEFAULTS="$UFW_DEFAULTS" BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$SANDBOX_DIR/harness-firewall.sh" "$SANDBOX_DIR" 2>&1)

assert_not_contains "$fw_inactive" "Keine IPv6-Regeln in der Firewall gefunden" \
    "Keine IPv6-Warnung, wenn die Firewall nicht aktiv ist"
assert_contains "$fw_inactive" "IPv6-Abdeckung wird nicht geprueft" \
    "Info statt Warnung, wenn die Firewall nicht aktiv ist"

# Gegenprobe: bei aktiver Firewall ohne IPv6-Regeln ist die Warnung richtig.
: > "$CALL_LOG"

fw_active_nov6=$(PATH="$STUB_DIR:$PATH" \
    UFW_CALL_LOG="$CALL_LOG" UFW_FAKE_STATE=active \
    FW_UFW_DEFAULTS="$UFW_DEFAULTS" BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$SANDBOX_DIR/harness-firewall.sh" "$SANDBOX_DIR" 2>&1)

assert_contains "$fw_active_nov6" "Firewall deckt IPv6 ab" \
    "Bei aktiver Firewall mit IPv6-Regeln wird kein Fehler gemeldet"
assert_not_contains "$fw_active_nov6" "Keine IPv6-Regeln in der Firewall gefunden" \
    "Bei aktiver Firewall mit IPv6-Regeln kommt keine Warnung"

# ==============================================================================
# 3. Reihenfolge: aktivieren vor neu anwenden
# ==============================================================================
section "3. Firewall: 'enable' läuft vor 'reload'"

: > "$CALL_LOG"

PATH="$STUB_DIR:$PATH" \
    UFW_CALL_LOG="$CALL_LOG" UFW_FAKE_STATE=active \
    FW_UFW_DEFAULTS="$UFW_DEFAULTS" BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$SANDBOX_DIR/harness-firewall.sh" "$SANDBOX_DIR" >/dev/null 2>&1

calls=$(cat "$CALL_LOG")
enable_line=$(grep -n -- '--force enable' "$CALL_LOG" | head -n1 | cut -d: -f1)
reload_line=$(grep -n -- '--force reload' "$CALL_LOG" | head -n1 | cut -d: -f1)

assert_contains "$calls" "--force enable" "Die Firewall wird aktiviert"
assert_contains "$calls" "--force reload" "Die Firewall-Regeln werden neu angewendet"

if [ -n "$enable_line" ] && [ -n "$reload_line" ] && [ "$enable_line" -lt "$reload_line" ]; then
    assert_true 0 "ufw --force enable wird vor ufw --force reload ausgeführt"
else
    fail "ufw --force enable wird vor ufw --force reload ausgeführt" \
        "enable: Zeile ${enable_line:-?} | reload: Zeile ${reload_line:-?}"
fi

test_summary
