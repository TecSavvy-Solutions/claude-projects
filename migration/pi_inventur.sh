#!/usr/bin/env bash
# pi_inventur.sh - READ-ONLY Inventur des Raspberry Pi (Homelab) vor/waehrend der Laptop-Migration.
# Aendert nichts. Schreibt nur eine Textdatei nach ~/pi_inventur_<datum>.txt
# Start auf dem Pi:   bash pi_inventur.sh
# Secrets (PASSWORD/TOKEN/SECRET/KEY/...) werden in der Ausgabe geschwaerzt. token.txt, .env,
# Nextcloud-Daten und Datenbanken werden NICHT gelesen.
# Passwortloses sudo wird nur abgefragt (sudo -n); ohne sudo fehlen einzelne Abschnitte, kein Abbruch.

set -u
OUT="$HOME/pi_inventur_$(date +%Y%m%d_%H%M).txt"
: > "$OUT"

redact() {
  sed -E \
    -e 's#(://[^@/[:space:]]+):[^@/[:space:]]+@#\1:***@#g' \
    -e 's/((PASS|PWD|PW|TOKEN|SECRET|KEY|CREDENTIAL|AUTH)[A-Za-z0-9_]*["'"'"']?[[:space:]]*[:=][[:space:]]*).*/\1***REDACTED***/I' \
    -e 's/((password|passwd|token|secret|apikey|api_key)["'"'"']?[[:space:]]*:[[:space:]]*).*/\1***REDACTED***/I'
}

sec() { { echo; echo "=============================================================================="; echo "$1"; echo "=============================================================================="; } >> "$OUT"; echo "-> $1"; }
run() { local title="$1"; shift; sec "$title"; { "$@" 2>&1 || true; } | redact >> "$OUT"; }
runsh() { local title="$1"; shift; sec "$title"; { bash -c "$*" 2>&1 || true; } | redact >> "$OUT"; }
catf() { # catf <datei> : Datei redigiert ausgeben (max 60 KB)
  sec "Datei: $1"
  if [ -r "$1" ]; then head -c 60000 "$1" | redact >> "$OUT"; else echo "(nicht lesbar/nicht vorhanden)" >> "$OUT"; fi
}

HS="$HOME/homeserver"
echo "Inventur: $(date -Is)  Host: $(hostname)  User: $(whoami)" >> "$OUT"

runsh "1 System" 'hostnamectl 2>/dev/null; echo; uname -a; echo; cat /etc/os-release | head -5; echo; uptime; echo; free -h; echo; vcgencmd get_throttled 2>/dev/null'
runsh "1.1 Platten / Mounts" 'lsblk -f; echo; df -hT -x tmpfs -x devtmpfs; echo; mount | grep -E "mnt|backup" '
catf /etc/fstab
runsh "1.2 /boot/firmware/config.txt (ohne Kommentare)" 'grep -vE "^\s*(#|$)" /boot/firmware/config.txt'

runsh "2 Home-Verzeichnis (Namen, Rechte)" 'ls -la "$HOME"'
runsh "2.1 ~/homeserver Struktur (Tiefe 2)" "ls -la '$HS'; echo; find '$HS' -maxdepth 2 -not -path '*/.git/*' 2>/dev/null | head -300"
runsh "2.2 Groessen ~/homeserver (kann dauern, max 120 s)" "timeout 120 du -sh '$HS'/* 2>/dev/null"
runsh "2.3 Weitere Skripte im Home (*.sh)" 'ls -la "$HOME"/*.sh 2>/dev/null'

runsh "3 Docker Version / Container" 'docker version --format "{{.Server.Version}}"; echo; docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
runsh "3.1 Container: Mounts, Ports, Restart (OHNE Env-Variablen)" 'for c in $(docker ps -aq); do docker inspect --format "{{.Name}} | image={{.Config.Image}} | restart={{.HostConfig.RestartPolicy.Name}} | net={{.HostConfig.NetworkMode}} | binds={{.HostConfig.Binds}} | ports={{.HostConfig.PortBindings}} | compose={{index .Config.Labels \"com.docker.compose.project\"}}" "$c"; done'
runsh "3.2 Images / Volumes / Netzwerke" 'docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"; echo; docker volume ls; echo; docker network ls; echo; docker compose ls'
catf "$HS/docker-compose.yml"
runsh "3.3 Nicht-Compose-Container (per docker run gestartet, z.B. obsidian-mcp): Cmd/Entrypoint" 'for c in $(docker ps -aq); do l=$(docker inspect --format "{{index .Config.Labels \"com.docker.compose.project\"}}" "$c"); [ -z "$l" ] && docker inspect --format "{{.Name}} | cmd={{.Config.Cmd}} | entrypoint={{.Config.Entrypoint}} | user={{.Config.User}}" "$c"; done'

catf "$HS/nginx/nginx.conf"
for f in "$HS"/homepage/config/*.yaml; do catf "$f"; done
catf "$HS/filebrowser/config/settings.json"
catf "$HS/filebrowser-backups/config/settings.json"
runsh "4 obsidian-mcp Verzeichnis (ohne data/)" "ls -la '$HS/obsidian-mcp' 2>/dev/null"
catf "$HS/obsidian-mcp/server.py"
catf "$HS/obsidian-mcp/Dockerfile"
catf "$HS/obsidian-mcp/requirements.txt"
catf "$HOME/backup_homelab.sh"

runsh "5 Crontab (User)" 'crontab -l'
runsh "5.1 Crontab root (sudo -n)" 'sudo -n crontab -l -u root'
runsh "5.2 /etc/cron.d, systemd timers" 'ls -la /etc/cron.d 2>/dev/null; echo; systemctl list-timers --all --no-pager 2>/dev/null | head -30'

runsh "6 Systemd: laufende Dienste" 'systemctl list-units --type=service --state=running --no-pager'
runsh "6.1 Taildrop-Dienst" 'systemctl status taildrop-receive --no-pager 2>&1 | head -12; echo; cat /etc/systemd/system/taildrop-receive.service 2>/dev/null'

catf /etc/samba/smb.conf
runsh "7.1 Samba-Benutzer (nur Namen, sudo -n)" 'sudo -n pdbedit -L'
runsh "8 Tailscale" 'tailscale status 2>&1 | head -30; echo; tailscale ip 2>&1'
runsh "8.1 Offene Ports (listening)" 'ss -tlnp 2>/dev/null || ss -tln'
runsh "8.2 Firewall (sudo -n)" 'sudo -n ufw status verbose 2>&1; sudo -n iptables -S 2>&1 | head -30'
runsh "9 SSH-Server (aktive Optionen)" 'grep -hvE "^\s*(#|$)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null'
runsh "9.1 authorized_keys: Anzahl + Kommentare (keine Schluessel)" 'awk "{print \$NF}" "$HOME/.ssh/authorized_keys" 2>/dev/null'
runsh "10 Manuell installierte Pakete (apt)" 'apt-mark showmanual 2>/dev/null | tr "\n" " "'
runsh "10.1 Updates verfuegbar" 'apt list --upgradable 2>/dev/null | head -20'
runsh "11 Klartext-Passwort-/Token-Dateien im Home (nur Namen+Rechte)" 'ls -la "$HOME" 2>/dev/null | grep -iE "pass|pw|token|secret|key" '

sec "FERTIG"
echo "Ausgabedatei: $OUT" | tee -a "$OUT"
echo "Bitte kurz ueberfliegen (Secrets sollten als ***REDACTED*** erscheinen) und an Claude geben."
