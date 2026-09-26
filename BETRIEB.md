# Betrieb — Die Datenlage

Kurzanleitung für den laufenden Betrieb des Servers hinter
[diedatenlage.de](https://diedatenlage.de). Alles wird mit `setup.sh`
eingerichtet; dieses Dokument erklärt den Alltag danach.

## Überblick — was läuft wo

| Komponente            | Ort / Befehl                                  |
|-----------------------|-----------------------------------------------|
| Anwendung (server.js) | `/opt/datenlage`, läuft als Benutzer `datenlage` |
| Dienst                | systemd-Unit `datenlage.service`, lauscht auf `127.0.0.1:8080` |
| Umgebungsvariablen    | `/etc/datenlage.env`                          |
| Reverse Proxy + TLS   | Caddy, Konfiguration in `/etc/caddy/Caddyfile` |
| Firewall              | `ufw` — eingehend nur 22, 80, 443             |
| Auto-Updates          | `unattended-upgrades`                         |
| Backup (optional)     | `restic` via `datenlage-backup.timer` → NAS   |

Anfragen laufen so: **Internet → Caddy (443, TLS) → 127.0.0.1:8080 (server.js)**.

---

## Setup ausführen / wiederholen

Das Skript ist idempotent — du kannst es jederzeit erneut ausführen, es prüft
bei jedem Schritt, ob etwas zu tun ist.

```bash
sudo ./setup.sh
```

Ganz am Ende läuft eine **Prüfroutine**, die meldet, ob Dienst und Caddy
laufen, das Zertifikat gültig ist und `/api/state` antwortet. Diese Prüfung
kannst du jederzeit erneut anstoßen, indem du `setup.sh` nochmal startest.

> **Hinweis zur SSH-Härtung:** Nach dem ersten Lauf ist Passwort-Login
> abgeschaltet und root nur noch per Key erreichbar. Öffne unbedingt eine
> **neue** SSH-Sitzung mit deinem Key und prüfe, dass du hineinkommst, bevor
> du die alte Sitzung schließt.

---

## Logs ansehen

```bash
# Live-Log des Dienstes
sudo journalctl -u datenlage -f

# Die letzten 200 Zeilen
sudo journalctl -u datenlage -n 200 --no-pager

# Nur seit dem letzten Start
sudo journalctl -u datenlage -b

# Caddy (TLS-Ausstellung, HTTP-Fehler, Proxy)
sudo journalctl -u caddy -f
```

---

## Dienst steuern

```bash
sudo systemctl status datenlage      # Status ansehen
sudo systemctl restart datenlage     # neu starten
sudo systemctl stop datenlage        # anhalten
sudo systemctl start datenlage       # starten
```

Der Dienst startet dank `Restart=always` nach einem Absturz automatisch neu
und kommt nach einem Reboot von selbst hoch (`enable` ist gesetzt).

---

## Neue Version einspielen

Der Code wird **nicht** vom Skript geklont — du kopierst `server.js` und
`public/` selbst nach `/opt/datenlage`.

```bash
# 1. Neue Dateien auf den Server bringen (Beispiel mit rsync)
rsync -av --delete ./ root@diedatenlage.de:/opt/datenlage/

# 2. Eigentümer korrigieren (rsync als root legt Dateien als root an)
sudo chown -R datenlage:datenlage /opt/datenlage

# 3. Dienst neu starten
sudo systemctl restart datenlage

# 4. Prüfen
curl -fsS http://127.0.0.1:8080/api/state | head
sudo systemctl status datenlage
```

Statt Schritt 2+3 kannst du auch einfach `sudo ./setup.sh` erneut laufen
lassen — das setzt Rechte und startet den Dienst mit.

---

## Konfiguration ändern

### Umgebungsvariablen (`/etc/datenlage.env`)

```bash
sudo nano /etc/datenlage.env
sudo systemctl restart datenlage   # Änderungen werden erst beim Neustart aktiv
```

### Caddy / Domain (`/etc/caddy/Caddyfile`)

```bash
sudo nano /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile   # erst prüfen
sudo systemctl reload caddy                    # ohne Ausfall neu laden
```

---

## Zertifikat prüfen

Caddy holt und erneuert das Let's-Encrypt-Zertifikat automatisch. Manuell
kontrollieren:

```bash
echo | openssl s_client -connect diedatenlage.de:443 -servername diedatenlage.de 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

Falls direkt nach dem Setup noch kein Zertifikat da ist: ein paar Minuten
warten (DNS + ACME) und erneut prüfen. Fehlerursachen stehen im Caddy-Log
(`journalctl -u caddy`).

---

## Firewall & SSH

```bash
sudo ufw status verbose        # aktive Regeln ansehen
```

Eingehend sind nur 22, 80 und 443 offen. Die SSH-Härtung liegt in
`/etc/ssh/sshd_config.d/00-datenlage-haertung.conf` (Passwort-Login aus,
root nur per Key). Nach Änderungen: `sudo sshd -t && sudo systemctl reload ssh`.

---

## Backup (restic → NAS)

Das Backup ist im Skript vollständig vorbereitet, aber **standardmäßig
deaktiviert** (`BACKUP_AKTIV="nein"`), weil der Zugang vom Server zum NAS im
Heimnetz noch eingerichtet werden muss.

### Aktivieren (einmalig)

1. **Zugang zum NAS herstellen.** Der Hetzner-Server muss das NAS erreichen —
   ein NAS hinter dem Heimrouter ist von außen normalerweise nicht direkt
   erreichbar. Übliche Wege: ein VPN (z.B. WireGuard/Tailscale) zwischen
   Server und NAS, oder eine Portweiterleitung/DynDNS am Router. Dieser Teil
   liegt außerhalb von `setup.sh`.

2. **SSH-Key des Servers auf dem NAS hinterlegen.** Das Backup läuft als root
   und schiebt per SSH aufs NAS:

   ```bash
   sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
   sudo cat /root/.ssh/id_ed25519.pub   # diesen Key in die authorized_keys des NAS eintragen
   # Host-Key des NAS einmalig bestätigen (verhindert späteres Hängen):
   sudo ssh <nas-benutzer>@<nas-adresse> exit
   ```

3. **restic-Passwort setzen** (sicher aufbewahren — ohne geht keine
   Wiederherstellung!):

   ```bash
   sudo bash -c 'umask 077; printf "%s\n" "EIN-STARKES-PASSWORT" > /etc/datenlage-restic.pass'
   ```

4. **Variablen oben in `setup.sh` setzen** und Skript erneut ausführen:

   ```bash
   BACKUP_AKTIV="ja"
   RESTIC_REPO="sftp:<nas-benutzer>@<nas-adresse>:/pfad/zu/backups/datenlage"
   # ggf. BACKUP_ZEIT anpassen
   ```
   ```bash
   sudo ./setup.sh
   ```

Das Skript installiert dann restic, initialisiert das Repository beim ersten
Lauf, legt einen täglichen Timer an und sichert `/opt/datenlage`,
`/etc/datenlage.env` und `/etc/caddy/Caddyfile`. Aufbewahrung: 7 täglich,
4 wöchentlich, 6 monatlich.

### Status & manueller Lauf

```bash
systemctl list-timers datenlage-backup.timer      # nächster Lauf
sudo systemctl start datenlage-backup.service      # sofortiges Backup
sudo journalctl -u datenlage-backup.service -f     # Log ansehen
```

### Snapshots ansehen

```bash
sudo bash -c 'set -a; . /etc/datenlage-backup.env; set +a; restic snapshots'
```

### Backup zurückholen (Restore)

```bash
# Hilfsvariablen laden (Repo + Passwortdatei)
sudo -i
set -a; . /etc/datenlage-backup.env; set +a

# 1. Verfügbare Snapshots auflisten
restic snapshots

# 2. Testweise in ein separates Verzeichnis zurückholen (nichts überschreiben)
restic restore latest --target /root/restore-test

# 3. Inhalt prüfen, dann gezielt zurückkopieren, z.B. die Anwendung:
rsync -av /root/restore-test/opt/datenlage/ /opt/datenlage/
chown -R datenlage:datenlage /opt/datenlage
systemctl restart datenlage
```

> Einzelne Dateien statt allem: `restic restore latest --target /root/restore-test --include /etc/datenlage.env`

---

## Prüfroutine / Schnellcheck

```bash
# Kompletter Check inkl. Zertifikat (läuft am Ende von setup.sh):
sudo ./setup.sh

# Oder von Hand:
systemctl is-active datenlage caddy
curl -fsS http://127.0.0.1:8080/api/state | head
curl -fsS https://diedatenlage.de/api/state | head
```

---

## Fehlersuche

| Symptom                                   | Erste Schritte |
|-------------------------------------------|----------------|
| Dienst läuft nicht                        | `journalctl -u datenlage -e` — meist Fehler in server.js oder falscher `PORT` in `/etc/datenlage.env` |
| Seite nicht per HTTPS erreichbar          | `journalctl -u caddy -e`; DNS prüfen (`dig diedatenlage.de`); Ports 80/443 offen? (`ufw status`) |
| Kein Zertifikat                           | DNS muss auf den Server zeigen und 80/443 erreichbar sein; Caddy-Log ansehen |
| `502` von Caddy                           | Anwendung antwortet nicht auf `127.0.0.1:8080` — Dienst-Status prüfen |
| Nach SSH-Härtung kein Login               | Über die Hetzner-Cloud-Console (Web) anmelden und `/root/.ssh/authorized_keys` bzw. die sshd-Konfiguration prüfen |
| Backup schlägt fehl                       | `journalctl -u datenlage-backup.service -e`; NAS erreichbar? Host-Key bestätigt? Passwortdatei vorhanden? |
