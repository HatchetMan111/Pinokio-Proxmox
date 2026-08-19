#!/usr/bin/env bash
#
# Entfernt Pinokio und die zugehörigen systemd-Dienste wieder von der VM.
#
# Aufruf:
#   bash uninstall.sh            # behält den Home-Ordner (~/pinokio) des Dienstbenutzers
#   bash uninstall.sh --purge-data   # löscht zusätzlich alle heruntergeladenen Apps/Modelle
#
set -euo pipefail

C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_RESET='\033[0m'
msg_info() { echo -e "${C_INFO}➜${C_RESET} $*"; }
msg_ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
msg_warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }

PINOKIO_USER="pinokio"
PURGE_DATA=0
[ "${1:-}" = "--purge-data" ] && PURGE_DATA=1

if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausführen (z.B. mit sudo)." >&2
  exit 1
fi

msg_info "Stoppe und deaktiviere Dienste..."
for svc in pinokio.service pinokio-vnc.service pinokio-xvfb.service; do
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
done
rm -f /etc/systemd/system/pinokio.service \
      /etc/systemd/system/pinokio-vnc.service \
      /etc/systemd/system/pinokio-xvfb.service
systemctl daemon-reload
msg_ok "Dienste entfernt."

if dpkg -l pinokio >/dev/null 2>&1; then
  msg_info "Deinstalliere Pinokio-Paket..."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq pinokio >/dev/null
  msg_ok "Pinokio-Paket entfernt."
else
  msg_warn "Pinokio-Paket war nicht installiert, überspringe."
fi

if [ "$PURGE_DATA" = "1" ]; then
  if id -u "$PINOKIO_USER" >/dev/null 2>&1; then
    msg_warn "Lösche Benutzer '${PINOKIO_USER}' inkl. Home-Verzeichnis (alle Apps/Modelle)..."
    userdel -r "$PINOKIO_USER" 2>/dev/null || true
    msg_ok "Benutzer und Daten entfernt."
  fi
else
  msg_info "Benutzer '${PINOKIO_USER}' und dessen Home-Verzeichnis (Apps/Modelle) bleiben erhalten."
  msg_info "Zum vollständigen Löschen: bash uninstall.sh --purge-data"
fi

echo
msg_ok "Deinstallation abgeschlossen."
