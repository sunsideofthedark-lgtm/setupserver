# Server-Setup-Skript (setupv3.sh) - Dokumentation

## Übersicht

| Eigenschaft | Wert |
|-------------|------|
| **Version** | 3.3.0 |
| **Dateiname** | `setupv3.sh` |
| **Zweck** | Universelles Server-Setup-Skript zur Absicherung und Ersteinrichtung von Linux-Servern |
| **Log-Datei** | `./install.log` |

## Unterstützte Betriebssysteme

| Distribution | Paketmanager | Firewall | SSH-Service |
|-------------|--------------|----------|-------------|
| Ubuntu | apt | UFW | ssh |
| Debian | apt | UFW | ssh |
| CentOS | yum/dnf | firewalld | sshd |
| RHEL | yum/dnf | firewalld | sshd |
| Rocky Linux | yum/dnf | firewalld | sshd |
| AlmaLinux | yum/dnf | firewalld | sshd |
| Fedora | dnf | firewalld | sshd |
| openSUSE | zypper | firewalld | sshd |
| SLES | zypper | firewalld | sshd |
| Arch Linux | pacman | UFW | sshd |

---

## Setup-Module

Das Skript bietet ein **modulares Menüsystem** mit 9 Konfigurationsmodulen.

### 1. Systemaktualisierung (`system_update`)

**Funktionen:**
- Paketlisten aktualisieren (`apt update` / `dnf check-update`)
- System-Upgrades durchführen
- Veraltete Pakete entfernen (`autoremove`)

**Status-Erkennung:**
- Prüft `/var/log/apt/history.log` oder `/var/log/yum.log` auf heutige Einträge

---

### 2. Automatische Updates (`auto_updates`)

**Distributionsspezifische Konfiguration:**

| Distribution | Tool | Konfiguration |
|-------------|------|---------------|
| Ubuntu/Debian | unattended-upgrades | Täglich, nur Sicherheitsupdates, Auto-Reboot deaktiviert |
| CentOS/RHEL | yum-cron | Nur Sicherheitsupdates, automatisch angewendet |
| Fedora | dnf-automatic | Täglich um 06:00 Uhr, Sicherheitsupdates |
| openSUSE | YaST Online Update | Repository Refresh automatisch |
| Arch Linux | - | Nicht unterstützt (Rolling Release) |

**Konfigurationsdateien:**
- `/etc/apt/apt.conf.d/20auto-upgrades`
- `/etc/apt/apt.conf.d/50unattended-upgrades`
- `/etc/yum/yum-cron.conf`
- `/etc/dnf/automatic.conf`

---

### 3. Hostname-Konfiguration (`hostname`)

**Validierungsregeln (RFC 1123):**
- Nur Buchstaben (a-z), Zahlen (0-9) und Bindestriche (-)
- Muss mit Buchstabe oder Zahl beginnen und enden
- Maximal 63 Zeichen
- Keine aufeinanderfolgenden Bindestriche

**Aktionen:**
- `hostnamectl set-hostname <name>`
- `/etc/hosts` aktualisieren

---

### 4. Benutzerverwaltung (`user_management`)

**Erstellte Ressourcen:**

| Ressource | Beschreibung |
|-----------|--------------|
| Benutzer | Neuer sudo-Benutzer mit Passwort |
| Gruppe `remotessh` | Spezielle SSH-Zugriffs-Gruppe |
| Gruppe `sudo`/`wheel` | Admin-Rechte (distributionsspezifisch) |
| SSH-Schlüssel | ED25519-Schlüsselpaar |

**Arbeitsverzeichnisse:**
- `~/projects/` - Entwicklungsprojekte
- `~/scripts/` - Persönliche Scripts
- `~/backups/` - Lokale Backups
- `/srv/*` - Sichere sudo-Zugriffe für Server-Projekte

**Benutzernamen-Validierung:**
- Nur Kleinbuchstaben (a-z), Zahlen (0-9), Unterstriche (_) und Bindestriche (-)
- Muss mit Buchstabe oder Unterstrich beginnen
- Maximal 32 Zeichen
- Keine reservierten Systemnamen (root, daemon, bin, etc.)

---

### 5. SSH-Härtung (`ssh_hardening`)

**Port-Konfiguration:**
- Standard: 2222
- Bereich: 1024-65535
- Reservierte Ports vermieden: 1080, 3128, 8080, 8888, 9050, 9051

**Sicherheitsoptionen in `/etc/ssh/sshd_config`:**

| Option | Wert | Beschreibung |
|--------|------|--------------|
| `PermitRootLogin` | no | Root-Login deaktiviert |
| `PasswordAuthentication` | no | Nur SSH-Schlüssel |
| `AllowGroups` | remotessh | SSH nur für diese Gruppe |
| `MaxAuthTries` | 3 | Max. Anmeldeversuche |
| `ClientAliveInterval` | 300 | Timeout nach 5 Min Inaktivität |
| `ClientAliveCountMax` | 2 | Max. Timeouts |
| `MaxSessions` | 10 | Max. gleichzeitige Sessions |
| `X11Forwarding` | no | X11 deaktiviert |
| `AllowAgentForwarding` | no | Agent-Forwarding deaktiviert |
| `AllowTcpForwarding` | no | TCP-Forwarding deaktiviert |
| `PermitEmptyPasswords` | no | Keine leeren Passwörter |
| `PermitUserEnvironment` | no | Keine Benutzer-Umgebungsvariablen |
| `Compression` | no | Komprimierung deaktiviert |

---

### 6. Firewall-Konfiguration (`firewall`)

**Standard-Regeln:**
- Default: Incoming DENY, Outgoing ALLOW
- SSH-Port (benutzerdefiniert) immer geöffnet
- Port 22/tcp blockiert wenn SSH-Port != 22

**Interaktive Port-Auswahl:**

| Service | Ports | Protokoll |
|---------|-------|-----------|
| HTTP | 80 | TCP |
| HTTPS | 443 | TCP |
| Pangolin VPN | 51820, 21820 | UDP |
| Komodo | 8120 | TCP |

**IPv6:** Automatisch aktiviert in `/etc/default/ufw`

---

### 7. Optionale Software (`optional_software`)

#### Sicherheit

| Paket | Beschreibung | Status-Anzeige |
|-------|--------------|----------------|
| Fail2Ban | Brute-Force-Schutz für SSH | Installations-Check |
| UFW Extras | Erweiterte Firewall-Regeln, Logging | Verfügbar |
| ClamAV | Antivirus-Scanner | Installations-Check |

#### Web & Container

| Paket | Beschreibung |
|-------|--------------|
| NGINX | Webserver & Reverse Proxy |
| Docker | Container-Plattform |

#### Monitoring & Performance

| Paket | Beschreibung |
|-------|--------------|
| Prometheus Node Exporter | System-Metriken (Port 9100) |
| htop | Verbesserter System-Monitor |
| iotop | I/O-Monitor für Festplatten |
| nethogs | Netzwerk-Traffic pro Prozess |

#### Administration

| Paket | Beschreibung |
|-------|--------------|
| ncdu | Interaktiver Festplatten-Analysator |
| tmux | Terminal-Multiplexer |
| MariaDB Client | Datenbank-CLI |
| PostgreSQL Client | Datenbank-CLI |
| git | Versionskontrolle |
| zip/unzip | Archivierungs-Tools |

#### VPN & Networking

| Paket | Beschreibung |
|-------|--------------|
| Tailscale | Mesh-VPN mit Exit Node & SSH |
| Komodo Periphery | Docker-Verwaltung über Komodo Core |

---

### Docker-Installation (v3.2 - Automatisch)

**Ab Version 3.2 wird Docker automatisch installiert**, wenn das Modul "Optionale Software" gewählt wird.

**Automatische Konfiguration:**
- Docker CE + Docker Compose Plugin
- `daemon.json` mit IPv6-Unterstützung
- UFW-Forwarding für Docker
- Netzwerk `newt_talk` wird erstellt
- Benutzer wird zur `docker`-Gruppe hinzugefügt

---

### Komodo Periphery Agent (Detail)

**Installationspfad:** `/opt/komodo/`

**Dateien:**
- `/opt/komodo/compose.yml` - Docker Compose Konfiguration
- `/opt/komodo/stacks/` - Stack-Konfigurationen
- `/opt/komodo/compose/` - Compose-Dateien

**Konfiguration:**

| Option | Beschreibung |
|--------|--------------|
| Passkey | Erforderlich für Core-Verbindung |
| Bind IP | Tailscale IP (empfohlen) oder 0.0.0.0 |
| Port | 8120 (Standard) |

**Tailscale-Integration:**
- Erkennt automatisch Tailscale IP
- Empfiehlt Bindung an Tailscale Interface für Sicherheit
- Nur über VPN erreichbar wenn Tailscale IP gewählt

**docker-compose.yml Beispiel:**
```yaml
services:
  komodo-agent:
    image: ghcr.io/moghtech/komodo-periphery:latest
    restart: unless-stopped
    container_name: komodo-periphery
    environment:
      PERIPHERY_ROOT_DIRECTORY: /opt/komodo
      PERIPHERY_PASSKEYS: "YOUR_PASSKEY"
      PERIPHERY_SSL_ENABLED: true
      PERIPHERY_DISABLE_TERMINALS: false
      PERIPHERY_INCLUDE_DISK_MOUNTS: /opt/
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      - /opt:/opt
    ports:
      - 100.x.x.x:8120:8120  # Tailscale IP
```

---

### Tailscale-Konfiguration (Detail)

**Automatisch aktivierte Features:**

| Feature | Flag | Beschreibung |
|---------|------|--------------|
| Tailscale SSH | `--ssh` | SSH über Tailscale-Identität |
| Exit Node | `--advertise-exit-node` | Server als Exit Node anbieten |
| Hostname | `--hostname` | Automatisch vom System übernommen |

**Optionale Features:**

| Feature | Flag | Beschreibung |
|---------|------|--------------|
| Subnet Router | `--advertise-routes=<CIDR>` | Lokales Netzwerk über Tailscale erreichbar |
| Tags | `--advertise-tags=<tags>` | ACL-Tags für Zugriffskontrolle |

**Beispiel-Subnet-Routes:**
- `192.168.1.0/24` - Heimnetzwerk (254 IPs)
- `10.0.0.0/8` - Großes Firmennetzwerk
- `172.16.0.0/12` - Private Netzwerke

**Nach der Installation:**
1. Exit Node in Admin-Console approving: `https://login.tailscale.com/admin/machines`
2. Subnet Routes ebenfalls approving falls konfiguriert
3. Verbindung testen: `tailscale status`

**UFW-Integration:**
- Tailscale Interface (`tailscale0`) wird automatisch erlaubt

---

### Docker-Konfiguration (Detail)

**daemon.json Einstellungen:**

```json
{
  "mtu": 1450,
  "live-restore": true,
  "metrics-addr": "127.0.0.1:9323",
  "experimental": true,
  "ipv6": true,
  "fixed-cidr-v6": "fd00:db8:1::/64",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    { "base": "172.25.0.0/16", "size": 24 },
    { "base": "fd00:db8:10::/56", "size": 64 }
  ]
}
```

**Netzwerk `newt_talk`:**
- IPv4: `172.25.0.0/24`
- IPv6: `fd00:db8:10:0::/64`
- MTU: 1450

**UFW-Konfiguration für Docker:**
- `DEFAULT_FORWARD_POLICY="ACCEPT"`
- Allow-Regeln für alle Docker-Pools

---

### 8. System-Wartung (`system_maintenance`)

**Log-Rotation (`/etc/logrotate.d/custom-server`):**

| Log-Datei | Rotation | Aufbewahrung |
|-----------|----------|--------------|
| `/var/log/auth.log` | wöchentlich | 12 Wochen |
| `/var/log/secure` | wöchentlich | 12 Wochen |
| `/var/log/messages` | wöchentlich | 12 Wochen |
| `/var/log/fail2ban.log` | wöchentlich | 8 Wochen |

**Disk-Space-Monitoring:**
- Skript: `/usr/local/bin/disk-space-monitor.sh`
- Cronjob: Täglich um 02:00 Uhr
- Schwellwert: 90%

---

### 9. Root-Deaktivierung (`root_security`)

**Aktionen:**
1. Root-Account sperren: `usermod --lock root`
2. Root-Passwort entfernen: `passwd -d root`
3. SSH-Konfiguration validieren: `sshd -t`

**sudo-Sicherheit (`/etc/sudoers.d/90-admin-security`):**
- `timestamp_timeout=15` - sudo-Cache 15 Min
- `passwd_timeout=5` - Passwort-Eingabe Timeout
- `pwfeedback` - Sternchen bei Passwort-Eingabe
- `logfile="/var/log/sudo.log"` - Logging aktiviert
- `log_input, log_output` - Befehle protokollieren

---

## Hilfsfunktionen

### OS-Erkennung
```bash
detect_os()  # Erkennt OS, Paketmanager, Firewall, SSH-Service
```

### Interaktion
```bash
ask_yes_no "<prompt>" "[y|n]"  # Ja/Nein-Fragen mit Standardwert
confirm "<prompt>"             # Bestätigungsabfrage [y/N]
```

### Validierung
```bash
validate_hostname "<name>"     # RFC 1123 Hostname-Validierung
validate_username "<name>"     # POSIX Benutzernamen-Validierung
validate_port "<port>"         # Port-Bereich 1024-65535
```

### Paket-Management
```bash
is_package_installed "<paket>" "[command]"  # Prüft Installation
install_package "<paket>" "[alt_paket]"      # Installiert mit 3 Retrys
```

### Backup & Logging
```bash
create_backup "<datei>"        # Backup nach /var/backups/server-setup/
log_action "<level>" "<msg>"   # Logging in install.log
debug "<msg>"                  # Debug-Ausgabe (nur mit DEBUG=1)
```

---

## Ausführung

### Standard
```bash
sudo bash ./setupv3.sh
```

### Debug-Modus
```bash
DEBUG=1 sudo bash ./setupv3.sh
```

### Menü-Optionen
1. **Komplettes Setup** - Alle Module ausführen
2. **Modulare Auswahl** - Einzelne Module wählen
3. **Beenden**

---

## Setup-Ablauf

```
1. OS-Erkennung
2. Root-Rechte prüfen
3. Netzwerk-Check
4. Modul-Auswahl (Menü)
5. Module ausführen:
   ├── Systemaktualisierung
   ├── Automatische Updates
   ├── Hostname
   ├── Benutzerverwaltung + SSH-Schlüssel
   ├── SSH-Härtung
   ├── Firewall
   ├── Optionale Software
   ├── System-Wartung
   └── Root-Deaktivierung
6. Docker-Netzwerk-Test (falls Docker installiert)
7. Server-Neustart
```

---

## Nach dem Setup

### SSH-Verbindung
```bash
ssh -i /pfad/zum/privaten/schlüssel -p <PORT> <USER>@<SERVER_IP>
```

### Wichtige Hinweise
1. **SSH-Schlüssel sofort sichern** - Wird nach Anzeige vom Server gelöscht
2. **Neues Terminal testen** - Vor dem Schließen der aktuellen Sitzung
3. **Server neustarten** - Damit alle Änderungen wirksam werden

---

## Dateien und Pfade

| Datei/Pfad | Beschreibung |
|------------|--------------|
| `./install.log` | Setup-Log |
| `/var/backups/server-setup/` | Backup-Verzeichnis |
| `/etc/ssh/sshd_config` | SSH-Konfiguration |
| `/etc/default/ufw` | UFW-Konfiguration |
| `/etc/docker/daemon.json` | Docker-Daemon-Konfiguration |
| `/etc/sudoers.d/90-admin-security` | sudo-Sicherheit |
| `/etc/sudoers.d/91-<user>-srv` | /srv-Zugriff für Benutzer |
| `/usr/local/bin/disk-space-monitor.sh` | Disk-Monitoring |
| `/etc/logrotate.d/custom-server` | Log-Rotation |

---

## Versionshistorie

| Version | Änderungen |
|---------|------------|
| 3.3.0 | Docker, Node.js/npm, Tailscale werden automatisch installiert |
| 3.2.0 | Docker Auto-Install, Komodo Periphery Agent, Tailscale IP Binding |
| 3.1.0 | Tailscale Integration: VPN mit SSH, Exit Node, Subnet Router, Tags |
| 3.0.0 | Docker JSON-Fix: `default-address-pools-v6` entfernt, IPv4/IPv6 in einem Array |
| 2.9.0 | Stabile Docker IPv6-ULA-Pools (`fd00::/8` statt `2001:db8::`) |
| 2.8.0 | Docker IPv6-Status-Erkennung |
| 2.7.0 | Verbessertes Logging |
| 2.6.0 | Log-Datei im Skript-Verzeichnis |
| 2.3.0 | Interaktive Firewall-Konfiguration |
