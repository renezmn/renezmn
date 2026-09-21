# Installation — Hetzner-Server & Domain einrichten

Diese Anleitung bringt dich von „nichts" bis zu dem Punkt, an dem `setup.sh`
läuft: **Server bei Hetzner anlegen → Domain bei INWX auf den Server zeigen
lassen → Code + `setup.sh` einspielen → prüfen.** Danach übernimmt
[`BETRIEB.md`](./BETRIEB.md) den Alltag.

## Reihenfolge (wichtig)

```
1. SSH-Key vorbereiten (lokal)
2. Hetzner-Server anlegen (mit hinterlegtem Key)
3. DNS bei INWX setzen (A + AAAA auf die Server-IPs)   ← VOR setup.sh!
4. Code + setup.sh auf den Server kopieren
5. setup.sh ausführen
6. Prüfen
```

> **Warum DNS zuerst?** Caddy holt beim ersten Lauf automatisch ein
> Let's-Encrypt-Zertifikat. Das klappt nur, wenn `diedatenlage.de` bereits auf
> den Server zeigt und Port 80/443 erreichbar ist. Zeigt die Domain noch
> woanders hin, scheitert die Zertifikatsausstellung (Dienst läuft trotzdem,
> nur ohne gültiges HTTPS).

---

## 1. SSH-Key vorbereiten (auf deinem Rechner)

Der Server wird per Key-Auth eingerichtet — Passwort-Login wird von `setup.sh`
abgeschaltet. Du brauchst also **vorher** einen SSH-Key. Prüfen, ob schon einer
da ist:

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || echo "kein ed25519-Key vorhanden"
```

Falls keiner existiert, einen erzeugen:

```bash
ssh-keygen -t ed25519 -C "diedatenlage"
cat ~/.ssh/id_ed25519.pub    # diesen öffentlichen Key brauchst du gleich bei Hetzner
```

---

## 2. Hetzner-Server anlegen

1. In der [Hetzner Cloud Console](https://console.hetzner.cloud) einloggen,
   Projekt öffnen (oder neu anlegen) → **Add Server**.
2. **Location:** eine Region wählen (z.B. Nürnberg oder Falkenstein).
3. **Image:** **Ubuntu 26.04** auswählen.
   > `setup.sh` verlangt Node ≥ 20 aus den Ubuntu-Paketquellen. Auf älteren
   > Ubuntu-Versionen (z.B. 24.04) ist das Distro-Node zu alt, und das Skript
   > bricht bewusst ab. Deshalb 26.04.
4. **Type:** den vorgesehenen Servertyp **CX23** auswählen.
5. **Networking:** IPv4 **und** IPv6 aktiviert lassen (beides wird für die
   A- und AAAA-Records gebraucht).
6. **SSH Keys:** deinen öffentlichen Key (aus Schritt 1) hinzufügen und
   auswählen. **Das ist entscheidend** — Hetzner legt den Key dann in
   `/root/.ssh/authorized_keys` ab, und genau darauf besteht `setup.sh`
   (Schutz vor dem Aussperren). Ohne hinterlegten Key verweigert das Skript
   die SSH-Härtung.
7. *(Optional)* **Firewalls:** Die Host-Firewall macht `setup.sh` selbst per
   `ufw` (nur 22/80/443). Du kannst zusätzlich eine Hetzner-Cloud-Firewall mit
   denselben Ports als zweite Ebene davorsetzen — nötig ist es nicht.
8. **Create & Buy now.**

Nach dem Anlegen zeigt die Console die **öffentliche IPv4** und **IPv6** des
Servers. Beide notieren — sie kommen gleich in die DNS-Einträge.

```
Server-IPv4:  z.B. 203.0.113.10
Server-IPv6:  z.B. 2a01:4f8:1234:abcd::1
```

---

## 3. Erster SSH-Login (Test)

```bash
ssh root@<Server-IPv4>
```

Beim ersten Mal den Fingerprint mit `yes` bestätigen. Wenn du eine root-Shell
bekommst, passt der Key. (Noch **nichts** härten — das macht `setup.sh`.)
Danach wieder `exit`.

---

## 4. Domain bei INWX auf den Server zeigen lassen

1. Bei [INWX](https://www.inwx.de) einloggen → **Domains** → `diedatenlage.de`
   → **DNS** (bzw. „Nameserver / DNS-Einträge"). Die Domain muss auf den
   INWX-Nameservern liegen (Standard bei INWX-Domains).
2. Folgende Einträge setzen bzw. anpassen:

   | Typ  | Host / Name        | Wert (Ziel)           | TTL   |
   |------|--------------------|-----------------------|-------|
   | A    | `@` (leer = Domain)| `<Server-IPv4>`       | 3600  |
   | AAAA | `@` (leer = Domain)| `<Server-IPv6>`       | 3600  |

   > **Tipp:** Während der Erstinstallation die TTL kurz setzen (z.B. 300),
   > dann sind Korrekturen schneller sichtbar. Später wieder auf 3600 erhöhen.

3. **`www` (optional):** Willst du auch `www.diedatenlage.de`, lege zusätzlich
   an — **und** ergänze die Domain im Caddyfile (siehe Hinweis unten). Ohne
   diesen Schritt bedient der Server nur `diedatenlage.de`.

   | Typ   | Host  | Wert                  | TTL  |
   |-------|-------|-----------------------|------|
   | CNAME | `www` | `diedatenlage.de.`    | 3600 |

   > Das aktuelle Caddyfile aus `setup.sh` deckt **nur** `diedatenlage.de` ab.
   > Für `www` in `/etc/caddy/Caddyfile` die erste Zeile zu
   > `diedatenlage.de, www.diedatenlage.de {` erweitern und
   > `systemctl reload caddy`.

4. Speichern.

### DNS-Ausbreitung prüfen

Auf deinem Rechner:

```bash
dig +short A    diedatenlage.de
dig +short AAAA diedatenlage.de
```

Es müssen die IPs deines Servers erscheinen. Bis das weltweit greift, können
je nach TTL ein paar Minuten (selten Stunden) vergehen. Erst weitermachen,
wenn hier die richtigen IPs kommen.

---

## 5. Code und setup.sh auf den Server bringen

Von deinem Rechner aus (im Verzeichnis mit `server.js`, `public/`, `setup.sh`):

```bash
# Anwendungscode nach /opt/datenlage (rsync legt den Ordner als root an)
rsync -av --delete server.js public/ root@<Server-IPv4>:/opt/datenlage/

# setup.sh separat ins root-Home
scp setup.sh root@<Server-IPv4>:/root/
```

> Reihenfolge egal: Falls du `setup.sh` zuerst ausführst, ohne dass der Code
> da ist, richtet es alles Übrige ein und bricht am Dienst-Start mit einer
> klaren Meldung ab. Dann Code kopieren und `setup.sh` erneut laufen lassen.

---

## 6. setup.sh ausführen

```bash
ssh root@<Server-IPv4>
chmod +x /root/setup.sh
/root/setup.sh          # läuft als root
```

Das Skript arbeitet die Schritte ab und endet mit einer **Prüfroutine**
(Dienst, Caddy, Zertifikat, `/api/state`).

> ⚠️ **Nicht aussperren:** Nach dem Lauf ist Passwort-Login aus und root nur
> noch per Key erreichbar. **Öffne parallel eine zweite SSH-Sitzung mit deinem
> Key und prüfe, dass du hineinkommst, BEVOR du die erste schließt.** Falls
> doch etwas klemmt: die **Hetzner Cloud Console** bietet einen Web-Zugang
> (Konsole) direkt zum Server, unabhängig von SSH.

---

## 7. Prüfen

Auf dem Server:

```bash
systemctl status datenlage caddy
curl -fsS http://127.0.0.1:8080/api/state | head
```

Von deinem Rechner / im Browser:

```bash
curl -fsS https://diedatenlage.de/api/state | head
```
→ und https://diedatenlage.de im Browser öffnen (Schloss-Symbol = Zertifikat ok).

Ab hier gilt [`BETRIEB.md`](./BETRIEB.md): Logs, Neustart, neue Version
einspielen, Backup, Fehlersuche.

---

## Troubleshooting

| Problem | Ursache / Lösung |
|---------|------------------|
| Kein HTTPS / kein Zertifikat | DNS zeigt (noch) nicht auf den Server, oder Port 80/443 nicht erreichbar. `dig` prüfen, Caddy-Log ansehen: `journalctl -u caddy -e`. Nach korrektem DNS ein paar Minuten warten. |
| „server.js fehlt in /opt/datenlage" | Code noch nicht kopiert (Schritt 5). Kopieren, dann `setup.sh` erneut. |
| Node zu alt, Skript bricht ab | Falsches Image — es muss Ubuntu 26.04 sein (Node ≥ 20). |
| Nach Härtung kein SSH mehr | Über die Hetzner Cloud Console (Web-Konsole) anmelden, `/root/.ssh/authorized_keys` bzw. `/etc/ssh/sshd_config.d/00-datenlage-haertung.conf` prüfen. |
| „Kein SSH-Key für root gefunden" | Beim Server-Anlegen war kein Key hinterlegt. Key nach `/root/.ssh/authorized_keys` eintragen, dann `setup.sh` erneut. |
