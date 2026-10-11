# setupv4 — Modulares Server-Setup

Die modulare Nachfolgerin von `setupv3.sh`. Gleiche Aufgaben, aber aufgeteilt
in eigenständige Module, die einzeln getestet, einzeln aktiviert und einzeln
weiterentwickelt werden können.

`setupv3.sh` bleibt unverändert erhalten und läuft weiter — beide Systeme
können parallel genutzt werden.

---

## Wo die Dateien liegen

Egal von wo du `setup.sh` startest: Beim ersten Lauf kopiert sich das Script
nach **`/opt/serversetup`** und läuft von dort weiter.

```
/opt/serversetup/
├── setup.sh              Einstiegspunkt: CLI, Ablaufsteuerung
├── lib/
│   ├── core.sh           Ausgabe, Logging, Eingaben, Validierung
│   ├── os.sh             Betriebssystem, Paketmanager, Services
│   ├── config.sh         Config laden, mergen, validieren
│   └── modules.sh        Module finden, auswählen, ausführen
├── modules/
│   └── <ORDNER>-<ID>.sh  ein Modul pro Datei
├── config/
│   ├── setup.conf
│   └── servers/
│       └── <hostname>.conf   Server-Profil, automatisch erkannt
└── logs/
    └── setup.log              Logfile (Modus 600, mit Rotation)
```

Ein alternatives Ziel lässt sich mit `SETUP_HOME=/pfad` setzen. Wer nicht
umziehen möchte, startet mit `--no-relocate`.

Die Ordnernummer im Dateinamen (`10-system-update.sh`) ist zugleich die
Ausführungsreihenfolge. Neue Module brauchen keine Registrierung — der Loader
findet jede `.sh` in `modules/` anhand ihrer Metadaten.

---

## Schnellstart

```bash
# 1. Interaktiv starten - Setup stellt Fragen
sudo bash setup.sh

# 2. Konfigurationsdatei erzeugen (ausfüllen)
sudo bash setup.sh --init

# 3. Nicht-interaktiv mit Config laufen
sudo bash setup.sh --config config/setup.conf

# 4. Ab hier geht es immer vom festen Ort
sudo /opt/serversetup/setup.sh --status
```

## Optionen

| Option | Bedeutung |
|--------|-----------|
| `-c, --config <datei>` | Konfigurationsdatei laden |
| `--modules <liste>` | Nur diese Module (`users,firewall`) |
| `--set KEY=WERT` | Einzelne Variable überschreiben, mehrfach möglich |
| `-n, --dry-run` | Nichts ändern, nur anzeigen |
| `-y, --yes` | Rückfragen automatisch mit Ja beantworten |
| `--non-interactive` | Keine Rückfragen — fehlende Werte brechen ab |
| `--list` | Verfügbare Module auflisten |
| `--status` | Status der gewählten Module prüfen |
| `--audit` | Ist-Zustand gegen die Zielkonfiguration prüfen |
| `--init` | Beispielkonfiguration erzeugen |
| `--no-profile` | Server-Profil ignorieren |
| `--no-relocate` | Nicht nach `/opt/serversetup` umziehen |
| `DEBUG=1` | Ausführliche Debug-Ausgabe |

---

## Konfiguration

Die Config ist eine **Shell-Datei** und wird gesourct. Damit sind Bedingungen,
Schleifen und Listen möglich:

```bash
# config/servers/su-004.conf
SERVER_ROLE="web"
INSTALL_NGINX=true

if [[ "$SERVER_ROLE" == "pangolin" ]]; then
    FIREWALL_EXTRA_PORTS="51820/udp,21820/udp"
fi
```

### Ladereihenfolge

Spätere Angaben gewinnen:

1. Defaults aus `lib/config.sh`
2. Umgebungsvariablen (`ZOT_API_KEY` usw.) — überschreiben nur die Defaults
3. `config/setup.conf`
4. `config/servers/<hostname>.conf` — automatisch geladen
5. `--set KEY=WERT`

Ein Tippfehler in der Config fällt auf: `INSAL_DOCKER=true` erzeugt eine
Warnung, statt stillschweigend nichts zu tun.

### Mehrere Server

```bash
for server in su-001 su-002 su-003 su-004; do
    ssh "root@$server" "sudo bash setup.sh --config config/setup.conf"
done
```

Jeder Server nimmt sein eigenes Profil, weil `config/servers/<hostname>.conf`
automatisch anhand des Hostnamens geladen wird.

### Secrets

Nicht in die Config schreiben, sondern zur Laufzeit übergeben:

```bash
ZOT_API_KEY=... sudo -E bash setup.sh --config config/setup.conf
sudo bash setup.sh --config c.conf --set ZOT_API_KEY=...
```

Wichtig: Ein **leeres** `ZOT_API_KEY=""` in der Config überschreibt den Wert
aus der Umgebung wieder. Die Vorlage lässt die Zeile deshalb auskommentiert.

Werte aus der Umgebung erscheinen im Log nur maskiert (`abcd****wxyz`).

---

## Module

| # | ID | Name | Schalter |
|---|-----|------|----------|
| 10 | `system-update` | Systemaktualisierung | `SYSTEM_UPDATE` |
| 20 | `auto-updates` | Automatische Sicherheitsupdates | `AUTO_UPDATES` |
| 30 | `hostname` | Server-Hostname | `SET_HOSTNAME`, `SERVER_HOSTNAME` |
| 40 | `timezone` | Zeitzone + NTP | `SET_TIMEZONE`, `TIMEZONE` |
| 50 | `users` | Benutzerverwaltung | `ADMIN_USER`, `CREATE_BACKUP_USER`, `CREATE_SHARED_DIR` |
| 55 | `sftp-sudoers` | SFTP-Sudoers-Regel | `SFTP_SUDOERS`, `ADMIN_USER` |
| 60 | `ssh-hardening` | SSH-Härtung | `SSH_PORT`, `DISABLE_ROOT_LOGIN`, `SSH_ALLOWED_USERS` |
| 70 | `firewall` | Firewall | `FIREWALL_OPEN_WEB_PORTS`, `FIREWALL_EXTRA_PORTS`, … |
| 80 | `docker` | Docker + `daemon.json` | `INSTALL_DOCKER` |
| 82 | `zfs-arc` | ZFS ARC-Cache | `INSTALL_ZFS_ARC` |
| 84 | `nodejs` | Node.js / npm | `INSTALL_NODEJS` |
| 85 | `zot-mirrors` | Zot-Registry-Mirrors | `ZOT_MIRRORS`, `ZOT_ENDPOINT`, `ZOT_API_KEY` |
| 86 | `netbird` | NetBird Mesh-VPN | `INSTALL_NETBIRD`, `NETBIRD_MGMT_URL`, `NETBIRD_SETUP_KEY` |
| 87 | `fail2ban` | Fail2Ban | `INSTALL_FAIL2BAN` |
| 88 | `crowdsec` | CrowdSec + Bouncer | `INSTALL_CROWDSEC` |
| 89 | `nginx` | NGINX | `INSTALL_NGINX` |
| 90 | `node-exporter` | Prometheus Node Exporter | `INSTALL_NODE_EXPORTER` |
| 91 | `monitoring-tools` | htop, iotop, nethogs, ncdu, tmux, git, zip | `INSTALL_HTOP`, `INSTALL_NCUDU`, … |
| 92 | `komodo` | Komodo Periphery | `INSTALL_KOMODO`, `KOMODO_PASSKEY` |
| 93 | `pangolin` | Pangolin SPK / Newt | `INSTALL_PANGOLIN`, `PANGOLIN_SPK` |
| 93b | `clamav` | ClamAV | `INSTALL_CLAMAV` |
| 94 | `github-ssh` | GitHub SSH-Key | `INSTALL_GITHUB_SSH`, `GITHUB_USERNAME` |
| 94b | `omnisight` | Omnisight Agent | `OMNISIGHT_URL`, `OMNISIGHT_TOKEN`, `OMNISIGHT_ROLE` |
| 95 | `maintenance` | Wartung + Cron | `MAINTENANCE_LOGROTATE`, `MAINTENANCE_DISK_MONITOR` |
| 96 | `root-disable` | Root deaktivieren | `DISABLE_ROOT_LOGIN` |
| 99 | `verify` | Netzwerk-/Docker-Verifikation | — |

`--list` zeigt die Liste immer aktuell an, `--status` prüft den Zustand.

### Status und Audit

`--status` beantwortet „was ist gerade eingerichtet?". `--audit` geht einen
Schritt weiter und vergleicht das mit dem, was die **Konfiguration** will:

```
$ sudo bash setup.sh --audit --config config/setup.conf

  hostname               Server-Hostname          ABWEICHUNG
                                                  ist:  aktuell: su-004
                                                  soll: Hostname su-007
  timezone               Zeitzone                 ABWEICHUNG
                                                  ist:  aktuell: Europe/Berlin
                                                  soll: Zeitzone Europe/Vienna
  firewall               Firewall                 nicht prüfbar: ufw aktiv
                                                  ufw ist nicht installiert
------------------------------------------------------------
  Im Zielzustand: 2 | Abweichungen: 2 | Nicht prüfbar: 1
```

Drei Zustände: `ok` (Ziel erreicht), `abweichung` (Ziel nicht erreicht) und
`info` (nicht bewertbar, z. B. weil das Paket auf dieser Distribution nicht
vorhanden ist). Der Exit-Code ist `1`, sobald mindestens eine Abweichung
gemeldet wird — damit lässt sich der Audit in eine Prüf-Pipeline einhängen.

Der Audit liest nur und verändert nichts. Er ist damit das Werkzeug für die
Frage „was ist auf diesem Server veraltet?" — etwa um einen mit `setupv3.sh`
eingerichteten Server auf `setupv4` umzuschätzen, ohne etwas anzufassen.

---

## Tests

```bash
sudo bash tests/run-tests.sh              # alles
sudo bash tests/run-tests.sh framework    # nur ein Bereich
```

Die Tests laufen in einer Kopie unter `/tmp` und fassen weder das Repository
noch `/opt/serversetup` an. Es gibt drei Bereiche:

| Bereich | Prüft |
|---------|-------|
| `framework` | Syntax, Zeilenenden, CLI, Config-Merge, Verlagerung |
| `modules` | Modulkonventionen, Metadaten, Ausführbarkeit, Statustabelle |
| `safety` | Dry-Run schreibt nichts, keine Secrets im Log, Idempotenz |

Bei jedem Push läuft die Suite in der CI (`.github/workflows/setup.yml`).

---

## Ein Modul schreiben

Jede Datei in `modules/` definiert Metadaten und Funktionen — beim Laden darf
kein Code ausgeführt werden:

```bash
MODULE_ID="firewall"
MODULE_NAME="Firewall"
MODULE_DESC="UFW/firewalld konfigurieren"
MODULE_ORDER=70
MODULE_REQUIRED_KEYS=(SSH_PORT)
MODULE_TAGS=("sicherheit")

module_main() {
    info "Firewall wird eingerichtet..."
    return 0
}

module_status() {
    echo "aktiv"
}
```

**Rückgabewerte von `module_main()`:**

| Wert | Bedeutung |
|------|-----------|
| `0` | Erfolgreich |
| `1` | Nicht anwendbar — wird als „Übersprungen" protokolliert |
| `2` | Echter Fehler — die übrigen Module laufen weiter, am Ende Exit-Code 1 |

**Verfügbare Helfer** aus `lib/core.sh`:
`info`, `success`, `warning`, `error`, `skip`, `debug`, `fatal`, `ask_yes_no`,
`ask_value`, `ask_secret`, `confirm`, `mask_secret`, `validate_hostname`,
`validate_username`, `validate_port`, `validate_cidr`, `validate_tags`,
`validate_passkey`, `create_backup`

Aus `lib/os.sh`:
`detect_os`, `install_package`, `is_package_installed`, `manage_service`,
`run_cmd`, `run_eval`

`run_cmd` und `run_eval` respektieren `--dry-run` — für eigene Befehle immer
die beiden nehmen, dann funktioniert der Trockenlauf automatisch.

Funktionsnamen brauchen ein Modul-Präfix (`fw_`, `zot_`, …), weil alle Module
in dieselbe Shell geladen werden.

---

## Sicherheit

- Secrets werden verdeckt abgefragt und nie im Klartext protokolliert
- Das Logfile hat Modus 600 und rotiert bei `LOG_MAX_KB` (Standard 2 MB)
- Config-Werte werden vor der Ausführung validiert (Hostname, Port, Benutzername, Zeitzone, Ports)
- Benutzernamen werden vor dem Schreiben in `/etc/sudoers.d` geprüft (Sudoers-Injection)
- Jede erzeugte Sudoers-Datei wird mit `visudo -c` geprüft und bei Fehlern zurückgerollt
- Änderungen an Systemdateien werden vorher mit `create_backup` gesichert
- Das System startet keine Module, wenn die Konfiguration fehlerhaft ist
- Ungültige Modulnamen führen zu einem Abbruch, nie zu einem stillen Ausweichen
- Ohne Terminal bricht der Lauf ab, statt auf eine Eingabe zu warten
- `--dry-run` verändert nichts — auch nicht die `docker daemon.json`

---

## Verhältnis zu setupv3.sh

| | setupv3.sh | setupv4 |
|---|---|---|
| Struktur | eine Datei, ~4.700 Zeilen | Hauptscript + Bibliotheken + Module |
| Konfiguration | nur interaktiv | interaktiv **oder** per Config-Datei |
| Wiederholbar | eher einmalig | idempotent getestet, für mehrere Server |
| Trockenlauf | nein | `--dry-run` für alles |
| Ablageort | neben dem Aufrufordner | fest `/opt/serversetup` |
| Tests | keine | Testsuite + CI |
| Erweiterung | große Datei anfassen | neue Datei in `modules/` |

Neue Funktionen gehen in v4. `setupv3.sh` bleibt als Referenz und Rückfallebene
bestehen, wird aber nicht mehr erweitert.