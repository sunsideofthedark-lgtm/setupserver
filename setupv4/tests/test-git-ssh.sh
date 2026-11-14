#!/bin/bash
# ==============================================================================
# setupv4/tests/test-git-ssh.sh - Regressionstests fuer das Modul git-ssh
# ==============================================================================
# Deckt die drei Fehler aus dem Produktivlauf ab:
#
#   1. Die apt-Quellliste enthielt woertlich "arch=$(dpkg --print-architecture)"
#      (die Command-Substitution wurde in einfachen Anfuehrungszeichen nie
#      expandiert). apt meldete danach bei JEDEM Lauf "Malformed entry" und
#      brach damit jede weitere Paketinstallation ab (logrotate, clamav).
#   2. Ein leerer API-Token fuehrte zu einer irrefuehrenden HTTP-401-Meldung
#      statt zu einem sauberen Abbruch.
#   3. Der Schalter INSTALL_GIT_SSH wurde nicht wie in den anderen Modulen
#      ueber module_switch_enabled ausgewertet.
#
# Die Tests laufen ausschliesslich in der Sandbox: weder /etc/apt noch das
# echte $HOME oder die globale Git-Konfiguration werden angefasst.
# ==============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

sandbox_setup >/dev/null || { echo "Sandbox konnte nicht erstellt werden"; exit 1; }
trap sandbox_cleanup EXIT

MODULE_FILE="$SANDBOX_DIR/modules/94-git-ssh.sh"
HARNESS="$SANDBOX_DIR/git-ssh-harness.sh"
FAKEBIN="$SANDBOX_DIR/fakebin"
APTDIR="$SANDBOX_DIR/apt"

mkdir -p "$FAKEBIN" "$APTDIR" "$SANDBOX_HOME/logs" "$SANDBOX_DIR/backups"

# ==============================================================================
# Test-Harness: laedt das Modul und ersetzt alle Systemzugriffe durch Stubs
# ==============================================================================
cat > "$HARNESS" << 'HARNESS'
#!/bin/bash
# ==============================================================================
# Test-Harness fuer das Modul git-ssh (setupv4/tests/test-git-ssh.sh)
# ==============================================================================
# Laedt das Modul in einer Subshell und ersetzt die Systemzugriffe durch
# Stubs: es wird kein Key erzeugt, kein Paket installiert, kein Host-Key
# gescannt und keine Datei ausserhalb der Sandbox geschrieben.
# ==============================================================================
cd "$(dirname "$0")" || exit 1

. lib/core.sh
. lib/config.sh
. lib/modules.sh
. modules/94-git-ssh.sh

# --- Stubs ---
install_package() { return 0; }
gitssh_install_cli() { return 0; }
gitssh_known_hosts_add() { return 0; }
gitssh_test_connection() { return 0; }
gitssh_set_git_identity() { return 0; }
gitssh_resolve_user() { echo "root"; }
gitssh_user_home() { echo "${SANDBOX_HOME}/home"; }

gitssh_ensure_key() {
    # Fake-Key: kein ssh-keygen, keine echten Schluessel.
    # Aufruf: gitssh_ensure_key <ssh_dir> <user> <key_pfad> <kommentar>
    mkdir -p "$1" 2>/dev/null || true
    printf 'ssh-ed25519 AAAAFAKEKEYFORTESTSUITE test@host\n' > "$3.pub"
    return 0
}

# "gh" gilt als nicht installiert - sonst startet das Modul einen
# interaktiven "gh auth login"-Dialog.
command() {
    if [ "$1" = "-v" ] && [ "$2" = "gh" ]; then
        return 1
    fi
    builtin command "$@"
}

# Alle Ja/Nein-Fragen werden mit "ja" beantwortet, ohne stdin zu lesen -
# so bleibt stdin fuer die Token-Eingabe frei.
ask_yes_no() { return 0; }

# Gesondert benannte Module kommen aus der Umgebung.
EXPLICIT_MODULES=()
if [ -n "${HARNESS_EXPLICIT_MODULES:-}" ]; then
    for m in $HARNESS_EXPLICIT_MODULES; do
        EXPLICIT_MODULES+=("$m")
    done
fi

"$@"
HARNESS

# ------------------------------------------------------------------
# Fake-dpkg: meldet eine feste Architektur, damit der Test unabhaengig
# von der echten Maschine laeuft.
# ------------------------------------------------------------------
cat > "$FAKEBIN/dpkg" << 'DPKG'
#!/bin/bash
if [ "$1" = "--print-architecture" ]; then
    echo "arm64"
    exit 0
fi
exit 1
DPKG
chmod +x "$FAKEBIN/dpkg"

# ------------------------------------------------------------------
# Fake-curl: protokolliert jeden Aufruf und liefert 401.
# ------------------------------------------------------------------
cat > "$FAKEBIN/curl" << 'CURL'
#!/bin/bash
echo "curl $*" >> "$CURL_CALL_LOG"
printf '401'
CURL
chmod +x "$FAKEBIN/curl"

section "1. apt-Quellliste: aufgeloeste Architektur statt Command-Substitution"

APT_LIST="$APTDIR/github-cli.list"

# Das echte /etc/apt darf nicht angefasst werden - Zustand vorher merken.
REAL_APT_LIST="/etc/apt/sources.list.d/github-cli.list"
REAL_BEFORE=""
[ -f "$REAL_APT_LIST" ] && REAL_BEFORE="$(cat "$REAL_APT_LIST")"

write_out=$(cd "$SANDBOX_DIR" && PATH="$FAKEBIN:$PATH" \
    LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    DRY_RUN=0 DEBUG=0 \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        gitssh_write_apt_source "$1"
    ' _ "$APT_LIST" 2>&1)
write_rc=$?

assert_exit 0 "$write_rc" "gitssh_write_apt_source meldet Erfolg"

apt_content=""
if [ -f "$APT_LIST" ]; then
    apt_content="$(cat "$APT_LIST")"
    pass "apt-Quellliste wurde geschrieben"
else
    fail "apt-Quellliste wurde nicht geschrieben" "$write_out"
fi

assert_contains "$apt_content" "arch=arm64" "Architektur wurde aufgeloest und eingesetzt"
assert_not_contains "$apt_content" '$(' "Keine Command-Substitution in der apt-Quellliste"
assert_not_contains "$apt_content" 'arch=$(dpkg' "Kein woertliches 'arch=\$(dpkg' in der apt-Quellliste"
assert_eq "deb" "${apt_content%% *}" "Zeile beginnt mit 'deb'"
assert_eq "deb [arch=arm64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    "$apt_content" "apt-Quellliste hat genau den erwarteten Inhalt"

REAL_AFTER=""
[ -f "$REAL_APT_LIST" ] && REAL_AFTER="$(cat "$REAL_APT_LIST")"
assert_eq "$REAL_BEFORE" "$REAL_AFTER" "Das echte /etc/apt wurde nicht angefasst"

# Der fehlerhafte Aufruf darf nicht mehr im Modul stehen. Die Erkennung
# laeuft ueber den Zeilenanfang, damit der Kommentar im Modul (der die
# alte Zeile zitiert) nicht anschlaegt.
if grep -qE '^[[:space:]]*run_cmd sh -c' "$MODULE_FILE"; then
    fail "Modul schreibt die apt-Quelle weiterhin per 'sh -c' (Single-Quotes-Problem)"
else
    pass "Modul schreibt die apt-Quelle nicht mehr per 'sh -c'"
fi

section "2. apt-Quellliste: Pruefung erkennt kaputte Zeilen, Rueckbau stellt her"

BROKEN_LIST="$APTDIR/broken.list"
printf 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' > "$BROKEN_LIST"

verify_rc=$(cd "$SANDBOX_DIR" && LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        gitssh_apt_source_verify "$1"
    ' _ "$BROKEN_LIST" >/dev/null 2>&1; echo $?)
assert_exit 1 "$verify_rc" "Kaputte apt-Quellliste wird erkannt"

verify_ok_rc=$(cd "$SANDBOX_DIR" && LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        gitssh_apt_source_verify "$1"
    ' _ "$APT_LIST" >/dev/null 2>&1; echo $?)
assert_exit 0 "$verify_ok_rc" "Gueltige apt-Quellliste wird akzeptiert"

GOOD_LINE="deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"

ROLL_LIST="$APTDIR/rollback.list"
SNAP="$APTDIR/rollback.snapshot"
printf '%s\n' "$GOOD_LINE" > "$ROLL_LIST"
cp -p "$ROLL_LIST" "$SNAP"
# Datei beschaedigen - so, wie es der fruehere Bug hinterliess.
printf 'deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' > "$ROLL_LIST"

(cd "$SANDBOX_DIR" && LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        GITS_APT_ROLLBACK="$1"
        gitssh_apt_source_rollback "$2"
    ' _ "$SNAP" "$ROLL_LIST" >/dev/null 2>&1)

assert_eq "$GOOD_LINE" "$(cat "$ROLL_LIST")" "Rueckbau stellt die gesicherte apt-Quellliste wieder her"
if [ -f "$SNAP" ]; then
    fail "Rueckbau-Snapshot wurde nicht aufgeraeumt"
else
    pass "Rueckbau-Snapshot wurde aufgeraeumt"
fi

NOSNAP_LIST="$APTDIR/nosnap.list"
printf 'deb [arch=$(dpkg --print-architecture) broken\n' > "$NOSNAP_LIST"
(cd "$SANDBOX_DIR" && LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        GITS_APT_ROLLBACK=""
        gitssh_apt_source_rollback "$1"
    ' _ "$NOSNAP_LIST" >/dev/null 2>&1)

if [ ! -f "$NOSNAP_LIST" ]; then
    pass "Ohne Sicherung wird die kaputte Datei entfernt"
else
    fail "Kaputte apt-Quellliste blieb zurueck"
fi

# Nach bestaetigter Quelle wird der Rueckbau-Snapshot wieder aufgeraeumt -
# sonst bliebe eine Datei "github-cli.list.rollback.XXXXXX" in
# /etc/apt/sources.list.d liegen.
CLEAN_LIST="$APTDIR/cleanup.list"
printf '%s\n' "$GOOD_LINE" > "$CLEAN_LIST"
(cd "$SANDBOX_DIR" && PATH="$FAKEBIN:$PATH" \
    LOGFILE="$SANDBOX_HOME/logs/apt-test.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    DRY_RUN=0 DEBUG=0 \
    bash -c '
        . lib/core.sh
        . lib/config.sh
        . modules/94-git-ssh.sh
        gitssh_write_apt_source "$1" || exit 1
        gitssh_apt_source_snapshot_cleanup
    ' _ "$CLEAN_LIST" >/dev/null 2>&1)

leftovers=$(find "$APTDIR" -name '*.rollback.*' | wc -l | tr -d ' ')
assert_eq "0" "$leftovers" "Kein Rueckbau-Snapshot bleibt liegen"

# Die Datei wurde dabei neu geschrieben - mit der aufgeloesten
# Architektur und ohne Command-Substitution.
clean_content="$(cat "$CLEAN_LIST")"
assert_eq "deb [arch=arm64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    "$clean_content" "apt-Quellliste bleibt nach dem Aufraeumen gueltig"
assert_not_contains "$clean_content" '$(' "Keine Command-Substitution nach dem Aufraeumen"

section "3. Leerer API-Token: Skip statt eines API-Aufrufs mit leerem Token"

CURL_LOG="$SANDBOX_DIR/curl-calls.log"
rm -f "$CURL_LOG"

# Der Benutzer bestaetigt die API-Registrierung und drueckt dann nur Enter.
token_out=$(cd "$SANDBOX_DIR" && printf '\n' | \
    PATH="$FAKEBIN:$PATH" \
    CURL_CALL_LOG="$CURL_LOG" \
    INSTALL_GIT_SSH=true \
    GIT_SSH_SERVICES="github.com|github|1|https://github.com" \
    HARNESS_EXPLICIT_MODULES="" \
    NON_INTERACTIVE=0 DRY_RUN=0 DEBUG=0 \
    SANDBOX_HOME="$SANDBOX_HOME" \
    LOGFILE="$SANDBOX_HOME/logs/setup.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$HARNESS" module_main 2>&1)
token_rc=$?

assert_exit 1 "$token_rc" "Modul endet mit Exit 1 (Skip)"
assert_contains "$token_out" "nur die manuelle Variante" "Ausgabe nennt die manuelle Variante als einzige Moeglichkeit"
assert_not_contains "$token_out" "401" "Keine HTTP-401-Meldung"
assert_not_contains "$token_out" "abgelehnt" "Keine 'Token abgelehnt'-Meldung"

if [ -f "$CURL_LOG" ]; then
    fail "Es wurde ein API-Aufruf mit leerem Token ausgefuehrt: $(cat "$CURL_LOG")"
else
    pass "Kein API-Aufruf mit leerem Token"
fi

section "4. Schalter-Semantik: module_switch_enabled"

# a) Schalter nicht gesetzt, Modul nicht gesondert benannt -> ueberspringen
skip_out=$(cd "$SANDBOX_DIR" && \
    INSTALL_GIT_SSH=false \
    GIT_SSH_SERVICES="github.com|github|1|https://github.com" \
    HARNESS_EXPLICIT_MODULES="" \
    NON_INTERACTIVE=1 DRY_RUN=0 DEBUG=0 \
    SANDBOX_HOME="$SANDBOX_HOME" \
    LOGFILE="$SANDBOX_HOME/logs/setup.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$HARNESS" module_main 2>&1)
skip_rc=$?

assert_exit 1 "$skip_rc" "Modul endet mit Exit 1 (Skip), wenn der Schalter fehlt"
assert_contains "$skip_out" "INSTALL_GIT_SSH ist nicht gesetzt - Git-SSH-Keys werden nicht eingerichtet." "Skip-Meldung nennt den Schalter"
assert_not_contains "$skip_out" "Geplante Dienste:" "Ohne Schalter wird keine Arbeit ausgefuehrt"

# b) Schalter nicht gesetzt, aber Modul gesondert benannt -> laeuft weiter
explicit_out=$(cd "$SANDBOX_DIR" && \
    INSTALL_GIT_SSH=false \
    GIT_SSH_SERVICES="github.com|github|1|https://github.com" \
    HARNESS_EXPLICIT_MODULES="git-ssh" \
    NON_INTERACTIVE=1 DRY_RUN=0 DEBUG=0 \
    SANDBOX_HOME="$SANDBOX_HOME" \
    LOGFILE="$SANDBOX_HOME/logs/setup.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$HARNESS" module_main 2>&1)

assert_not_contains "$explicit_out" "Git-SSH-Keys werden nicht eingerichtet" "Gesondert benanntes Modul ueberspringt sich nicht"
assert_contains "$explicit_out" "Richte Git SSH-Keys ein" "Gesondert benanntes Modul laeuft weiter"

section "5. module_audit liefert genau eine Zeile"

audit_off=$(cd "$SANDBOX_DIR" && \
    INSTALL_GIT_SSH=false \
    GIT_SSH_SERVICES="github.com|github|1|https://github.com" \
    HARNESS_EXPLICIT_MODULES="" \
    NON_INTERACTIVE=1 DRY_RUN=0 DEBUG=0 \
    SANDBOX_HOME="$SANDBOX_HOME" \
    LOGFILE="$SANDBOX_HOME/logs/setup.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$HARNESS" module_audit 2>/dev/null)

audit_off_lines=$(printf '%s\n' "$audit_off" | grep -c '[^[:space:]]' || true)
assert_eq "1" "$audit_off_lines" "Audit liefert genau eine Zeile (Schalter aus)"
assert_contains "$audit_off" "info|Keine Git-SSH-Keys angefordert|INSTALL_GIT_SSH ist nicht gesetzt" "Audit meldet 'nicht angefordert'"
assert_eq "3" "$(printf '%s\n' "$audit_off" | head -n1 | awk -F'|' '{print NF}')" "Audit-Zeile hat drei Felder (Zustand|Zielzustand|Begruendung)"

audit_on=$(cd "$SANDBOX_DIR" && \
    INSTALL_GIT_SSH=true \
    GIT_SSH_SERVICES="github.com|github|1|https://github.com" \
    HARNESS_EXPLICIT_MODULES="" \
    NON_INTERACTIVE=1 DRY_RUN=0 DEBUG=0 \
    SANDBOX_HOME="$SANDBOX_HOME" \
    LOGFILE="$SANDBOX_HOME/logs/setup.log" \
    BACKUP_DIR="$SANDBOX_DIR/backups" \
    bash "$HARNESS" module_audit 2>/dev/null)

audit_on_lines=$(printf '%s\n' "$audit_on" | grep -c '[^[:space:]]' || true)
assert_eq "1" "$audit_on_lines" "Audit liefert genau eine Zeile (Schalter an)"

test_summary
