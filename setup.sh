#!/usr/bin/env bash
#
# setup.sh — Server-Setup für "Die Datenlage" (diedatenlage.de)
#
# Bringt einen frischen Ubuntu-26.04-Server (Hetzner CX23) idempotent in den
# Zielzustand: App-Benutzer, SSH-Härtung, Firewall, automatische
# Sicherheitsupdates, Node.js, Caddy (Reverse Proxy + Let's Encrypt),
# systemd-Dienst und — optional, standardmäßig deaktiviert — restic-Backup
# auf ein NAS.
#
# Aufruf:            sudo ./setup.sh
# Mehrfach ausführbar: Jeder Schritt prüft erst, ob er nötig ist, und
#                     überschreibt nichts blind.
#
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ═════════════════════════════════════════════════════════════════════════
#  KONFIGURATION — hier anpassen
# ═════════════════════════════════════════════════════════════════════════

# Domain, für die Caddy automatisch ein Let's-Encrypt-Zertifikat holt.
DOMAIN="diedatenlage.de"

# Kontakt-E-Mail für Let's-Encrypt-Ablaufwarnungen.
# Leer lassen = ohne Kontaktadresse (funktioniert, nur ohne Benachrichtigung).
LE_EMAIL=""

# www.<DOMAIN> mitbedienen? "ja" = Caddy holt auch für www ein Zertifikat und
# leitet www dauerhaft (301) auf DOMAIN um. "nein" = nur DOMAIN.
# Voraussetzung: ein passender DNS-Eintrag (A/AAAA) für www zeigt auf den Server.
MIT_WWW="ja"

# Systembenutzer/-gruppe, unter denen der Dienst läuft (ohne Login-Shell).
APP_USER="datenlage"
APP_GROUP="datenlage"

# Verzeichnis der Anwendung. server.js und public/ musst du selbst hierher
# kopieren (z.B. per scp/rsync) — das Skript klont nichts.
APP_DIR="/opt/datenlage"

# Port, auf dem server.js lauscht; Caddy leitet auf 127.0.0.1:<APP_PORT> weiter.
APP_PORT="8080"

# Umgebungsdatei für den Dienst (wird von systemd via EnvironmentFile geladen).
ENV_FILE="/etc/datenlage.env"

# ── Backup (restic → NAS) ────────────────────────────────────────────────
# ERSTMAL AUSGELASSEN: Solange BACKUP_AKTIV nicht "ja" ist, rührt das Skript
# nichts Backup-bezogenes an (kein restic, kein Timer). Wenn dein Zugang zum
# NAS steht (z.B. per VPN), hier "ja" setzen, die Variablen darunter füllen
# und setup.sh erneut ausführen. Details siehe BETRIEB.md.
BACKUP_AKTIV="nein"

# restic-Repository auf dem NAS (Push-Richtung Server → NAS).
# Standard-Backend ist SFTP über SSH, z.B.:
#   sftp:BENUTZER@nas.example.intern:/volume1/backups/datenlage
# Das ist der "Repo-Pfad" / das "NAS-Ziel".
RESTIC_REPO=""

# Datei mit dem restic-Repository-Passwort (nur für root lesbar).
# Ohne dieses Passwort sind Backups NICHT wiederherstellbar — sicher aufbewahren!
RESTIC_PASS_FILE="/etc/datenlage-restic.pass"

# Uhrzeit des täglichen Backups (HH:MM, lokale Serverzeit).
BACKUP_ZEIT="03:30"

# Was gesichert wird: Konfiguration + Anwendungsdaten. Pfade ohne Leerzeichen.
BACKUP_PFADE=("${APP_DIR}" "${ENV_FILE}" "/etc/caddy/Caddyfile")

# ═════════════════════════════════════════════════════════════════════════
#  Ab hier ist normalerweise nichts mehr anzupassen.
# ═════════════════════════════════════════════════════════════════════════

# ── Ausgabe-Helfer (farbig, wenn Terminal) ───────────────────────────────
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_RST=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_RST=""
fi
log()  { printf '%s[..]%s %s\n' "$C_INFO" "$C_RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_OK"   "$C_RST" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_WARN" "$C_RST" "$*" >&2; }
err()  { printf '%s[XX]%s %s\n' "$C_ERR"  "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Bei einem unerwarteten Fehler die Zeile melden (saubere Fehlermeldung).
trap 'err "Unerwarteter Abbruch in Zeile ${LINENO} (Exit-Code $?)."' ERR

# Voller Pfad zum Node-Binary; wird in schritt_node ermittelt (node oder nodejs).
NODE_BIN=""

# ── Kleine Werkzeuge ──────────────────────────────────────────────────────
require_root() {
  [[ ${EUID} -eq 0 ]] || die "Bitte als root ausführen, z.B.: sudo ./setup.sh"
}

APT_AKTUALISIERT=0
apt_update() {
  # Paketlisten nur einmal pro Lauf aktualisieren.
  if [[ ${APT_AKTUALISIERT} -eq 0 ]]; then
    log "Aktualisiere Paketlisten ..."
    apt-get update -qq
    APT_AKTUALISIERT=1
  fi
}

ensure_pkg() {
  # Installiert nur, was noch fehlt.
  local pkg
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      ok "Paket '$pkg' bereits installiert."
    else
      apt_update
      log "Installiere Paket '$pkg' ..."
      apt-get install -y -qq "$pkg"
      ok "Paket '$pkg' installiert."
    fi
  done
}

# Schreibt Inhalt nur, wenn die Zieldatei fehlt oder abweicht (idempotent).
# Rückgabe 0 = geändert, 1 = unverändert.
datei_schreiben() {
  local ziel="$1" inhalt="$2"
  if [[ -f "$ziel" && "$(cat "$ziel")" == "$inhalt" ]]; then
    return 1
  fi
  printf '%s\n' "$inhalt" > "$ziel"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════
#  1. Grundpakete
# ═════════════════════════════════════════════════════════════════════════
schritt_grundpakete() {
  log "Prüfe Grundpakete ..."
  ensure_pkg ca-certificates curl gnupg openssl
}

# ═════════════════════════════════════════════════════════════════════════
#  2. Automatische Sicherheitsupdates
# ═════════════════════════════════════════════════════════════════════════
schritt_unattended_upgrades() {
  log "Prüfe automatische Sicherheitsupdates ..."
  ensure_pkg unattended-upgrades
  local cfg="/etc/apt/apt.conf.d/20auto-upgrades"
  local inhalt='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
  if datei_schreiben "$cfg" "$inhalt"; then
    ok "Automatische Sicherheitsupdates aktiviert ($cfg)."
  else
    ok "Automatische Sicherheitsupdates bereits aktiv."
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  3. Node.js aus den Ubuntu-Paketquellen (Abbruch bei Version < 20)
# ═════════════════════════════════════════════════════════════════════════
schritt_node() {
  log "Prüfe Node.js ..."
  if ! command -v node >/dev/null 2>&1 && ! command -v nodejs >/dev/null 2>&1; then
    ensure_pkg nodejs
  fi
  # Das Ubuntu-Paket installiert das Binary je nach Version als 'node' oder 'nodejs'.
  if command -v node >/dev/null 2>&1; then
    NODE_BIN="$(command -v node)"
  elif command -v nodejs >/dev/null 2>&1; then
    NODE_BIN="$(command -v nodejs)"
  else
    die "Node-Binary nach der Installation nicht gefunden (weder 'node' noch 'nodejs')."
  fi
  local ver major
  ver="$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//')" \
    || die "$NODE_BIN ist nicht ausführbar."
  major="${ver%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || die "Node-Version nicht erkennbar ('$ver')."
  if (( major < 20 )); then
    die "Node.js $ver ist zu alt (benötigt wird >= 20).
     In den Paketquellen dieser Ubuntu-Version ist Node zu alt. Bitte ein
     neueres Ubuntu verwenden oder Node aus einer aktuelleren Quelle
     installieren, dann setup.sh erneut ausführen."
  fi
  ok "Node.js $ver ($NODE_BIN) erfüllt die Anforderung (>= 20)."
}

# ═════════════════════════════════════════════════════════════════════════
#  4. Systembenutzer ohne Login-Shell
# ═════════════════════════════════════════════════════════════════════════
schritt_benutzer() {
  log "Prüfe Systembenutzer '$APP_USER' ..."
  if getent group "$APP_GROUP" >/dev/null; then
    ok "Gruppe '$APP_GROUP' existiert."
  else
    groupadd --system "$APP_GROUP"
    ok "Gruppe '$APP_GROUP' angelegt."
  fi
  if id "$APP_USER" >/dev/null 2>&1; then
    ok "Benutzer '$APP_USER' existiert."
  else
    useradd --system --gid "$APP_GROUP" --home-dir "$APP_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$APP_USER"
    ok "Benutzer '$APP_USER' angelegt (keine Login-Shell)."
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  5. Anwendungsverzeichnis (Code kopierst du selbst hinein)
# ═════════════════════════════════════════════════════════════════════════
schritt_app_verzeichnis() {
  log "Prüfe Anwendungsverzeichnis '$APP_DIR' ..."
  if [[ -d "$APP_DIR" ]]; then
    ok "Verzeichnis '$APP_DIR' existiert."
  else
    mkdir -p "$APP_DIR"
    ok "Verzeichnis '$APP_DIR' angelegt."
  fi
  # Eigentümer/Rechte idempotent setzen, damit du als App-User hineinkopieren
  # kannst und der Dienst lesen/schreiben darf.
  chown -R "$APP_USER":"$APP_GROUP" "$APP_DIR"
  chmod 0755 "$APP_DIR"
  ok "Eigentümer/Rechte auf '$APP_DIR' gesetzt."
}

# ═════════════════════════════════════════════════════════════════════════
#  6. Umgebungsdatei /etc/datenlage.env
# ═════════════════════════════════════════════════════════════════════════
schritt_env_datei() {
  log "Prüfe Umgebungsdatei '$ENV_FILE' ..."
  if [[ -f "$ENV_FILE" ]]; then
    ok "Umgebungsdatei existiert bereits (wird nicht überschrieben)."
  else
    cat > "$ENV_FILE" <<EOF
# Umgebungsvariablen für den Dienst "datenlage".
# Wird von systemd via EnvironmentFile eingelesen. Hier kannst du weitere
# Werte ergänzen (z.B. API-Tokens); nach Änderungen: systemctl restart datenlage
NODE_ENV=production
PORT=${APP_PORT}
EOF
    ok "Umgebungsdatei '$ENV_FILE' erstellt."
  fi
  # Rechte immer absichern: root:datenlage, nicht welt-lesbar (könnte Secrets halten).
  chown root:"$APP_GROUP" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
}

# ═════════════════════════════════════════════════════════════════════════
#  7. Caddy (Reverse Proxy + automatisches Let's-Encrypt-Zertifikat)
# ═════════════════════════════════════════════════════════════════════════
schritt_caddy() {
  log "Prüfe Caddy ..."
  if ! command -v caddy >/dev/null 2>&1; then
    log "Installiere Caddy aus dem offiziellen Repository ..."
    ensure_pkg debian-keyring debian-archive-keyring apt-transport-https
    # Signierschlüssel hinterlegen (nur falls noch nicht vorhanden).
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi
    # Paketquelle eintragen (nur falls noch nicht vorhanden).
    if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    fi
    apt-get update -qq
    ensure_pkg caddy
  else
    ok "Caddy bereits installiert ($(caddy version 2>/dev/null | head -n1))."
  fi

  # Caddyfile zusammenbauen (globaler E-Mail-Block nur, wenn LE_EMAIL gesetzt).
  local caddyfile="/etc/caddy/Caddyfile"
  local inhalt=""
  if [[ -n "$LE_EMAIL" ]]; then
    inhalt+="{"$'\n'"    email ${LE_EMAIL}"$'\n'"}"$'\n\n'
  fi
  inhalt+="${DOMAIN} {"$'\n'
  inhalt+="    encode zstd gzip"$'\n'
  inhalt+="    reverse_proxy 127.0.0.1:${APP_PORT}"$'\n'
  inhalt+="}"
  # Optional: www dauerhaft auf die Hauptdomain umleiten (Caddy zieht dafür
  # automatisch ein eigenes Zertifikat). {uri} ist ein Caddy-Platzhalter.
  if [[ "${MIT_WWW,,}" == "ja" ]]; then
    inhalt+=$'\n\n'"www.${DOMAIN} {"$'\n'
    inhalt+="    redir https://${DOMAIN}{uri} permanent"$'\n'
    inhalt+="}"
  fi

  mkdir -p /etc/caddy
  if datei_schreiben "$caddyfile" "$inhalt"; then
    ok "Caddyfile geschrieben ($caddyfile)."
  else
    ok "Caddyfile ist bereits aktuell."
  fi

  systemctl enable caddy >/dev/null 2>&1 || true
  # Konfiguration prüfen, bevor neu geladen wird.
  if ! caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1; then
    die "Caddyfile ist ungültig. Prüfen mit: caddy validate --config $caddyfile"
  fi
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
    ok "Caddy neu geladen (Konfiguration aktiv)."
  else
    systemctl start caddy
    ok "Caddy gestartet."
  fi
}

# ═════════════════════════════════════════════════════════════════════════
#  8. Firewall (ufw): eingehend nur 22, 80, 443
# ═════════════════════════════════════════════════════════════════════════
schritt_firewall() {
  log "Prüfe Firewall (ufw) ..."
  ensure_pkg ufw
  # Standardrichtlinien und erlaubte Ports (ufw-Regeln sind idempotent).
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp   >/dev/null   # SSH — zuerst erlauben, damit kein Aussperren
  ufw allow 80/tcp   >/dev/null   # HTTP (Let's-Encrypt-Challenge, Weiterleitung)
  ufw allow 443/tcp  >/dev/null   # HTTPS
  if ufw status | grep -q "Status: active"; then
    ok "ufw bereits aktiv."
  else
    ufw --force enable >/dev/null  # --force: keine interaktive Rückfrage
    ok "ufw aktiviert."
  fi
  ok "Eingehend erlaubt: 22, 80, 443 — alles andere wird verworfen."
}

# ═════════════════════════════════════════════════════════════════════════
#  9. SSH härten: nur Key-Auth, kein Passwort, root nur per Key
# ═════════════════════════════════════════════════════════════════════════
schritt_ssh_haerten() {
  log "Prüfe SSH-Härtung ..."

  # Schutz vor dem Aussperren: root muss mindestens einen SSH-Key haben,
  # sonst gäbe es nach dem Abschalten der Passwort-Anmeldung keinen Login mehr.
  local rk="/root/.ssh/authorized_keys"
  if [[ ! -s "$rk" ]] || ! grep -Eq 'ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-' "$rk"; then
    die "Kein SSH-Key für root gefunden ($rk).
     Zum Schutz vor dem Aussperren wird NICHT gehärtet.
     Bitte zuerst deinen öffentlichen Key hinterlegen, z.B.:
       mkdir -p /root/.ssh && chmod 700 /root/.ssh
       echo 'ssh-ed25519 AAAA... dein-key' >> $rk && chmod 600 $rk
     Danach setup.sh erneut ausführen."
  fi

  # Härtung als Drop-in. Präfix 00- sorgt dafür, dass diese Werte VOR den
  # Cloud-Init-Defaults (50-cloud-init.conf) gelesen werden — sshd nimmt für
  # die meisten Optionen den ersten gefundenen Wert.
  local drop="/etc/ssh/sshd_config.d/00-datenlage-haertung.conf"
  local inhalt='# Von setup.sh verwaltet — SSH-Härtung für "Die Datenlage".
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes'

  mkdir -p /etc/ssh/sshd_config.d
  if datei_schreiben "$drop" "$inhalt"; then
    chmod 0644 "$drop"
    ok "SSH-Härtung geschrieben ($drop)."
  else
    ok "SSH-Härtung bereits gesetzt."
  fi

  # Konfiguration testen, bevor neu geladen wird.
  sshd -t 2>/dev/null || die "sshd-Konfiguration fehlerhaft — Reload abgebrochen (Test: sshd -t)."

  # Sanft neu laden (bestehende Sitzungen bleiben bestehen).
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
    ok "sshd neu geladen."
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
    ok "sshd neu geladen."
  else
    ok "sshd ist socket-aktiviert — Konfiguration greift bei der nächsten Verbindung."
  fi

  ok "SSH-Härtung aktiv: nur Key-Auth, kein Passwort-Login, root nur per Key."
  warn "WICHTIG: Öffne JETZT parallel eine NEUE SSH-Sitzung mit deinem Key und"
  warn "         prüfe, dass du hineinkommst, BEVOR du diese Sitzung schließt."
}

# ═════════════════════════════════════════════════════════════════════════
# 10. systemd-Dienst für die Anwendung
# ═════════════════════════════════════════════════════════════════════════
schritt_systemd_dienst() {
  log "Prüfe systemd-Dienst 'datenlage' ..."

  # Anwendungscode muss vorhanden sein (du kopierst server.js/public/ selbst).
  if [[ ! -f "$APP_DIR/server.js" ]]; then
    die "server.js fehlt in $APP_DIR.
     Bitte den Anwendungscode dorthin kopieren, z.B.:
       rsync -av ./ root@<server>:$APP_DIR/
     und setup.sh danach erneut ausführen. (Alle übrigen Schritte sind bereits
     eingerichtet — dieser Lauf hat nur den Dienst-Start ausgelassen.)"
  fi

  local unit="/etc/systemd/system/datenlage.service"
  # NODE_BIN wurde in schritt_node ermittelt.
  [[ -n "$NODE_BIN" ]] || NODE_BIN="$(command -v node || command -v nodejs)"
  local inhalt
  inhalt="$(cat <<EOF
[Unit]
Description=Die Datenlage — Datendienst (server.js)
Documentation=https://${DOMAIN}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${APP_DIR}/server.js
Restart=always
RestartSec=5

# ── Härtung ──
NoNewPrivileges=yes
ProtectSystem=strict
# Anwendung darf nur in ihr eigenes Verzeichnis schreiben. Schreibt server.js
# woanders hin, hier den Pfad ergänzen.
ReadWritePaths=${APP_DIR}
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
)"

  local geaendert=0
  if datei_schreiben "$unit" "$inhalt"; then
    systemctl daemon-reload
    geaendert=1
    ok "Unit-Datei geschrieben ($unit)."
  else
    ok "Unit-Datei ist bereits aktuell."
  fi

  systemctl enable datenlage >/dev/null 2>&1 || true
  if [[ $geaendert -eq 1 ]] || ! systemctl is-active --quiet datenlage; then
    systemctl restart datenlage
    ok "Dienst 'datenlage' gestartet."
  else
    ok "Dienst 'datenlage' läuft bereits."
  fi
}

# ═════════════════════════════════════════════════════════════════════════
# 11. Backup per restic auf das NAS (standardmäßig deaktiviert)
# ═════════════════════════════════════════════════════════════════════════
schritt_backup() {
  if [[ "${BACKUP_AKTIV,,}" != "ja" ]]; then
    ok "Backup übersprungen (BACKUP_AKTIV=\"$BACKUP_AKTIV\"). Aktivieren: siehe BETRIEB.md."
    return 0
  fi

  log "Richte restic-Backup (Server → NAS) ein ..."
  [[ -n "$RESTIC_REPO" ]] || die "RESTIC_REPO ist leer — bitte NAS-Ziel/Repo-Pfad oben eintragen."
  if [[ ! -f "$RESTIC_PASS_FILE" ]]; then
    die "Passwortdatei $RESTIC_PASS_FILE fehlt.
     Einmalig ein starkes Passwort setzen (und sicher aufbewahren!):
       umask 077; printf '%s\\n' 'DEIN-RESTIC-PASSWORT' > $RESTIC_PASS_FILE
     Ohne dieses Passwort sind die Backups nicht wiederherstellbar."
  fi
  ensure_pkg restic
  chown root:root "$RESTIC_PASS_FILE"; chmod 600 "$RESTIC_PASS_FILE"

  # Backup-Umgebung (Repo + Passwortdatei + Pfade). Quoting für die Pfade,
  # damit die Datei sowohl von systemd als auch beim Sourcen in bash passt.
  local benv="/etc/datenlage-backup.env"
  local pfade="${BACKUP_PFADE[*]}"
  local benv_inhalt
  benv_inhalt="$(cat <<EOF
# Von setup.sh verwaltet — Konfiguration des restic-Backups.
RESTIC_REPOSITORY=${RESTIC_REPO}
RESTIC_PASSWORD_FILE=${RESTIC_PASS_FILE}
BACKUP_PATHS="${pfade}"
EOF
)"
  if datei_schreiben "$benv" "$benv_inhalt"; then
    ok "Backup-Umgebung geschrieben ($benv)."
  else
    ok "Backup-Umgebung bereits aktuell."
  fi
  chown root:root "$benv"; chmod 600 "$benv"

  # Ausführbares Backup-Skript.
  local runner="/usr/local/bin/datenlage-backup.sh"
  local runner_inhalt
  runner_inhalt="$(cat <<'EOF'
#!/usr/bin/env bash
# Von setup.sh erzeugt. Sichert Konfiguration + Anwendungsdaten per restic
# vom Server auf das NAS (Push-Richtung Server → NAS).
set -euo pipefail
if [[ -f /etc/datenlage-backup.env ]]; then
  set -a; . /etc/datenlage-backup.env; set +a
fi
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY nicht gesetzt}"
: "${BACKUP_PATHS:?BACKUP_PATHS nicht gesetzt}"

# Repository bei Bedarf initialisieren (erster Lauf).
if ! restic snapshots >/dev/null 2>&1; then
  echo "restic-Repository wird initialisiert ..."
  restic init
fi

# Backup erstellen (Wortauftrennung von BACKUP_PATHS ist beabsichtigt).
# shellcheck disable=SC2086
restic backup --verbose $BACKUP_PATHS

# Aufräumen: Aufbewahrung begrenzen und alte Daten löschen.
restic forget --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6

# Integrität kurz prüfen.
restic check --read-data-subset=1/10
EOF
)"
  if datei_schreiben "$runner" "$runner_inhalt"; then
    ok "Backup-Skript geschrieben ($runner)."
  else
    ok "Backup-Skript bereits aktuell."
  fi
  chown root:root "$runner"; chmod 0750 "$runner"

  # systemd-Service (oneshot) + Timer (täglich).
  local svc="/etc/systemd/system/datenlage-backup.service"
  local svc_inhalt
  svc_inhalt="$(cat <<EOF
[Unit]
Description=Backup von "Die Datenlage" auf NAS (restic)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=${runner}
EOF
)"
  local tmr="/etc/systemd/system/datenlage-backup.timer"
  local tmr_inhalt
  tmr_inhalt="$(cat <<EOF
[Unit]
Description=Tägliches Backup von "Die Datenlage" auf NAS

[Timer]
OnCalendar=*-*-* ${BACKUP_ZEIT}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
)"

  local geaendert=0
  if datei_schreiben "$svc" "$svc_inhalt"; then geaendert=1; fi
  if datei_schreiben "$tmr" "$tmr_inhalt"; then geaendert=1; fi
  if [[ $geaendert -eq 1 ]]; then
    systemctl daemon-reload
    ok "Backup-Service und -Timer geschrieben."
  else
    ok "Backup-Service und -Timer bereits aktuell."
  fi
  systemctl enable --now datenlage-backup.timer >/dev/null 2>&1 \
    || systemctl enable --now datenlage-backup.timer
  ok "Backup-Timer aktiv (täglich ${BACKUP_ZEIT}). Testlauf: systemctl start datenlage-backup.service"
}

# ═════════════════════════════════════════════════════════════════════════
# 12. Prüfroutine
# ═════════════════════════════════════════════════════════════════════════
pruefroutine() {
  echo
  log "──────── Prüfroutine ────────"
  local fehler=0   # harte Fehler (Dienst/Caddy/lokale API)

  # Dienst läuft?
  if systemctl is-active --quiet datenlage; then
    ok "Dienst 'datenlage' läuft."
  else
    err "Dienst 'datenlage' läuft NICHT — Details: journalctl -u datenlage -e"
    fehler=1
  fi

  # Caddy läuft?
  if systemctl is-active --quiet caddy; then
    ok "Caddy läuft."
  else
    err "Caddy läuft NICHT — Details: journalctl -u caddy -e"
    fehler=1
  fi

  # /api/state lokal erreichbar?
  if curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/api/state" >/dev/null 2>&1; then
    ok "/api/state antwortet lokal (127.0.0.1:${APP_PORT})."
  else
    err "/api/state antwortet lokal NICHT (Port ${APP_PORT})."
    fehler=1
  fi

  # /api/state über die Domain (HTTPS) erreichbar?
  if curl -fsS --max-time 15 "https://${DOMAIN}/api/state" >/dev/null 2>&1; then
    ok "/api/state antwortet über https://${DOMAIN}."
  else
    warn "/api/state über https://${DOMAIN} (noch) nicht erreichbar — bei"
    warn "     frischem Setup können DNS/Zertifikat ein paar Minuten brauchen."
  fi

  # TLS-Zertifikat gültig?
  local enddate
  enddate="$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" || true
  if [[ -n "${enddate:-}" ]]; then
    ok "TLS-Zertifikat für ${DOMAIN} gültig bis: ${enddate}."
  else
    warn "TLS-Zertifikat konnte (noch) nicht geprüft werden — Caddy stellt es evtl. gerade aus."
  fi

  # Backup-Timer (nur wenn aktiviert).
  if [[ "${BACKUP_AKTIV,,}" == "ja" ]]; then
    if systemctl is-active --quiet datenlage-backup.timer; then
      ok "Backup-Timer aktiv."
    else
      err "Backup-Timer NICHT aktiv."
      fehler=1
    fi
  else
    ok "Backup deaktiviert (BACKUP_AKTIV=nein) — kein Timer erwartet."
  fi

  echo
  if [[ $fehler -eq 0 ]]; then
    ok "Kerndienste laufen. Falls HTTPS/Zertifikat oben noch offen waren:"
    ok "kurz warten und die Prüfroutine erneut aufrufen (sudo ./setup.sh)."
  else
    warn "Es gibt offene Punkte (siehe oben)."
  fi
  return 0
}

# ═════════════════════════════════════════════════════════════════════════
#  Hauptablauf
# ═════════════════════════════════════════════════════════════════════════
main() {
  require_root
  log "Setup für \"Die Datenlage\" (${DOMAIN}) startet ..."
  apt_update
  schritt_grundpakete
  schritt_unattended_upgrades
  schritt_node
  schritt_benutzer
  schritt_app_verzeichnis
  schritt_env_datei
  schritt_caddy
  schritt_firewall
  schritt_ssh_haerten
  schritt_systemd_dienst
  schritt_backup
  pruefroutine
  echo
  ok "Setup abgeschlossen."
}

main "$@"
