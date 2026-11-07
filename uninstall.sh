#!/usr/bin/env bash
# =============================================================================
#  🗑️  Pinokio AI Browser – Deinstaller (Debian/Ubuntu-VM)
#  https://github.com/HatchetMan111/Pinokio-Proxmox
#
#  Entfernt Pinokio und die zugehörigen systemd-Dienste wieder von der VM.
#
#  Aufruf:
#    bash uninstall.sh              # behält den Home-Ordner (~/pinokio) des Dienstbenutzers
#    bash uninstall.sh --purge-data # löscht zusätzlich alle heruntergeladenen Apps/Modelle
#    bash uninstall.sh --help
#
#  Alternative ohne Download (in der VM als root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)" -- --uninstall [--purge-data]
# =============================================================================

set -euo pipefail

# ── Farben & Logging (Unicode-Symbole, Ausgaben auf Deutsch) ────────────────
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'
C_ERR='\033[1;31m'; C_STEP='\033[1;36m'; C_RESET='\033[0m'; C_BOLD='\033[1m'

info()   { echo -e "${C_INFO}➜${C_RESET} $*"; }
ok()     { echo -e "${C_OK}✔${C_RESET} $*"; }
warn()   { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()    { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }
die()    { err "$1"; exit 1; }
header() { echo -e "\n${C_STEP}${C_BOLD}━━━ $1 ━━━${C_RESET}"; }

PINOKIO_USER="pinokio"
PURGE_DATA=0

usage() {
  cat <<'USAGE'
🗑️  Pinokio Deinstaller

Usage:
  bash uninstall.sh [OPTION]

Optionen:
  (keine)         Pinokio + Dienste entfernen, Apps/Modelle bleiben erhalten
  --purge-data    zusätzlich Benutzer 'pinokio' inkl. aller Apps/Modelle löschen
  --help, -h      Diese Hilfe
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-data)  PURGE_DATA=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)             die "Unbekanntes Argument: $1 (--help für Hilfe)" ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  die "Bitte als root ausführen (z.B. mit sudo)."
fi

export DEBIAN_FRONTEND=noninteractive

header "Dienste entfernen"
info "Stoppe und deaktiviere Dienste..."
for svc in pinokio.service pinokio-vnc.service pinokio-xvfb.service; do
  systemctl disable --now "$svc" >/dev/null 2>&1 || true
done
rm -f /etc/systemd/system/pinokio.service \
      /etc/systemd/system/pinokio-vnc.service \
      /etc/systemd/system/pinokio-xvfb.service
systemctl daemon-reload || true
ok "Dienste entfernt."

header "Paket entfernen"
if dpkg -l pinokio >/dev/null 2>&1; then
  info "Deinstalliere Pinokio-Paket..."
  apt-get purge -y -qq pinokio >/dev/null \
    || die "apt-get purge pinokio fehlgeschlagen – manuell prüfen: dpkg -l pinokio"
  ok "Pinokio-Paket entfernt."
else
  warn "Pinokio-Paket war nicht installiert, überspringe."
fi

header "Datenverzeichnis"
if [ "$PURGE_DATA" = "1" ]; then
  if id -u "$PINOKIO_USER" >/dev/null 2>&1; then
    warn "Lösche Benutzer '${PINOKIO_USER}' inkl. Home-Verzeichnis (alle Apps/Modelle)..."
    userdel -r "$PINOKIO_USER" 2>/dev/null || true
    ok "Benutzer und Daten entfernt."
  else
    info "Benutzer '${PINOKIO_USER}' existiert nicht – nichts zu löschen."
  fi
else
  info "Benutzer '${PINOKIO_USER}' und dessen Home-Verzeichnis (Apps/Modelle) bleiben erhalten."
  info "Zum vollständigen Löschen: bash uninstall.sh --purge-data"
fi

echo
ok "Deinstallation abgeschlossen."
