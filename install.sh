#!/usr/bin/env bash
#
# Pinokio Headless-Server Installer
# ----------------------------------
# Installiert Pinokio (https://pinokio.co) auf einer Debian/Ubuntu VM und
# betreibt es als systemd-Dienst (Xvfb + Electron-App), sodass es dauerhaft
# im Hintergrund läuft und über http://<VM-IP>:42000 von jedem Gerät im
# Netzwerk erreichbar ist.
#
# Aufruf (Einzeiler, in der VM als root ausführen):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)"
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Hilfsfunktionen für Ausgaben
# ----------------------------------------------------------------------------
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
msg_info()  { echo -e "${C_INFO}➜${C_RESET} $*"; }
msg_ok()    { echo -e "${C_OK}✔${C_RESET} $*"; }
msg_warn()  { echo -e "${C_WARN}⚠${C_RESET} $*"; }
msg_err()   { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }

PINOKIO_USER="pinokio"
PINOKIO_HOME="/home/${PINOKIO_USER}"
DISPLAY_NUM=":99"
VNC_PORT="5900"
PINOKIO_PORT="42000"
NEED_REBOOT=0
GPU_DRIVER_SKIPPED=0

# ----------------------------------------------------------------------------
# Vorabprüfungen
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  msg_err "Bitte als root ausführen (z.B. mit sudo)."
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  msg_err "Kann /etc/os-release nicht finden – nicht unterstütztes System."
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"

case "$OS_ID" in
  debian|ubuntu) ;;
  *)
    msg_err "Dieses Skript unterstützt nur Debian und Ubuntu (erkannt: ${OS_ID:-unbekannt})."
    exit 1
    ;;
esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  *)
    msg_err "Nicht unterstützte Architektur: $ARCH (nur amd64/arm64)."
    exit 1
    ;;
esac

msg_info "System erkannt: ${PRETTY_NAME:-$OS_ID} (${ARCH})"

# ----------------------------------------------------------------------------
# Basispakete
# ----------------------------------------------------------------------------
msg_info "Aktualisiere Paketlisten und installiere Grundpakete..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget ca-certificates gnupg pciutils \
  xvfb x11vnc dbus-x11 sudo >/dev/null
msg_ok "Grundpakete installiert."

# ----------------------------------------------------------------------------
# GPU-Erkennung & Treiberinstallation
# ----------------------------------------------------------------------------
enable_debian_nonfree_components() {
  # Versucht "contrib non-free non-free-firmware" zu aktivieren, ohne
  # bestehende, bereits angepasste Zeilen zu verändern.
  local changed=0
  if [ -f /etc/apt/sources.list ] && grep -Eq '^deb https?://[^ ]+ [a-z-]+ main$' /etc/apt/sources.list; then
    sed -i -E 's|^(deb https?://[^ ]+ [a-z-]+ main)$|\1 contrib non-free non-free-firmware|' /etc/apt/sources.list
    changed=1
  fi
  if [ -f /etc/apt/sources.list.d/debian.sources ] && grep -q '^Components: main$' /etc/apt/sources.list.d/debian.sources; then
    sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
    changed=1
  fi
  if [ "$changed" = "1" ]; then
    msg_info "contrib/non-free-Komponenten aktiviert, aktualisiere Paketlisten..."
    apt-get update -qq
  fi
}

detect_and_install_gpu_drivers() {
  local gpu_info
  gpu_info="$(lspci -nnk | grep -A2 -Ei 'vga compatible controller|3d controller' || true)"

  if echo "$gpu_info" | grep -qi 'nvidia'; then
    msg_info "NVIDIA-GPU erkannt. Installiere Treiber..."
    if [ "$OS_ID" = "ubuntu" ]; then
      apt-get install -y -qq ubuntu-drivers-common >/dev/null
      if ubuntu-drivers autoinstall; then
        NEED_REBOOT=1
        msg_ok "NVIDIA-Treiber installiert (ubuntu-drivers autoinstall)."
      else
        msg_warn "ubuntu-drivers autoinstall ist fehlgeschlagen. Treiber bitte manuell installieren."
        GPU_DRIVER_SKIPPED=1
      fi
    else
      enable_debian_nonfree_components
      if apt-cache show nvidia-driver >/dev/null 2>&1; then
        apt-get install -y -qq nvidia-driver firmware-misc-nonfree >/dev/null
        NEED_REBOOT=1
        msg_ok "NVIDIA-Treiber installiert (nvidia-driver)."
      else
        msg_warn "Paket 'nvidia-driver' nicht gefunden. Bitte 'contrib' und 'non-free-firmware'"
        msg_warn "in den APT-Quellen aktivieren, 'apt update' ausführen und danach:"
        msg_warn "  apt install nvidia-driver firmware-misc-nonfree"
        GPU_DRIVER_SKIPPED=1
      fi
    fi
  elif echo "$gpu_info" | grep -qi 'amd\|ati'; then
    msg_info "AMD-GPU erkannt. Installiere Firmware/Mesa..."
    apt-get install -y -qq firmware-amd-graphics libgl1-mesa-dri mesa-vulkan-drivers vainfo >/dev/null
    NEED_REBOOT=1
    msg_ok "AMD-Grafiktreiber/Firmware installiert."
    msg_warn "Für GPU-Rechenlast (KI-Modelle) benötigen manche Apps zusätzlich ROCm."
    msg_warn "Siehe: https://rocm.docs.amd.com/ (nicht Teil dieses Skripts)."
  elif echo "$gpu_info" | grep -qi 'intel'; then
    msg_info "Intel-GPU erkannt. Installiere Mesa/VAAPI..."
    apt-get install -y -qq intel-media-va-driver libgl1-mesa-dri >/dev/null
    msg_ok "Intel-Grafiktreiber installiert."
  else
    msg_warn "Keine durchgereichte GPU erkannt. Pinokio wird im CPU-Modus laufen."
    msg_warn "Siehe README.md, Abschnitt 'GPU Passthrough', um eine GPU durchzureichen."
  fi
}

detect_and_install_gpu_drivers

# ----------------------------------------------------------------------------
# Dedizierten Benutzer für den Dienst anlegen
# ----------------------------------------------------------------------------
if ! id -u "$PINOKIO_USER" >/dev/null 2>&1; then
  msg_info "Lege Systembenutzer '${PINOKIO_USER}' an..."
  useradd --create-home --home-dir "$PINOKIO_HOME" --shell /usr/sbin/nologin "$PINOKIO_USER"
  msg_ok "Benutzer '${PINOKIO_USER}' angelegt."
else
  msg_info "Benutzer '${PINOKIO_USER}' existiert bereits, überspringe."
fi
usermod -aG video,render "$PINOKIO_USER" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Neueste Pinokio-Version ermitteln und installieren
# ----------------------------------------------------------------------------
msg_info "Ermittle neueste Pinokio-Version..."
TAG="$(curl -fsSL https://api.github.com/repos/pinokiocomputer/pinokio/releases/latest \
  | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | sed -E 's#.*"([^"]+)"$#\1#' | tr -d '\r')"

# Fallback: Redirect des /releases/latest-Links auswerten, falls die API nicht antwortet
if [ -z "$TAG" ]; then
  TAG="$(curl -fsSI https://github.com/pinokiocomputer/pinokio/releases/latest \
    | grep -i '^location:' | sed -E 's#.*/tag/(v?[0-9][0-9a-zA-Z.-]*).*#\1#' | tr -d '\r')"
fi

if [ -z "$TAG" ]; then
  msg_err "Konnte die neueste Pinokio-Version nicht ermitteln (GitHub nicht erreichbar?)."
  exit 1
fi
VERSION="${TAG#v}"
DEB_NAME="Pinokio_${VERSION}_${ARCH}.deb"
DEB_URL="https://github.com/pinokiocomputer/pinokio/releases/download/${TAG}/${DEB_NAME}"
TMP_DEB="/tmp/${DEB_NAME}"

msg_info "Lade Pinokio ${VERSION} (${ARCH}) herunter..."
curl -fL --progress-bar -o "$TMP_DEB" "$DEB_URL"

msg_info "Installiere Pinokio..."
apt-get install -y -qq "$TMP_DEB" >/dev/null
rm -f "$TMP_DEB"

# Das .deb installiert die Binärdatei je nach Version nach /opt/Pinokio/pinokio
# (aktuell, kein /usr/bin-Symlink!) oder älter nach /usr/bin/pinokio – daher suchen.
PINOKIO_BIN=""
for CAND in /opt/Pinokio/pinokio /usr/bin/pinokio /usr/local/bin/pinokio; do
  if [ -x "$CAND" ]; then
    PINOKIO_BIN="$CAND"
    break
  fi
done
if [ -z "$PINOKIO_BIN" ]; then
  msg_err "Installation fehlgeschlagen: Pinokio-Binary wurde nicht gefunden (/opt/Pinokio/pinokio)."
  exit 1
fi
msg_ok "Pinokio ${VERSION} installiert (${PINOKIO_BIN})."

# ----------------------------------------------------------------------------
# Pinokio vorkonfigurieren (headless, ohne GUI-Ersteinrichtung)
# ----------------------------------------------------------------------------
# Pinokio liest seine Einstellungen aus ~/.pinokio/config.json. Wird dort ein
# "home" vorgegeben, entfällt der Ordner-Auswahl-Dialog beim ersten Start und
# der Webserver ist sofort unter http://<VM-IP>:42000 erreichbar.
msg_info "Konfiguriere Pinokio für Headless-Betrieb..."
PINOKIO_DATA_HOME="${PINOKIO_HOME}/pinokio"
install -d -o "$PINOKIO_USER" -g "$PINOKIO_USER" "$PINOKIO_DATA_HOME"
if [ ! -f "${PINOKIO_HOME}/.pinokio/config.json" ]; then
  install -d -o "$PINOKIO_USER" -g "$PINOKIO_USER" "${PINOKIO_HOME}/.pinokio"
  cat > "${PINOKIO_HOME}/.pinokio/config.json" <<EOF
{
  "home": "${PINOKIO_DATA_HOME}"
}
EOF
  chown "${PINOKIO_USER}:${PINOKIO_USER}" "${PINOKIO_HOME}/.pinokio/config.json"
fi
msg_ok "Pinokio konfiguriert (Datenverzeichnis: ${PINOKIO_DATA_HOME})."

# ----------------------------------------------------------------------------
# systemd-Dienste einrichten
# ----------------------------------------------------------------------------
msg_info "Richte systemd-Dienste ein..."

cat > /etc/systemd/system/pinokio-xvfb.service <<EOF
[Unit]
Description=Virtuelles Display fuer Pinokio (Xvfb)
After=network.target

[Service]
Type=simple
User=${PINOKIO_USER}
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 1280x800x24 -nolisten tcp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pinokio-vnc.service <<EOF
[Unit]
Description=Temporaerer VNC-Zugriff auf das Pinokio-Display (nur fuer Ersteinrichtung)
After=pinokio-xvfb.service
Requires=pinokio-xvfb.service

[Service]
Type=simple
User=${PINOKIO_USER}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=/usr/bin/x11vnc -display ${DISPLAY_NUM} -localhost -nopw -forever -shared -rfbport ${VNC_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/pinokio.service <<EOF
[Unit]
Description=Pinokio AI Browser (Server)
After=network-online.target pinokio-xvfb.service
Wants=network-online.target
Requires=pinokio-xvfb.service

[Service]
Type=simple
User=${PINOKIO_USER}
Group=${PINOKIO_USER}
Environment=HOME=${PINOKIO_HOME}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=${PINOKIO_BIN} --no-sandbox
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pinokio-xvfb.service >/dev/null
systemctl enable --now pinokio.service >/dev/null
# pinokio-vnc.service bewusst NICHT aktivieren -> nur bei Bedarf manuell starten
msg_ok "Dienste 'pinokio-xvfb' und 'pinokio' aktiviert und gestartet."

# ----------------------------------------------------------------------------
# Healthcheck: Warten, bis der Pinokio-Webserver auf Port 42000 antwortet
# ----------------------------------------------------------------------------
msg_info "Warte auf Pinokio-Webserver (Port ${PINOKIO_PORT})..."
PINOKIO_UP=0
for _ in $(seq 1 36); do   # 36 x 5s = max. 3 Minuten
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PINOKIO_PORT}" \
     || curl -fsS -o /dev/null --max-time 3 "http://localhost:${PINOKIO_PORT}"; then
    PINOKIO_UP=1
    break
  fi
  if ! systemctl is-active --quiet pinokio.service; then
    msg_err "Dienst 'pinokio' läuft nicht mehr. Logs: journalctl -u pinokio -e"
    break
  fi
  sleep 5
done
echo
if [ "$PINOKIO_UP" = "1" ]; then
  msg_ok "Pinokio-Webserver ist erreichbar."
else
  msg_warn "Pinokio-Webserver antwortet (noch) nicht auf Port ${PINOKIO_PORT}."
  msg_warn "Logs ansehen: journalctl -u pinokio -f"
fi

# ----------------------------------------------------------------------------
# Firewall (falls ufw aktiv ist)
# ----------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PINOKIO_PORT}/tcp" comment "Pinokio" >/dev/null || true
  msg_info "ufw-Regel für Port ${PINOKIO_PORT}/tcp hinzugefügt."
fi

# ----------------------------------------------------------------------------
# Zusammenfassung
# ----------------------------------------------------------------------------
VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
if [ "$PINOKIO_UP" = "1" ]; then
  msg_ok "Fertig! Pinokio ist jetzt im Netzwerk erreichbar:"
  echo
  echo -e "    ${C_OK}http://${VM_IP:-<VM-IP>}:${PINOKIO_PORT}${C_RESET}"
  echo
else
  msg_ok "Installation abgeschlossen (Webserver noch nicht bereit – siehe Warnung oben)."
fi
echo "  Pinokio-Version : ${VERSION}"
echo "  Web-UI          : http://${VM_IP:-<VM-IP>}:${PINOKIO_PORT}"
echo "  Datenverzeichnis: ${PINOKIO_DATA_HOME}"
echo "  Logs            : journalctl -u pinokio -f"
echo
if [ "$NEED_REBOOT" = "1" ]; then
  msg_warn "Ein Neustart wird empfohlen, damit die GPU-Treiber vollständig geladen werden:"
  echo "    reboot"
  echo
fi
if [ "$GPU_DRIVER_SKIPPED" = "1" ]; then
  msg_warn "GPU-Treiberinstallation wurde übersprungen – siehe Hinweise oben / README.md."
  echo
fi
msg_info "Falls die Web-UI doch einen Einrichtungsdialog zeigt (normalerweise nicht nötig):"
echo "    1) Auf deinem PC: ssh -L 5900:localhost:5900 root@${VM_IP:-<VM-IP>}"
echo "    2) In der VM:     systemctl start pinokio-vnc"
echo "    3) VNC-Viewer auf deinem PC gegen 'localhost:5900' verbinden (kein Passwort)"
echo "    4) Pinokio-Ersteinrichtung abschließen und unter Settings 'Home Server' /"
echo "       LAN-Zugriff aktivieren"
echo "    5) In der VM:     systemctl stop pinokio-vnc"
echo
echo "Details siehe README.md."
