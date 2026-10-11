# Server-Profile

Jede Datei in diesem Ordner wird **automatisch** geladen, wenn ihr Name dem
Hostnamen der Maschine entspricht. Kein Eintrag in der Basis-Config nötig.

## Ablauf beim Start

```
config/setup.conf                  <- Basis-Konfiguration
config/servers/<hostname>.conf     <- Server-Profil, gewinnt gegen die Basis
--set KEY=WERT                     <- Kommandozeile, gewinnt gegen alles
```

`--no-profile` überspringt das Server-Profil.

## Beispiel

Für einen Server mit dem Hostnamen `su-004` legst du `su-004.conf` an:

```bash
# su-004.conf
SERVER_ROLE="web"
INSTALL_NGINX=true
FIREWALL_EXTRA_PORTS="80/tcp,443/tcp"
```

Beim Start:

```bash
sudo bash setup.sh --config config/setup.conf
```

lädt erst `setup.conf`, dann `su-004.conf`. Werte aus dem Profil überschreiben
die Basis-Config, werden aber nicht gelöscht — wenn die Basis `true` setzt und
das Profil `false`, gewinnt `false`.

## Mehrere Server gleichzeitig

```bash
for server in su-001 su-002 su-003 su-004; do
    ssh "root@$server" "sudo bash setup.sh --config config/setup.conf"
done
```

Jeder Server nimmt automatisch sein eigenes Profil, weil der Hostname
selbstständig aufgelöst wird.

## Wichtig auf dem Server

Nach der Verlagerung nach `/opt/serversetup` liegen die Profile hier:

```
/opt/serversetup/config/servers/<hostname>.conf
```

Beim Start von einem anderen Ort werden bestehende Config-Dateien **nicht**
überschrieben, sondern nur ergänzt. Anpassungen gehören deshalb in die
Profil-Dateien unter `/opt/serversetup/config/`.

## Tipps

- **Keine Secrets in Git.** API-Keys, Passkeys und Setup-Keys gehören nicht in
  diese Dateien, sondern werden zur Laufzeit übergeben:
  ```bash
  ZOT_API_KEY=... sudo -E bash setup.sh --config config/setup.conf
  ```
- **Nur Abweichungen eintragen.** Ein Profil muss nicht alles wiederholen, was
  schon in `setup.conf` steht.
- **Namen prüfen** mit `hostname -s` — der muss exakt dem Dateinamen entsprechen.
- **Tippfehler werden erkannt.** Unbekannte Schlüssel meldet das Setup mit einer
  Warnung, statt sie stillschweigend zu ignorieren.