# autobackup

YAML-konfiguriertes Backup-Skript für den VPS. Sichert Pfade (z. B. `/docker/container/…`)
in ein Zielverzeichnis (z. B. `/backup/container/…`) und benachrichtigt nach erfolgreichem
Backup via **Gotify** oder einem **generischen Webhook**. Die zeitliche Steuerung erfolgt
über einen **Cron-Job**.

## Funktionen

- **Zwei Backup-Methoden** pro Eintrag wählbar:
  - `tar` – komprimiertes Archiv (`<name>_<zeitstempel>.tar.gz`)
  - `rsync` – timestampierte Verzeichnisse mit **Hardlinks** zur Speicherplatzersparnis
- **Rotation** altbackups pro Eintrag individuell einstellbar:
  - nach **Tagen** (`keep_days`) und/oder
  - nach **Anzahl** (`keep_count`)
- **Benachrichtigung** bei Erfolg über Gotify oder Webhook
- **Token aus separater Datei** – wird durch die `.gitignore` vor dem Upload geschützt
- Beliebig viele Backup-Jobs in einer Konfigurationsdatei
- Exclude-Listen pro Job
- Einfaches Logging in eine Logdatei
- Lock-Mechanismus, damit sich parallele Läufe (doppelte Cron-Aufrufe) nicht in die Quere kommen
- Pure Bash, **keine** zusätzlichen Tools (kein `yq`, kein Python) nötig – nur Standard-Nützlichkeiten

## Voraussetzungen

| Paket | Zweck | Installation (Debian/Ubuntu) |
|---|---|---|
| `bash` (>= 4) | Script | i. d. R. vorhanden |
| `tar` | tar-Methode | `sudo apt install tar` |
| `rsync` | rsync-Methode | `sudo apt install rsync` |
| `curl` | Benachrichtigung | `sudo apt install curl` |
| `util-linux` (flock) | Lock | i. d. R. vorhanden |
| `find`, `ls`, `du`, etc. | Rotation, Logging | i. d. R. vorhanden |

## Installation

```bash
# 1) Script installieren
sudo cp backup.sh /usr/local/bin/autobackup
sudo chmod +x /usr/local/bin/autobackup

# 2) Konfiguration anlegen
sudo mkdir -p /etc/autobackup
sudo cp backup.yml.example /etc/autobackup/backup.yml
sudo chmod 600 /etc/autobackup/backup.yml

# 3) Gotify-Token in separate Datei schreiben (optional, für Webhook nicht nötig)
sudo sh -c 'echo "DEIN_GOTIFY_TOKEN" > /etc/autobackup/gotify.token'
sudo chmod 600 /etc/autobackup/gotify.token

# 4) Testlauf
sudo autobackup /etc/autobackup/backup.yml
```

> **Wichtig:** Das Token wird **nicht** in `backup.yml` abgelegt, sondern in eine eigene
> Datei, auf die die Konfiguration mit `notify.token_file` verweist. Die `.gitignore`
> schließt `gotify.token` und `backup.yml` aus, damit beides nicht versehentlich ins
> Git-Repository gelangt.

## Konfiguration

### Globale Einstellungen

| Key | Beschreibung | Standard |
|---|---|---|
| `notify.type` | `gotify` oder `webhook` | `gotify` |
| `notify.url` | Basis-URL z. B. `https://gotify.example.com` | – |
| `notify.token_file` | Pfad zur Datei, die das Gotify-Token enthält | – |
| `notify.token` | Alternative: Token direkt angeben (nicht empfohlen, landet evtl. im Git) | – |
| `notify.title` | Titel, der an Benachrichtigungen vorangestellt wird | `Autobackup` |
| `notify.notify_on_error` | `true` – auch bei Fehlern benachrichtigen | `false` |
| `log_file` | Pfad zur Logdatei | `/var/log/autobackup.log` |

### Backup-Jobs (`backups:`)

| Key | Pflicht | Beschreibung |
|---|---|---|
| `name` | ja | Eindeutiger Name (bestimmt den Datei-/Ordnernamen des Backups) |
| `source` | ja | Quellpfad, z. B. `/docker/container/appdata` |
| `destination` | ja | Zielpfad, z. B. `/backup/container/appdata` |
| `method` | nein | `tar` (Standard) oder `rsync` |
| `keep_days` | nein | Alte Backups löschen, die älter als N Tage sind |
| `keep_count` | nein | Nur die neuesten N Backups behalten |
| `enabled` | nein | `true` / `false` – Job ohne Löschen deaktivieren |
| `notify` | nein | `true` / `false` – Benachrichtigung für diesen Job an/aus |
| `exclude` | nein | Liste von Mustern, die vom Backup ausgenommen werden |

Werden `keep_days` und `keep_count` gesetzt, wird beides angewendet (ein Eintrag wird
gelöscht, sobald eine der beiden Bedingungen zutrifft).

### Vollständiges Beispiel

```yaml
notify:
  type: gotify
  url: "https://gotify.example.com"
  token_file: "/etc/autobackup/gotify.token"
  title: "Autobackup"
  notify_on_error: true

log_file: "/var/log/autobackup.log"

backups:
  - name: "appdata"
    source: "/docker/container/appdata"
    destination: "/backup/container/appdata"
    method: "tar"
    keep_days: 7
    keep_count: 5

  - name: "database"
    source: "/docker/container/mysql"
    destination: "/backup/container/mysql"
    method: "rsync"
    keep_count: 10
    exclude:
      - "*.tmp"
      - "tmp/*"

  - name: "beispiel-deaktiviert"
    source: "/docker/container/beispiel"
    destination: "/backup/container/beispiel"
    method: "tar"
    enabled: false
```

## Cron-Job

Die zeitliche Steuerung übernimmt der Cron-Daemon. Beispiel: täglich um 02:30 Uhr.

```cron
30 2 * * * /usr/local/bin/autobackup /etc/autobackup/backup.yml >> /var/log/autobackup-cron.log 2>&1
```

Als root einrichten:

```bash
sudo crontab -e
```

Weitere Beispiele:

```cron
# jede Stunde
0 * * * * /usr/local/bin/autobackup /etc/autobackup/backup.yml >> /var/log/autobackup-cron.log 2>&1

# wöchentlich sonntags 03:00
0 3 * * 0 /usr/local/bin/autobackup /etc/autobackup/backup.yml >> /var/log/autobackup-cron.log 2>&1
```

> Tipp: Ein separates Backup-Ziel und eine ausreichend große Rotation halten die
> Laufzeit kurz. Bei mehreren/n-großen Pfaden reicht ein täglicher oder wöchentlicher
> Lauf locker.

## Gotify einrichten

1. Gotify installieren und starten (z. B. als Docker-Container).
2. In der Web-Oberfläche eine **App** anlegen und das **App-Token** kopieren.
3. Token in die separate Datei schreiben (siehe Installation, Schritt 3).
4. `notify.url` in `backup.yml` auf die Gotify-Basis-URL setzen.

Wichtige Hinweise zum Token:

- Gehört **nicht** in `backup.yml` (würde ins Git gelangen).
- Datei nur für root lesbar: `sudo chmod 600 /etc/autobackup/gotify.token`

## Webhook verwenden

Statt Gotify kann ein beliebiger Endpunkt per `POST` angesprochen werden. Die URL wird
mit einem JSON-Payload `{"title": "…", "message": "…"}` aufgerufen.

```yaml
notify:
  type: webhook
  url: "https://example.com/dein-webhook"
```

Das Script wertet den HTTP-Status aus: `2xx` gilt als Erfolg.

## Backup-Methoden im Detail

### tar

Erzeugt pro Lauf eine Archiv-Datei:

```
/backup/container/appdata/appdata_20260101_023001.tar.gz
```

Das Archiv wird mit `gzip` komprimiert. Exclude-Muster werden an `tar` durchgereicht
(z. B. `--exclude '*.tmp'`). Es handelt sich um **Vollbackups** – jede Datei landet
komprimiert im Archiv, Speicherbedarf kann hoch sein. Für Speicher sparen mit
Vollständigkeit der Daten besser geeignet ist die rsync-Methode.

### rsync

Erzeugt pro Lauf ein timestampiertes Verzeichnis:

```
/backup/container/mysql/mysql_20260101_023001/
```

Identische Dateien werden dank `--link-dest` als **Hardlinks** auf den vorherigen Lauf
verwiesen – unveränderte Daten brauchen also keinen neuen Speicherplatz, aber jedes
Verzeichnis wirkt wie ein vollständiges Backup. Der Quellpfad wird mit `--delete`
gespiegelt, Excludes werden durchgereicht.

> Hinweis: `--link-dest` funktioniert nur innerhalb desselben Dateisystems. Das
> Zielverzeichnis sollte daher auf einem einzigen Mount liegen.

## Rotation

Die Rotation läuft **nach jedem erfolgreichen Backup** ab:

- **`keep_days`**: löscht Einträge älter als N × 24 Stunden (basierend auf dem
  Dateidatum/mtime; GNU `find -mtime`).
- **`keep_count`**: behält nur die neuesten N Einträge (anhand des Zeitstempels im Namen).

```yaml
# Beispiel: 7 Tage oder 7 Backups – was zuerst greift
keep_days: 7
keep_count: 7
```

## Troubleshooting

| Problem | Lösung |
|---|---|
| `Konfigurationsdatei nicht gefunden` | Pfad prüfen bzw. vollständigen Pfad in Cron angeben |
| `FATAL: Es läuft bereits eine Autobackup-Instanz` | Vorheriger Lauf läuft noch (Lock-Datei `/tmp/autobackup.lock`); kurz warten |
| Benachrichtigung wird nicht gesendet | `curl` installieren, `notify.url` prüfen, Token-Datei prüfen |
| `curl: command not found` | `sudo apt install curl` |
| Gotify meldet `401` | Token falsch oder Token-Datei mit Leerzeichen/Zeilenumbruch gespeichert |
| `rsync … "--link-dest" … »not a hard link«` | Warnung bei ersten Läufen; unkritisch, es wird kopiert statt verlinkt |
| Backups fehlen bei Rotation | Namen prüfen – jeder Job braucht einen **eindeutigen** Namen ohne `/` |

## Sicherheitshinweise & Regeln

- **Ziel nie innerhalb der Quelle** platzieren – das Script verweigert den Lauf, um
  Endlosschleifen zu verhindern.
- **Eindeutige Namen** pro Job verwenden; Namen ungliche Werte wie `/` vermeiden.
- Konfiguration und Token-Datei mit `chmod 600` vor Zugriffen durch andere Benutzer
  schützen.
- Werte mit Sonderzeichen (`#`, Leerzeichen, `:`) in **Anführungszeichen** setzen.
- Natürlich zu Testzwecken einmal manuell starten: `sudo autobackup /etc/autobackup/backup.yml`.

## Beispiel-Ablauf nach Erfolg

```
===== Autobackup gestartet (2026-01-01 02:30:01) =====
Konfiguration: /etc/autobackup/backup.yml  |  Jobs: 2
OK   appdata: /backup/container/appdata/appdata_20260101_023001.tar.gz (1,2G)
Benachrichtigung gesendet (HTTP 200)
OK   database: /backup/container/mysql/mysql_20260101_023001 (800M)
Benachrichtigung gesendet (HTTP 200)
===== Autobackup erfolgreich beendet =====
```

## Lizenz

MIT