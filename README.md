# Server Setup Script

Ein universelles Server-Setup-Skript zur Absicherung und Ersteinrichtung von Linux-Servern.

## One-Liner (Kopieren & Ausführen)

**Ubuntu / Debian:**
```bash
apt update && apt install -y git && git clone https://github.com/sunsideofthedark-lgtm/setupserver.git && cd setupserver && sudo bash ./setupv3.sh
```

**CentOS / RHEL / Rocky / Alma:**
```bash
yum install -y git && git clone https://github.com/sunsideofthedark-lgtm/setupserver.git && cd setupserver && sudo bash ./setupv3.sh
```

**Fedora:**
```bash
dnf install -y git && git clone https://github.com/sunsideofthedark-lgtm/setupserver.git && cd setupserver && sudo bash ./setupv3.sh
```

---

## Schnellstart

```bash
# Repository klonen
git clone https://github.com/sunsideofthedark-lgtm/setupserver.git
cd setupserver

# Skript ausführen
sudo bash ./setupv3.sh

# Debug-Modus (für Fehlerbehebung)
DEBUG=1 sudo bash ./setupv3.sh
```

## Voraussetzungen

- Frischer Linux-Server (VPS, Dedicated, Cloud)
- Root-Zugriff oder sudo-Rechte
- Internetverbindung

## Unterstützte Betriebssysteme

| Distribution | Paketmanager | Firewall |
|-------------|--------------|----------|
| Ubuntu | apt | UFW |
| Debian | apt | UFW |
| CentOS / RHEL / Rocky / Alma | yum/dnf | firewalld |
| Fedora | dnf | firewalld |
| openSUSE / SLES | zypper | firewalld |
| Arch Linux | pacman | UFW |

---

## Was das Skript macht

### Automatisch installiert

Diese Pakete werden automatisch installiert, wenn das Modul "Optionale Software" gewählt wird:

| Software | Beschreibung |
|----------|--------------|
| **Docker** | Container-Plattform mit IPv6-Unterstützung |
| **Node.js/npm** | JavaScript Runtime v20.x LTS |
| **Tailscale** | Mesh-VPN mit SSH und Exit Node |

### Module (auswählbar)

| Modul | Beschreibung |
|-------|--------------|
| Systemaktualisierung | Pakete aktualisieren, Autoremove |
| Automatische Updates | Unattended-Upgrades konfigurieren |
| Hostname | Server-Name ändern |
| Benutzerverwaltung | Neuen sudo-User + SSH-Schlüssel |
| SSH-Härtung | Port ändern, Root deaktivieren |
| Firewall | UFW/firewalld konfigurieren |
| Optionale Software | Fail2Ban, NGINX, Komodo, etc. |
| System-Wartung | Log-Rotation, Disk-Monitoring |
| Root-Deaktivierung | Root-Account sperren |

---

## Schritt-für-Schritt Anleitung

### 1. Server vorbereiten

```bash
# Als Root einloggen
ssh root@<SERVER_IP>

# System aktualisieren
apt update && apt upgrade -y  # Ubuntu/Debian
# oder
yum update -y                  # CentOS/RHEL
```

### 2. Skript herunterladen

```bash
# Git installieren (falls nicht vorhanden)
apt install -y git   # Ubuntu/Debian
# oder
yum install -y git   # CentOS/RHEL

# Repository klonen
git clone https://github.com/sunsideofthedark-lgtm/setupserver.git
cd setupserver
```

### 3. Skript ausführen

```bash
sudo bash ./setupv3.sh
```

### 4. Modul-Auswahl

Das Skript bietet zwei Modi:

1. **Komplettes Setup** - Alle Module werden ausgeführt
2. **Modulare Auswahl** - Einzelne Module auswählen

### 5. Tailscale konfigurieren

Bei der Installation wird nach einem Tailscale Auth-Key gefragt:

1. Gehe zu https://login.tailscale.com/admin/settings/keys
2. Erstelle einen **Reusable** Key
3. Füge den Key im Skript ein

**Optionen:**
- SSH: Automatisch aktiviert
- Exit Node: Automatisch advertised
- Subnet Router: Optional (CIDR eingeben)
- Tags: Optional (z.B. `tag:server,tag:prod`)

### 6. Komodo Periphery (optional)

Wenn Komodo installiert wird:

1. Passkey erstellen (min. 20 Zeichen)
2. Tailscale IP wird automatisch erkannt
3. Konfiguration liegt in `/opt/komodo/compose.yml`

---

## Nach dem Setup

### SSH-Verbindung

```bash
# Mit SSH-Schlüssel
ssh -i /pfad/zum/schlüssel -p <PORT> <USER>@<SERVER_IP>

# Über Tailscale (empfohlen)
tailscale ssh <USER>@<HOSTNAME>
```

### Wichtige Dateien

| Datei | Beschreibung |
|-------|--------------|
| `./install.log` | Setup-Log |
| `/etc/ssh/sshd_config` | SSH-Konfiguration |
| `/etc/docker/daemon.json` | Docker-Konfiguration |
| `/opt/komodo/compose.yml` | Komodo Periphery |

### Server neustarten

```bash
sudo reboot
```

---

## Tailscale - Exit Node aktivieren

Nach dem Setup muss der Exit Node in der Tailscale Admin-Console approved werden:

1. Gehe zu https://login.tailscale.com/admin/machines
2. Klicke auf den Server
3. Aktiviere "Exit Node"
4. Speichern

---

## Komodo - Server hinzufügen

In der Komodo Core Instanz:

1. Gehe zu "Servers" → "Add Server"
2. Trage ein:
   - **Address:** `<TAILSCALE_IP>:8120` (oder `0.0.0.0:8120`)
   - **Passkey:** (siehe `/opt/komodo/compose.yml`)

---

## Docker-Konfiguration

Das Skript erstellt automatisch:

```json
{
  "mtu": 1450,
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

---

## Optionale Software

| Kategorie | Pakete |
|-----------|--------|
| Sicherheit | Fail2Ban, ClamAV |
| Web | NGINX |
| Monitoring | Prometheus Node Exporter, htop, iotop, nethogs |
| Administration | ncdu, tmux, DB-Clients, git, zip/unzip |
| VPN | Tailscale (auto), Komodo Periphery |

---

## Sicherheitshinweise

- Auth-Keys und Passkeys werden im Log maskiert
- CIDR-Notation wird validiert
- Tailscale Tags werden auf korrektes Format geprüft
- Komodo Passkey muss min. 20 Zeichen haben

---

## Fehlerbehebung

### Debug-Modus

```bash
DEBUG=1 sudo bash ./setupv3.sh
```

### Log prüfen

```bash
cat ./install.log
```

### Docker Probleme

```bash
# Docker Status
systemctl status docker

# Docker Logs
journalctl -u docker

# Docker Netzwerk prüfen
docker network ls
docker network inspect newt_talk
```

### Tailscale Probleme

```bash
# Tailscale Status
tailscale status

# Neu verbinden
tailscale up --force-reauth
```

---

## Versionshistorie

| Version | Änderungen |
|---------|------------|
| 3.4.0 | Sicherheit: Secret-Masking, Validierung für CIDR/Tags/Passkey |
| 3.3.0 | Docker, Node.js/npm, Tailscale werden automatisch installiert |
| 3.2.0 | Docker Auto-Install, Komodo Periphery Agent |
| 3.1.0 | Tailscale Integration |
| 3.0.0 | Docker JSON-Fix für IPv6 |

---

## Lizenz

MIT License

---

## Autor

[sunsideofthedark-lgtm](https://github.com/sunsideofthedark-lgtm)
