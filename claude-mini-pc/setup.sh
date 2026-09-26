#!/usr/bin/env bash
# setup.sh – macht einen Mini-PC (Ubuntu/Debian) zur ferngesteuerten
# Claude-Code-Station. Anleitung: README.md in diesem Ordner.
#
#   sudo ./setup.sh [Optionen]        (Optionen: ./setup.sh --help)
#
# Mehrfaches Ausführen ist unbedenklich: Skripte und Dienste werden
# aktualisiert, deine Anpassungen (Einstellungen, CLAUDE.md, SERVERS.md,
# Schlüssel, Anmeldung) bleiben erhalten.

# shellcheck disable=SC1111 # „…“ sind deutsche Anführungszeichen im Text
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=/etc/claude-rc.env
LIB_DIR=/usr/local/lib/claude-rc
UNIT_DIR=/etc/systemd/system
SUDOERS_FILE=/etc/sudoers.d/90-claude-rc
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-claude-rc.conf
APT_DROPIN=/etc/apt/apt.conf.d/52claude-rc

CLAUDE_USER=claude
USER_FROM_FLAG=0
OWNER=""
GITHUB_USER=""
CHANNEL=stable
WITH_SUDO=0
WITH_TAILSCALE=0
WITH_FIREWALL=1
WITH_SSH_HARDENING=1
AUTO_REBOOT=1
ASSUME_YES=0
UNINSTALL=0

if [[ -t 1 ]]; then
  B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'
else
  B="" G="" Y="" R="" N=""
fi
info() { printf '%s\n' "$*"; }
ok() { printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die() {
  printf '%s✘ %s%s\n' "$R" "$*" "$N" >&2
  exit 1
}
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }

usage() {
  cat <<'EOF'
Aufruf: sudo ./setup.sh [Optionen]

  --owner NAME        Dein Vorname für Claudes Arbeitsanweisungen
                      (Standard: aus deinem Benutzerkonto)
  --github BENUTZER   Dein GitHub-Konto – Claude darf in dessen Repos pushen
  --user NAME         Linux-Benutzer, unter dem Claude läuft (Standard: claude)
  --channel KANAL     Update-Kanal von Claude Code: stable (Standard) oder latest
  --sudo              Claude darf auf dem Mini-PC Admin-Befehle ohne Passwort
                      ausführen (Vollzugriff – nur wenn du das wirklich willst)
  --tailscale         Tailscale installieren (SSH-Notfallzugang von unterwegs)
  --no-firewall       Firewall (ufw) nicht einrichten
  --no-ssh-hardening  Passwort- und root-Login per SSH nicht abschalten
  --no-auto-reboot    Nach Sicherheitsupdates nicht automatisch neu starten
  --yes               Keine Rückfragen; Ersteinrichtung danach: claude-rc first-run
  --uninstall         Dienst, Befehle und Systemdateien entfernen
                      (Benutzer, Arbeitsordner und Schlüssel bleiben)
  -h, --help          Diese Hilfe

Beispiel:
  sudo ./setup.sh --owner René --github renezmn --tailscale
EOF
}

need_value() {
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 braucht einen Wert (siehe --help)."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --owner)
        need_value "$@"
        OWNER=$2
        shift 2
        ;;
      --github)
        need_value "$@"
        GITHUB_USER=$2
        shift 2
        ;;
      --user)
        need_value "$@"
        CLAUDE_USER=$2
        USER_FROM_FLAG=1
        shift 2
        ;;
      --channel)
        need_value "$@"
        CHANNEL=$2
        shift 2
        ;;
      --sudo) WITH_SUDO=1 && shift ;;
      --tailscale) WITH_TAILSCALE=1 && shift ;;
      --no-firewall) WITH_FIREWALL=0 && shift ;;
      --no-ssh-hardening) WITH_SSH_HARDENING=0 && shift ;;
      --no-auto-reboot) AUTO_REBOOT=0 && shift ;;
      --yes) ASSUME_YES=1 && shift ;;
      --uninstall) UNINSTALL=1 && shift ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "Unbekannte Option: $1 (siehe --help)" ;;
    esac
  done
  [[ "$CLAUDE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Ungültiger Benutzername: $CLAUDE_USER"
  [[ "$CHANNEL" == stable || "$CHANNEL" == latest ]] || die "--channel muss stable oder latest sein."
  [[ -z "$GITHUB_USER" || "$GITHUB_USER" =~ ^[A-Za-z0-9-]{1,39}$ ]] || die "Ungültiger GitHub-Name: $GITHUB_USER"
  [[ ! "$OWNER" =~ [\"\$\`\\] && "$OWNER" != *$'\n'* ]] || die "--owner darf keine Zeichen wie \" \$ \` \\ enthalten."
}

# Wert aus einer bestehenden /etc/claude-rc.env lesen.
config_value() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC2016
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2:-}"' _ "$CONFIG_FILE" "$1"
}

preflight() {
  ((EUID == 0)) || die "Bitte mit sudo starten: sudo $0"
  [[ -r /etc/os-release ]] || die "Unbekanntes Betriebssystem."
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ "${ID:-}" == debian || "${ID:-}" == ubuntu || " ${ID_LIKE:-} " == *" debian "* ]] ||
    die "Unterstützt werden Ubuntu und Debian (gefunden: ${PRETTY_NAME:-unbekannt})."
  case "$(uname -m)" in
    x86_64 | aarch64) ;;
    *) die "Nicht unterstützte Architektur: $(uname -m) (nötig: x86_64 oder arm64)." ;;
  esac

  HAS_SYSTEMD=0
  [[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
  ((HAS_SYSTEMD)) || warn "Kein laufendes systemd (Container?) – Dienste werden nur installiert, nicht gestartet."

  ADMIN_USER="${SUDO_USER:-}"
  [[ "$ADMIN_USER" == root ]] && ADMIN_USER=""

  # Bei erneutem Aufruf die bisherigen Werte übernehmen.
  if ((!USER_FROM_FLAG)) && [[ -n "$(config_value CLAUDE_USER)" ]]; then
    CLAUDE_USER="$(config_value CLAUDE_USER)"
  fi
  [[ -n "$OWNER" ]] || OWNER="$(config_value OWNER)"
  if [[ -z "$OWNER" && -n "$ADMIN_USER" ]]; then
    OWNER="$(getent passwd "$ADMIN_USER" | cut -d: -f5 | cut -d, -f1 | awk '{print $1}' || true)"
    OWNER="${OWNER:-$ADMIN_USER}"
    OWNER="${OWNER//[\"\$\`\\]/}"
  fi
  OWNER="${OWNER:-Admin}"
}

# Befehl als Claude-Benutzer ausführen: im Home-Verzeichnis, mit sauberer
# Umgebung (nur Proxy-Einstellungen werden übernommen).
as_claude() {
  local -a env_vars=(HOME="$CLAUDE_HOME" USER="$CLAUDE_USER" LOGNAME="$CLAUDE_USER" LANG=C.UTF-8
    PATH="$CLAUDE_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin")
  local name
  for name in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [[ -n "${!name:-}" ]] && env_vars+=("$name=${!name}")
  done
  runuser -u "$CLAUDE_USER" -- env -i -C "$CLAUDE_HOME" "${env_vars[@]}" "$@"
}

# Vorlage ausgeben und {{PLATZHALTER}} ersetzen.
render() {
  local text key pattern
  local -A vars=(
    [OWNER]="$OWNER" [CLAUDE_USER]="$CLAUDE_USER" [WORKSPACE]="$WORKSPACE"
    [CHANNEL]="$CHANNEL" [GITHUB]="$GITHUB_USER"
  )
  text="$(<"$1")"
  for key in "${!vars[@]}"; do
    pattern="{{$key}}"
    text="${text//"$pattern"/"${vars[$key]}"}"
  done
  printf '%s\n' "$text"
}

# Vorlage in den Arbeitsordner kopieren – nur, wenn es die Datei noch nicht gibt.
install_template() {
  local src=$1 dest=$2
  if [[ -e "$dest" ]]; then
    info "Vorhanden, nicht überschrieben: $dest"
    return 0
  fi
  render "$src" >"$dest"
  chown "$CLAUDE_USER:$CLAUDE_GROUP" "$dest"
  chmod 0640 "$dest"
  ok "Angelegt: $dest"
}

# NAME="WERT" in /etc/claude-rc.env setzen (oder ergänzen).
set_config() {
  local key=$1 value=$2 line found=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s="%s"\n' "$key" "$value"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done <"$CONFIG_FILE" >"$tmp"
  ((found)) || printf '%s="%s"\n' "$key" "$value" >>"$tmp"
  install -m 0644 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

ask() {
  local answer
  read -r -p "$1 [J/n] " answer || true
  [[ -z "$answer" || "$answer" =~ ^[jJyY] ]]
}

# --- Schritte ----------------------------------------------------------------

install_packages() {
  step "1/10 Pakete installieren und System aktualisieren"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local apt_opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  local pkgs=(ca-certificates curl git htop jq openssh-client openssh-server python3 ripgrep
    rsync sudo tmux unattended-upgrades unzip)
  local virt
  virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
  ((WITH_FIREWALL)) && pkgs+=(ufw)
  [[ "$virt" == kvm || "$virt" == qemu ]] && pkgs+=(qemu-guest-agent)
  apt-get update -q
  apt-get "${apt_opts[@]}" upgrade
  apt-get "${apt_opts[@]}" install --no-install-recommends "${pkgs[@]}"
  ok "Pakete installiert, System aktuell."
  if [[ "$virt" == kvm || "$virt" == qemu ]]; then
    if ((HAS_SYSTEMD)); then
      systemctl start --no-block qemu-guest-agent 2>/dev/null || true
    fi
    ok "VM erkannt (Proxmox/KVM): QEMU-Gast-Agent installiert – in Proxmox unter Optionen „QEMU Guest Agent“ aktivieren."
  fi
}

configure_updates() {
  step "2/10 Automatische Sicherheitsupdates"
  local reboot=false
  ((AUTO_REBOOT)) && reboot=true
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >"$APT_DROPIN" <<EOF
// Angelegt von claude-mini-pc/setup.sh
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  if ((AUTO_REBOOT)); then
    ok "Sicherheitsupdates täglich, Neustart bei Bedarf um 04:30."
  else
    ok "Sicherheitsupdates täglich (ohne automatischen Neustart)."
  fi
}

keep_awake() {
  step "3/10 Dauerbetrieb"
  if ((HAS_SYSTEMD)); then
    systemctl mask --quiet sleep.target suspend.target hibernate.target hybrid-sleep.target
    ok "Standby und Ruhezustand abgeschaltet."
  else
    warn "Übersprungen (kein systemd)."
  fi
}

create_user() {
  step "4/10 Benutzer „$CLAUDE_USER“"
  if id "$CLAUDE_USER" &>/dev/null; then
    ok "Benutzer gibt es schon."
  else
    useradd --create-home --shell /bin/bash --comment "Claude Code" "$CLAUDE_USER"
    ok "Benutzer angelegt (ohne Passwort – Zugang nur über: claude-rc shell)."
  fi
  CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
  CLAUDE_GROUP="$(id -gn "$CLAUDE_USER")"
  WORKSPACE="$CLAUDE_HOME/workspace"
  [[ "$CLAUDE_USER" != "$ADMIN_USER" ]] ||
    warn "Claude läuft unter deinem eigenen Konto und kann damit auf alle deine Dateien zugreifen."

  if ((WITH_SUDO)); then
    printf '# Angelegt von claude-mini-pc/setup.sh (--sudo)\n%s ALL=(ALL) NOPASSWD:ALL\n' \
      "$CLAUDE_USER" >"$SUDOERS_FILE.tmp"
    chmod 0440 "$SUDOERS_FILE.tmp"
    if ! visudo -cqf "$SUDOERS_FILE.tmp"; then
      rm -f "$SUDOERS_FILE.tmp"
      die "sudo-Regel ist ungültig."
    fi
    mv "$SUDOERS_FILE.tmp" "$SUDOERS_FILE"
    warn "Claude darf sudo ohne Passwort – voller Zugriff auf den Mini-PC."
  elif [[ -f "$SUDOERS_FILE" ]]; then
    rm -f "$SUDOERS_FILE"
    ok "sudo-Recht für Claude entfernt."
  fi
}

install_claude() {
  step "5/10 Claude Code"
  local bin="$CLAUDE_HOME/.local/bin/claude"
  if [[ -x "$bin" ]]; then
    ok "Schon installiert: $(as_claude "$bin" --version 2>/dev/null || echo '?') – Updates kommen automatisch."
    return 0
  fi
  # shellcheck disable=SC2016
  as_claude bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash -s "$1"' _ "$CHANNEL" ||
    die "Installation von Claude Code fehlgeschlagen – ist das Internet erreichbar?"
  [[ -x "$bin" ]] || die "Claude Code wurde nicht unter $bin gefunden."
  ok "Installiert: $(as_claude "$bin" --version)"
}

setup_workspace() {
  step "6/10 Arbeitsordner $WORKSPACE"
  local dir
  for dir in "$WORKSPACE" "$WORKSPACE/projects" "$WORKSPACE/scripts" "$WORKSPACE/logs"; do
    install -d -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" -m 0750 "$dir"
  done
  install_template "$SCRIPT_DIR/workspace/CLAUDE.md" "$WORKSPACE/CLAUDE.md"
  install_template "$SCRIPT_DIR/workspace/SERVERS.md" "$WORKSPACE/SERVERS.md"
  if [[ ! -e "$WORKSPACE/.gitignore" ]]; then
    printf '# Geklonte Repos haben ihre eigene Versionsverwaltung.\nprojects/\n' >"$WORKSPACE/.gitignore"
    chown "$CLAUDE_USER:$CLAUDE_GROUP" "$WORKSPACE/.gitignore"
  fi

  as_claude git config --global user.name >/dev/null ||
    as_claude git config --global user.name "Claude ($(uname -n))"
  as_claude git config --global user.email >/dev/null ||
    as_claude git config --global user.email "claude@$(uname -n).local"
  as_claude git config --global init.defaultBranch main
  if [[ ! -d "$WORKSPACE/.git" ]]; then
    as_claude git -C "$WORKSPACE" init -q
    as_claude git -C "$WORKSPACE" add -A
    as_claude git -C "$WORKSPACE" commit -q -m "Arbeitsordner angelegt"
    ok "Git-Repository angelegt (Änderungen siehst du auch in der App)."
  fi
}

setup_ssh() {
  step "7/10 SSH-Schlüssel für Claude"
  local ssh_dir="$CLAUDE_HOME/.ssh"
  install -d -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" -m 0700 "$ssh_dir" "$ssh_dir/config.d"
  if [[ -f "$ssh_dir/id_ed25519" ]]; then
    ok "Schlüssel vorhanden."
  else
    as_claude ssh-keygen -q -t ed25519 -N "" -C "claude@$(uname -n)" -f "$ssh_dir/id_ed25519"
    ok "Neuen Schlüssel erzeugt."
  fi
  if [[ ! -f "$ssh_dir/config" ]]; then
    cat >"$ssh_dir/config" <<'EOF'
# SSH-Einstellungen für Claude. Jeder Server ist eine eigene Datei in
# ~/.ssh/config.d/ – am einfachsten anlegen mit: claude-rc add-server
Include config.d/*.conf

Host *
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ConnectTimeout 15
    ServerAliveInterval 30
    ServerAliveCountMax 4
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 5m
EOF
    chown "$CLAUDE_USER:$CLAUDE_GROUP" "$ssh_dir/config"
    chmod 0600 "$ssh_dir/config"
    ok "SSH-Konfiguration angelegt."
  fi
}

configure_claude() {
  step "8/10 Claude-Einstellungen (Auto-Modus und Regeln)"
  local dir="$CLAUDE_HOME/.claude" settings="$CLAUDE_HOME/.claude/settings.json"
  install -d -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" -m 0700 "$dir"
  if [[ -e "$settings" ]]; then
    info "Vorhanden, nicht überschrieben: $settings"
    info "(Vorlage zum Vergleichen: $SCRIPT_DIR/config/settings.json)"
    return 0
  fi
  jq --arg owner "$OWNER" --arg user "$CLAUDE_USER" --arg github "$GITHUB_USER" \
    --arg channel "$CHANNEL" --arg workspace "$WORKSPACE" '
    def fill:
      split("{{OWNER}}") | join($owner)
      | split("{{CLAUDE_USER}}") | join($user)
      | split("{{GITHUB}}") | join($github)
      | split("{{CHANNEL}}") | join($channel)
      | split("{{WORKSPACE}}") | join($workspace);
    (if $github == "" then .autoMode.environment |= map(select(contains("{{GITHUB}}") | not)) else . end)
    | walk(if type == "string" then fill else . end)
  ' "$SCRIPT_DIR/config/settings.json" >"$settings.tmp"
  chown "$CLAUDE_USER:$CLAUDE_GROUP" "$settings.tmp"
  chmod 0600 "$settings.tmp"
  mv "$settings.tmp" "$settings"
  ok "Auto-Modus mit Sicherheitsregeln eingerichtet: $settings"
}

install_service() {
  step "9/10 Dienst für den Dauerbetrieb"
  install -D -m 0755 "$SCRIPT_DIR/bin/claude-rc" /usr/local/bin/claude-rc
  install -D -m 0755 "$SCRIPT_DIR/bin/claude-rc-loop" "$LIB_DIR/claude-rc-loop"
  [[ -f "$CONFIG_FILE" ]] || install -m 0644 "$SCRIPT_DIR/config/claude-rc.env" "$CONFIG_FILE"
  set_config CLAUDE_USER "$CLAUDE_USER"
  set_config WORKSPACE "$WORKSPACE"
  set_config OWNER "$OWNER"

  render "$SCRIPT_DIR/systemd/claude-remote.service" >"$UNIT_DIR/claude-remote.service"
  install -m 0644 "$SCRIPT_DIR/systemd/claude-remote-restart.service" \
    "$SCRIPT_DIR/systemd/claude-remote-restart.timer" "$UNIT_DIR/"
  chmod 0644 "$UNIT_DIR/claude-remote.service"
  if ((HAS_SYSTEMD)); then
    systemctl daemon-reload
    systemctl enable --now --quiet claude-remote-restart.timer
    if systemctl is-active --quiet claude-remote.service; then
      warn "Der Dienst läuft bereits – neue Version übernehmen mit: claude-rc restart"
    fi
  fi
  ok "Befehl „claude-rc“, Dienst „claude-remote“ und Einstellungen ($CONFIG_FILE) installiert."
}

setup_firewall() {
  step "10/10 Firewall und SSH"
  if ((WITH_FIREWALL)); then
    local port
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
    port="${port:-22}"
    if ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null &&
      ufw allow "$port/tcp" >/dev/null && ufw --force enable >/dev/null; then
      ok "Firewall aktiv: eingehend nur SSH (Port $port). Remote Control braucht keine offenen Ports."
    else
      warn "Firewall konnte nicht aktiviert werden – übersprungen."
    fi
  else
    info "Firewall übersprungen (--no-firewall)."
  fi
  harden_ssh
}

harden_ssh() {
  if ((!WITH_SSH_HARDENING)); then
    info "SSH-Härtung übersprungen (--no-ssh-hardening)."
    return 0
  fi
  if [[ -z "$ADMIN_USER" ]]; then
    warn "Direkt als root angemeldet – SSH-Härtung übersprungen, damit du dich nicht aussperrst."
    return 0
  fi
  local keys lines="PermitRootLogin no"
  keys="$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys"
  if [[ -s "$keys" ]]; then
    lines+=$'\nPasswordAuthentication no\nKbdInteractiveAuthentication no'
  fi
  mkdir -p "$(dirname "$SSHD_DROPIN")" /run/sshd
  printf '# Angelegt von claude-mini-pc/setup.sh\n%s\n' "$lines" >"$SSHD_DROPIN"
  if ! sshd -t 2>/dev/null; then
    rm -f "$SSHD_DROPIN"
    warn "SSH-Konfiguration wurde nicht akzeptiert – Härtung zurückgenommen."
    return 0
  fi
  ((HAS_SYSTEMD)) && systemctl try-reload-or-restart ssh.service 2>/dev/null || true
  if [[ -s "$keys" ]]; then
    ok "SSH: Anmeldung nur noch mit Schlüssel, kein root-Login."
  else
    ok "SSH: kein root-Login."
    warn "Für „$ADMIN_USER“ ist noch kein SSH-Schlüssel hinterlegt – Passwort-Login bleibt erlaubt."
    warn "Schlüssel einrichten (siehe README) und setup.sh erneut ausführen."
  fi
}

setup_tailscale() {
  ((WITH_TAILSCALE)) || return 0
  step "Extra: Tailscale (SSH-Notfallzugang von unterwegs)"
  if ! command -v tailscale >/dev/null; then
    if ! curl -fsSL https://tailscale.com/install.sh | sh; then
      warn "Tailscale-Installation fehlgeschlagen – später erneut versuchen."
      return 0
    fi
  fi
  if tailscale status >/dev/null 2>&1; then
    ok "Tailscale ist verbunden."
  elif [[ -t 0 ]] && ((!ASSUME_YES)); then
    info "Melde den Mini-PC bei Tailscale an (den angezeigten Link öffnen):"
    tailscale up || warn "Anmeldung fehlgeschlagen – später: sudo tailscale up"
  else
    info "Bei Tailscale anmelden mit: sudo tailscale up"
  fi
}

uninstall() {
  step "Deinstallieren"
  if ((HAS_SYSTEMD)); then
    systemctl disable --now claude-remote.service claude-remote-restart.timer 2>/dev/null || true
  fi
  rm -f "$UNIT_DIR/claude-remote.service" "$UNIT_DIR/claude-remote-restart.service" \
    "$UNIT_DIR/claude-remote-restart.timer" /usr/local/bin/claude-rc "$CONFIG_FILE" \
    "$SUDOERS_FILE" "$APT_DROPIN"
  rm -rf "$LIB_DIR"
  ((HAS_SYSTEMD)) && systemctl daemon-reload
  ok "Dienst, Befehle und Einstellungen entfernt."
  info "Behalten: Benutzer „$CLAUDE_USER“ (Arbeitsordner, Schlüssel, Anmeldung), Firewall und SSH-Härtung."
  info "Benutzer samt Daten löschen: sudo userdel -r $CLAUDE_USER"
}

summary() {
  step "Fertig 🎉"
  info "Nächster Schritt – bei Claude anmelden und Remote Control einschalten:"
  info "    ${B}claude-rc first-run${N}"
  info "Danach Server eintragen, z. B.:"
  info "    claude-rc add-server web deploy@203.0.113.10 --desc \"Webserver (nginx)\""
  info "Alle Befehle: claude-rc help"
  [[ -f /var/run/reboot-required ]] &&
    warn "Die Updates brauchen einen Neustart: nach first-run „sudo reboot“ (der Dienst startet von selbst)."
  if [[ -t 0 ]] && ((!ASSUME_YES && HAS_SYSTEMD)) && ask "Jetzt mit der Anmeldung weitermachen?"; then
    exec /usr/local/bin/claude-rc first-run
  fi
}

main() {
  parse_args "$@"
  preflight
  if ((UNINSTALL)); then
    uninstall
    return 0
  fi
  install_packages
  configure_updates
  keep_awake
  create_user
  install_claude
  setup_workspace
  setup_ssh
  configure_claude
  install_service
  setup_firewall
  setup_tailscale
  summary
}

main "$@"
