#!/usr/bin/env bash
# =============================================================================
#  🖥️  Pinokio AI Browser – Server-Installer (Debian/Ubuntu-VM)
#  https://github.com/HatchetMan111/Pinokio-Proxmox
#
#  Installiert Pinokio (https://pinokio.co) auf einer Debian/Ubuntu-VM und
#  betreibt es als systemd-Dienst (Xvfb + Electron-App), sodass es dauerhaft
#  im Hintergrund läuft und über http://<VM-IP>:42000 von jedem Gerät im
#  Netzwerk erreichbar ist. Auf einem Proxmox-Host erkannt das Skript den
#  falschen Kontext und leitet stattdessen zu create-vm.sh weiter.
#
#  Installation (in der VM als root, Einzeiler):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)"
#
#  Update (idempotent – einfach erneut ausführen):
#    bash -c "$(curl -fsSL .../install.sh)" -- --update
#
#  Status anzeigen:
#    bash -c "$(curl -fsSL .../install.sh)" -- --status
#
#  Deinstallieren:
#    bash -c "$(curl -fsSL .../install.sh)" -- --uninstall [--purge-data]
#
#  Debugging (bash -x, Log auf stderr):
#    bash -c "$(curl -fsSL .../install.sh)" -- --debug
# =============================================================================

set -euo pipefail

# ── GitHub-Quelle ───────────────────────────────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main"
PINOKIO_API_URL="https://api.github.com/repos/pinokiocomputer/pinokio/releases/latest"
PINOKIO_RELEASES_URL="https://github.com/pinokiocomputer/pinokio/releases/latest"

# ── Farben & Logging (Unicode-Symbole, Ausgaben auf Deutsch) ────────────────
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'
C_ERR='\033[1;31m'; C_STEP='\033[1;36m'; C_RESET='\033[0m'; C_BOLD='\033[1m'

info()   { echo -e "${C_INFO}➜${C_RESET} $*"; }
ok()     { echo -e "${C_OK}✔${C_RESET} $*"; }
warn()   { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()    { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }
die()    { err "$1"; exit 1; }
header() { echo -e "\n${C_STEP}${C_BOLD}━━━ $1 ━━━${C_RESET}"; }

# ── Defaults ────────────────────────────────────────────────────────────────
PINOKIO_USER="pinokio"
PINOKIO_HOME="/home/${PINOKIO_USER}"
DISPLAY_NUM=":99"
VNC_PORT="5900"
PINOKIO_PORT="42000"

MODE="install"          # install | update | status | uninstall
PURGE_DATA=0
DEBUG=0
NEED_REBOOT=0
GPU_DRIVER_SKIPPED=0

TMP_DEB=""
TMP_TAG_FILE=""
TMP_CREATE_VM=""

SCRIPT_BUILD="2026-11-07-v7"

# ── Cleanup (kein halber Zustand: Teildownloads werden entfernt) ────────────
cleanup() {
  if [ -n "${TMP_DEB:-}" ] && [ -f "${TMP_DEB}" ]; then
    rm -f "${TMP_DEB}"
  fi
  if [ -n "${TMP_TAG_FILE:-}" ] && [ -f "${TMP_TAG_FILE}" ]; then
    rm -f "${TMP_TAG_FILE}"
  fi
  if [ -n "${TMP_CREATE_VM:-}" ] && [ -f "${TMP_CREATE_VM}" ]; then
    rm -f "${TMP_CREATE_VM}"
  fi
}
trap cleanup EXIT

# ── Argumente parsen ────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
🖥️  Pinokio AI Browser – Server-Installer (Debian/Ubuntu-VM)
   https://github.com/HatchetMan111/Pinokio-Proxmox

Usage (in der VM als root):
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)" [OPTIONEN]

Optionen:
  (keine)         Pinokio installieren bzw. aktualisieren (idempotent)
  --update        Wie keine Option – ausdrücklicher Update-Lauf
  --status        Status der Dienste + Version + URL anzeigen
  --uninstall     Pinokio + Dienste entfernen (Apps/Modelle bleiben)
  --purge-data    Nur mit --uninstall: zusätzlich alle Apps/Modelle löschen
  --debug         bash -x-Logging aktivieren (jeder Befehl sichtbar)
  --help, -h      Diese Hilfe

Beispiele:
  bash -c "$(curl -fsSL .../install.sh)"                     # Installation
  bash -c "$(curl -fsSL .../install.sh)" -- --update          # Update
  bash -c "$(curl -fsSL .../install.sh)" -- --status          # Status
  bash -c "$(curl -fsSL .../install.sh)" -- --uninstall       # Deinstallation
  curl -fsSL .../install.sh | bash -s -- --status             # Variante per Pipe

Auf einem Proxmox-Host (pveversion vorhanden) leitet das Skript automatisch zur
VM-Erstellung weiter:  bash -c "$(curl -fsSL .../create-vm.sh)"
USAGE
}

parse_args() {
  # bash -c "$(curl ...)" --update übergibt "--update" als $0 – auch das mitscrollen.
  # (set -- "$0" "$@" würde bei älteren Bash-Versionen unter set -u brechen, daher
  # der klassische ${@+...}-Workaround.)
  if [ "${0:-}" = "--update" ] || [ "${0:-}" = "--status" ] || [ "${0:-}" = "--uninstall" ] \
     || [ "${0:-}" = "--debug" ] || [ "${0:-}" = "--help" ] || [ "${0:-}" = "-h" ] \
     || [ "${0:-}" = "--purge-data" ]; then
    set -- "$0" ${@+"$@"}
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --update)      MODE="update"; shift ;;
      --status)      MODE="status"; shift ;;
      --uninstall)   MODE="uninstall"; shift ;;
      --purge-data)  PURGE_DATA=1; shift ;;
      --debug|-x)    DEBUG=1; shift ;;
      --help|-h)     usage; exit 0 ;;
      *)             die "Unbekanntes Argument: $1 (--help für Hilfe)" ;;
    esac
  done

  if [ "$PURGE_DATA" = "1" ] && [ "$MODE" != "uninstall" ]; then
    die "--purge-data ist nur zusammen mit --uninstall sinnvoll."
  fi
}

# ── Debug-Modus (bash -x) ───────────────────────────────────────────────────
enable_debug() {
  info "Debug-Modus aktiv (bash -x). Jeder ausgeführte Befehl wird angezeigt."
  PS4='+ $(date +%H:%M:%S) [${BASH_SOURCE}:${LINENO}] '
  set -x
}

# ── Proxmox-Host-Erkennung & Routing ────────────────────────────────────────
# install.sh gehört IN die VM. Auf einem Proxmox-Host (pveversion vorhanden,
# ebenfalls Debian-basiert – daher hier ohne Schutz nicht unterscheidbar von
# einer VM) würde dieses Skript Pinokio direkt auf den Hypervisor installieren.
# Das wollen wir niemals: also Kontext erkennen und sauber routen.
is_proxmox_host() {
  command -v pveversion >/dev/null 2>&1
}

handle_proxmox_host() {
  header "Proxmox-Host erkannt – install.sh gehört in die VM"
  warn "Du bist auf einem Proxmox-VE-Host (pveversion gefunden)."
  warn "Pinokio würde hier direkt auf den Hypervisor installiert – das ist fast"
  warn "sicher nicht gewollt. Richtig ist: VM anlegen und Pinokio in die VM."
  echo
  info "Der passende Einzeiler für den Proxmox-Host ist:"
  echo
  echo -e "    ${C_BOLD}bash -c \"\$(curl -fsSL ${REPO_RAW}/create-vm.sh)\"${C_RESET}"
  echo
  info "create-vm.sh erstellt automatisch eine Debian/Ubuntu-VM (inkl. whiptail-"
  info "Assistent bei interaktiver Sitzung) und installiert Pinokio anschließend"
  info "per SSH in diese VM. Alle Werte (CORES, MEMORY, DISK_SIZE, OS_IMAGE, IPCONFIG,"
  info "NONINTERACTIVE, ...) werden per Umgebungsvariable an create-vm.sh weitergereicht."

  # Sauberer TTY-Fallback: nur interaktiv nachfragen; per Pipe (curl | bash)
  # niemals ohne Zustimmung eine VM anlegen.
  if [ -t 0 ] && [ -t 1 ]; then
    local answer=""
    echo
    # read kann bei EOF/Abbruch fehlschlagen -> nicht set -e überlassen
    read -r -p "Jetzt create-vm.sh herunterladen und starten? [J/n] " answer || answer=""
    case "$answer" in
      n|N|nein|Nein|NEIN)
        info "Verstanden – hier die Anleitung für den nächsten Schritt:"
        info "  1) Auf dem Host:  bash -c \"\$(curl -fsSL ${REPO_RAW}/create-vm.sh)\""
        info "  2) Warten, bis create-vm.sh die URL http://<VM-IP>:42000 ausgibt."
        exit 0
        ;;
      *)  # Leerzeichen/Enter = Ja (Default), j/J/ja/y/yes
        info "Lade create-vm.sh herunter..."
        TMP_CREATE_VM="$(mktemp /tmp/pinokio-create-vm-XXXXXX.sh)"
        if ! curl -fsSL --retry 3 --retry-delay 2 "${REPO_RAW}/create-vm.sh" -o "${TMP_CREATE_VM}" \
           || [ ! -s "${TMP_CREATE_VM}" ]; then
          die "Download von create-vm.sh fehlgeschlagen. Manuell ausführen:
  bash -c \"\$(curl -fsSL ${REPO_RAW}/create-vm.sh)\""
        fi
        # HINWEIS: Nach 'exec' feuert der EXIT-Trap nicht mehr – die Temporärdatei
        # bleibt daher bewusst in /tmp liegen (winzig, wird beim Reboot geräumt).
        info "Starte create-vm.sh..."
        exec bash "${TMP_CREATE_VM}"
        ;;
    esac
  fi

  # Kein TTY (curl | bash, CI, Automation): sauber ablehnen statt VM anzulegen.
  die "Kein interaktives Terminal erkannt – auf einem Proxmox-Host wird hier
bewusst nichts installiert und keine VM ohne Zustimmung angelegt.

Nächster Schritt (auf dem Host ausführen):
  bash -c \"\$(curl -fsSL ${REPO_RAW}/create-vm.sh)\"

Für eine vollautomatische VM (ohne Assistent):
  NONINTERACTIVE=1 bash -c \"\$(curl -fsSL ${REPO_RAW}/create-vm.sh)\""
}

# ── Voraussetzungen prüfen ──────────────────────────────────────────────────
check_prerequisites() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Bitte als root ausführen (z.B. mit sudo)."
  fi

  if [ ! -f /etc/os-release ]; then
    die "Kann /etc/os-release nicht finden – nicht unterstütztes System."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"

  case "$OS_ID" in
    debian|ubuntu) ;;
    *) die "Dieses Skript unterstützt nur Debian und Ubuntu (erkannt: ${OS_ID:-unbekannt})." ;;
  esac

  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64|arm64) ;;
    *) die "Nicht unterstützte Architektur: ${ARCH} (nur amd64/arm64)." ;;
  esac

  # systemd muss als PID 1 laufen, sonst schlagen alle systemctl-Aufrufe fehl
  # und es bliebe ein halb installierter Zustand zurück.
  if [ ! -d /run/systemd/system ]; then
    die "systemd läuft nicht (PID 1 ist kein systemd). Pinokio wird als
systemd-Dienst betrieben und braucht ein volles Debian/Ubuntu-System –
keinen Container ohne systemd."
  fi

  # Container (LXC/Docker) degradiert funktionsfähig – zumindest warnen.
  local virt=""
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "$virt" in
    lxc|docker|containerd|podman)
      warn "Container-Umgebung erkannt (${virt}). Pinokio braucht Xvfb + Electron –"
      warn "in Containern nicht offiziell unterstützt (siehe README, Contributing)."
      ;;
    "") warn "systemd-detect-virt nicht verfügbar – Virtualisierungstyp unbekannt." ;;
    *)  ok "System erkannt: ${PRETTY_NAME:-$OS_ID} (${ARCH}, ${virt})" ;;
  esac
}

# ── Basispakete ─────────────────────────────────────────────────────────────
install_base_packages() {
  header "Basispakete installieren"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "apt-get update fehlgeschlagen – APT-Quellen/Netzwerk prüfen."
  apt-get install -y -qq \
    curl wget ca-certificates gnupg pciutils \
    xvfb x11vnc dbus-x11 sudo >/dev/null \
    || die "Installation der Grundpakete fehlgeschlagen (apt-Fehler siehe oben)."
  ok "Grundpakete installiert."
}

# ── GPU-Erkennung & Treiberinstallation ─────────────────────────────────────
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
    info "contrib/non-free-Komponenten aktiviert, aktualisiere Paketlisten..."
    apt-get update -qq || die "apt-get update nach Aktivierung von contrib/non-free fehlgeschlagen."
  fi
}

# Pakete, die fehlen können (architektur-/distrospezifisch), toleriert installieren
apt_try_install() {
  apt-get install -y -qq "$@" >/dev/null 2>&1
}

detect_and_install_gpu_drivers() {
  header "GPU-Erkennung"
  local gpu_info=""
  gpu_info="$(lspci -nnk | grep -A2 -Ei 'vga compatible controller|3d controller' || true)"

  if echo "$gpu_info" | grep -qi 'nvidia'; then
    info "NVIDIA-GPU erkannt. Installiere Treiber..."
    if [ "$OS_ID" = "ubuntu" ]; then
      apt_try_install ubuntu-drivers-common || true
      if ubuntu-drivers autoinstall; then
        NEED_REBOOT=1
        ok "NVIDIA-Treiber installiert (ubuntu-drivers autoinstall)."
      else
        warn "ubuntu-drivers autoinstall ist fehlgeschlagen. Treiber bitte manuell installieren."
        GPU_DRIVER_SKIPPED=1
      fi
    else
      enable_debian_nonfree_components
      if apt-cache show nvidia-driver >/dev/null 2>&1; then
        apt_try_install nvidia-driver firmware-misc-nonfree \
          || { warn "NVIDIA-Treiberpakete konnten nicht installiert werden – bitte manuell prüfen:"; \
               warn "  apt install nvidia-driver firmware-misc-nonfree"; GPU_DRIVER_SKIPPED=1; NEED_REBOOT=0; }
        if [ "$GPU_DRIVER_SKIPPED" = "0" ]; then
          NEED_REBOOT=1
          ok "NVIDIA-Treiber installiert (nvidia-driver)."
        fi
      else
        warn "Paket 'nvidia-driver' nicht gefunden. Bitte 'contrib' und 'non-free-firmware'"
        warn "in den APT-Quellen aktivieren, 'apt update' ausführen und danach:"
        warn "  apt install nvidia-driver firmware-misc-nonfree"
        GPU_DRIVER_SKIPPED=1
      fi
    fi
  elif echo "$gpu_info" | grep -qi 'amd\|ati'; then
    info "AMD-GPU erkannt. Installiere Firmware/Mesa..."
    # firmware-amd-graphics gibt es nur unter Debian – unter Ubuntu ist die
    # Firmware in linux-firmware enthalten. Fehlende Pakete nicht hart scheitern
    # lassen (früher: set -e-Abbruch mitten in der Installation).
    if [ "$OS_ID" = "ubuntu" ]; then
      apt_try_install linux-firmware libgl1-mesa-dri mesa-vulkan-drivers vainfo \
        || warn "Einige AMD-Firmware-/Mesa-Pakete fehlen – GPU-Betrieb ggf. eingeschränkt."
    else
      apt_try_install firmware-amd-graphics libgl1-mesa-dri mesa-vulkan-drivers vainfo \
        || warn "Einige AMD-Firmware-/Mesa-Pakete fehlen – GPU-Betrieb ggf. eingeschränkt."
    fi
    NEED_REBOOT=1
    ok "AMD-Grafiktreiber/Firmware installiert (soweit verfügbar)."
    warn "Für GPU-Rechenlast (KI-Modelle) benötigen manche Apps zusätzlich ROCm."
    warn "Siehe: https://rocm.docs.amd.com/ (nicht Teil dieses Skripts)."
  elif echo "$gpu_info" | grep -qi 'intel'; then
    info "Intel-GPU erkannt. Installiere Mesa/VAAPI..."
    apt_try_install intel-media-va-driver libgl1-mesa-dri \
      || warn "Intel-Mesa/VAAPI-Pakete konnten nicht installiert werden – überspringe."
    ok "Intel-Grafiktreiber installiert (soweit verfügbar)."
  else
    warn "Keine durchgereichte GPU erkannt. Pinokio wird im CPU-Modus laufen."
    warn "Siehe README.md, Abschnitt 'GPU Passthrough', um eine GPU durchzureichen."
  fi
}

# ── Dedizierten Benutzer für den Dienst anlegen ─────────────────────────────
create_service_user() {
  header "Dienstbenutzer anlegen"
  if ! id -u "$PINOKIO_USER" >/dev/null 2>&1; then
    info "Lege Systembenutzer '${PINOKIO_USER}' an..."
    useradd --create-home --home-dir "$PINOKIO_HOME" --shell /usr/sbin/nologin "$PINOKIO_USER" \
      || die "Benutzer '${PINOKIO_USER}' konnte nicht angelegt werden."
    ok "Benutzer '${PINOKIO_USER}' angelegt."
  else
    info "Benutzer '${PINOKIO_USER}' existiert bereits, überspringe."
  fi
  usermod -aG video,render "$PINOKIO_USER" 2>/dev/null || true
}

# ── Neueste Pinokio-Version ermitteln ───────────────────────────────────────
# Robust gegen GitHub-API-Ausfälle/Rate-Limiting:
#   1. GitHub-API (JSON, bevorzugt per python3 geparst, sonst grep/sed)
#   2. Fallback: HTTP-Redirect des /releases/latest-Links
# WICHTIG: Der alte Code ("TAG=$(curl | grep | sed)") hat unter
# set -euo pipefail das gesamte Skript beendet, sobald grep nichts fand –
# BEVOR der Fallback überhaupt greifen konnte. Deshalb: Ermittlung komplett in
# dieser Funktion, alle Pipelines entschärft, Funktion gibt leer oder Tag zurück.
fetch_latest_pinokio_tag() {
  local tag=""
  TMP_TAG_FILE="$(mktemp /tmp/pinokio-tag-XXXXXX)"

  if curl -fsSL --retry 3 --retry-delay 2 --max-time 30 "$PINOKIO_API_URL" -o "$TMP_TAG_FILE" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
      # Sauberes JSON-Parsing statt sprödem sed auf tag_name
      tag="$(python3 -I -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("tag_name", ""))
except Exception:
    pass' "$TMP_TAG_FILE" 2>/dev/null)" || tag=""
    else
      tag="$(grep -oE '"tag_name":[[:space:]]*"[^"]+"' "$TMP_TAG_FILE" | head -1 \
             | sed -E 's#.*"([^"]+)"$#\1#' | tr -d '\r')" || tag=""
    fi
  fi

  if [ -z "$tag" ]; then
    # Fallback: Redirect des /releases/latest-Links auswerten (GitHub-Antwort:
    # location: /pinokiocomputer/pinokio/releases/tag/vX.Y.Z)
    tag="$(curl -fsSI --retry 3 --retry-delay 2 --max-time 30 "$PINOKIO_RELEASES_URL" 2>/dev/null \
           | grep -i '^location:' | sed -E 's#.*/tag/(v?[0-9][0-9a-zA-Z.-]*).*#\1#' | tr -d '\r')" || tag=""
  fi

  rm -f "$TMP_TAG_FILE"
  TMP_TAG_FILE=""
  if [ -n "$tag" ]; then
    printf '%s' "$tag"
  fi
  return 0
}

# ── Pinokio herunterladen und installieren ──────────────────────────────────
install_pinokio_package() {
  header "Pinokio-Paket installieren"
  info "Ermittle neueste Pinokio-Version..."

  # || true ent-schärft die Zuweisung (pipefail!), Leer-Check danach,
  # erst DANN ggf. Fehler – so überlebt ein API-Ausfall den ersten Versuch.
  TAG="$(fetch_latest_pinokio_tag)" || true

  if [ -z "$TAG" ]; then
    die "Konnte die neueste Pinokio-Version nicht ermitteln (GitHub nicht erreichbar oder Rate-Limit).
Nächster Schritt: Skript später erneut ausführen (Download: ~130 MB).
  bash -c \"\$(curl -fsSL ${REPO_RAW}/install.sh)\""
  fi

  VERSION="${TAG#v}"
  DEB_NAME="Pinokio_${VERSION}_${ARCH}.deb"
  DEB_URL="https://github.com/pinokiocomputer/pinokio/releases/download/${TAG}/${DEB_NAME}"
  # .deb-Suffix behalten (apt erkennt lokale Pakete am Pfad) – mktemp-Suffix hinten.
  TMP_DEB="$(mktemp "/tmp/pinokio_${VERSION}_${ARCH}.XXXXXX.deb")"

  if [ "$MODE" = "update" ] && dpkg -s pinokio >/dev/null 2>&1 \
     && dpkg-query -W -f='${Version}' pinokio 2>/dev/null | grep -q "^${VERSION}$"; then
    ok "Pinokio ${VERSION} ist bereits installiert – keine neue Version nötig."
  else
    info "Lade Pinokio ${VERSION} (${ARCH}) herunter..."
    info "Quelle: ${DEB_URL}"
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TMP_DEB" "$DEB_URL"; then
      die "Download von Pinokio fehlgeschlagen: ${DEB_URL}
Prüfen: existiert das Asset '${DEB_NAME}' im Release ${TAG}?
  https://github.com/pinokiocomputer/pinokio/releases"
    fi
    info "Installiere Pinokio..."
    apt-get install -y -qq "$TMP_DEB" >/dev/null \
      || die "Installation des heruntergeladenen Pakets fehlgeschlagen (${TMP_DEB})."
    rm -f "$TMP_DEB"
    TMP_DEB=""
  fi

  # Das .deb installiert die Binärdatei je nach Version nach /opt/Pinokio/pinokio
  # (aktuell, kein /usr/bin-Symlink!) oder älter nach /usr/bin/pinokio – daher suchen.
  PINOKIO_BIN=""
  local cand
  for cand in /opt/Pinokio/pinokio /usr/bin/pinokio /usr/local/bin/pinokio; do
    if [ -x "$cand" ]; then
      PINOKIO_BIN="$cand"
      break
    fi
  done
  if [ -z "$PINOKIO_BIN" ]; then
    die "Installation fehlgeschlagen: Pinokio-Binary wurde nicht gefunden
(getestet: /opt/Pinokio/pinokio, /usr/bin/pinokio, /usr/local/bin/pinokio)."
  fi
  ok "Pinokio ${VERSION} installiert (${PINOKIO_BIN})."
}

# ── Pinokio vorkonfigurieren (headless, ohne GUI-Ersteinrichtung) ───────────
# Pinokio liest seine Einstellungen aus ~/.pinokio/config.json. Wird dort ein
# "home" vorgegeben, entfällt der Ordner-Auswahl-Dialog beim ersten Start und
# der Webserver ist sofort unter http://<VM-IP>:42000 erreichbar.
configure_pinokio() {
  header "Pinokio konfigurieren (Headless)"
  info "Konfiguriere Pinokio für Headless-Betrieb..."
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
  ok "Pinokio konfiguriert (Datenverzeichnis: ${PINOKIO_DATA_HOME})."
}

# ── systemd-Dienste einrichten ──────────────────────────────────────────────
setup_services() {
  header "systemd-Dienste einrichten"
  info "Richte systemd-Dienste ein..."

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

  systemctl daemon-reload \
    || die "systemctl daemon-reload fehlgeschlagen (systemd-Status prüfen: systemctl --no-pager status)."
  systemctl enable pinokio-xvfb.service pinokio.service >/dev/null 2>&1 \
    || die "systemd-Dienste konnten nicht aktiviert werden (systemctl enable pinokio-xvfb pinokio)."
  # restart statt enable --now: bei einem Update-Lauf startet so auch die neue
  # Binärversion wirklich neu (enable --now ließe einen laufenden Dienst weiterlaufen).
  systemctl restart pinokio-xvfb.service \
    || die "Dienst 'pinokio-xvfb' konnte nicht gestartet werden. Logs: journalctl -u pinokio-xvfb -e"
  systemctl restart pinokio.service \
    || die "Dienst 'pinokio' konnte nicht gestartet werden. Logs: journalctl -u pinokio -e"
  # pinokio-vnc.service bewusst NICHT aktivieren -> nur bei Bedarf manuell starten
  ok "Dienste 'pinokio-xvfb' und 'pinokio' aktiviert und gestartet."
}

# ── Healthcheck: warten, bis der Webserver auf Port 42000 antwortet ─────────
wait_for_pinokio() {
  header "Healthcheck"
  info "Warte auf Pinokio-Webserver (Port ${PINOKIO_PORT})..."
  PINOKIO_UP=0
  for _ in $(seq 1 36); do   # 36 x 5s = max. 3 Minuten
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PINOKIO_PORT}" \
       || curl -fsS -o /dev/null --max-time 3 "http://localhost:${PINOKIO_PORT}"; then
      PINOKIO_UP=1
      break
    fi
    if ! systemctl is-active --quiet pinokio.service; then
      err "Dienst 'pinokio' läuft nicht mehr. Logs: journalctl -u pinokio -e"
      break
    fi
    sleep 5
  done
  echo
  if [ "$PINOKIO_UP" = "1" ]; then
    ok "Pinokio-Webserver ist erreichbar."
  else
    warn "Pinokio-Webserver antwortet (noch) nicht auf Port ${PINOKIO_PORT}."
    warn "Logs ansehen: journalctl -u pinokio -f"
  fi

  # Firewall (falls ufw aktiv ist)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw allow "${PINOKIO_PORT}/tcp" comment "Pinokio" >/dev/null 2>&1; then
      info "ufw-Regel für Port ${PINOKIO_PORT}/tcp hinzugefügt."
    else
      warn "ufw-Regel für Port ${PINOKIO_PORT}/tcp konnte nicht gesetzt werden – manuell prüfen."
    fi
  fi
}

# ── Primäre IP ermitteln (route-src statt blindem erstem hostname -I-Eintrag) ─
detect_primary_ip() {
  local ip=""
  # 1) Quell-IP der Default-Route (die IP, unter der die VM im LAN erreichbar ist)
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2; exit}')" || true
  # 2) erste globale IPv4
  if [ -z "$ip" ]; then
    ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)" || true
  fi
  # 3) alter Fallback
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  if [ -n "$ip" ]; then
    printf '%s' "$ip"
  fi
  return 0
}

# ── Zusammenfassung ─────────────────────────────────────────────────────────
print_summary() {
  header "Zusammenfassung"
  VM_IP="$(detect_primary_ip)"
  echo
  if [ "${PINOKIO_UP:-0}" = "1" ]; then
    echo -e "  ${C_OK}${C_BOLD}════════════════════════════════════════════════════════${C_RESET}"
    echo -e "  ${C_OK}  Pinokio-Server ist fertig eingerichtet und erreichbar:${C_RESET}"
    echo -e "  ${C_OK}"
    echo -e "  ${C_OK}      http://${VM_IP:-<VM-IP>}:${PINOKIO_PORT}${C_RESET}"
    echo -e "  ${C_OK}"
    echo -e "  ${C_OK}  Einfach im Browser eines beliebigen Geräts im Netzwerk öffnen.${C_RESET}"
    echo -e "  ${C_OK}${C_BOLD}════════════════════════════════════════════════════════${C_RESET}"
    echo
  else
    warn "Installation abgeschlossen, Webserver aber (noch) nicht erreichbar."
    warn "Logs: journalctl -u pinokio -f   |   Dienst: systemctl restart pinokio"
    echo
  fi
  echo "  Pinokio-Version : ${VERSION}"
  echo "  Web-UI          : http://${VM_IP:-<VM-IP>}:${PINOKIO_PORT}"
  echo "  Datenverzeichnis: ${PINOKIO_DATA_HOME}"
  echo "  Logs            : journalctl -u pinokio -f"
  echo "  Status          : bash -c \"\$(curl -fsSL ${REPO_RAW}/install.sh)\" -- --status"
  echo
  if [ "$NEED_REBOOT" = "1" ]; then
    warn "Ein Neustart wird empfohlen, damit die GPU-Treiber vollständig geladen werden:"
    echo "    reboot"
    echo
  fi
  if [ "$GPU_DRIVER_SKIPPED" = "1" ]; then
    warn "GPU-Treiberinstallation wurde übersprungen – siehe Hinweise oben / README.md."
    echo
  fi
  info "Falls die Web-UI doch einen Einrichtungsdialog zeigt (normalerweise nicht nötig):"
  echo "    1) Auf deinem PC: ssh -L 5900:localhost:5900 root@${VM_IP:-<VM-IP>}"
  echo "    2) In der VM:     systemctl start pinokio-vnc"
  echo "    3) VNC-Viewer auf deinem PC gegen 'localhost:5900' verbinden (kein Passwort)"
  echo "    4) Pinokio-Ersteinrichtung abschließen und unter Settings 'Home Server' /"
  echo "       LAN-Zugriff aktivieren"
  echo "    5) In der VM:     systemctl stop pinokio-vnc"
  echo
  echo "Details siehe README.md."
}

# ── Status anzeigen (--status; kein Root nötig, rein lesend) ────────────────
do_status() {
  header "Pinokio-Status"
  if [ ! -d /run/systemd/system ]; then
    die "systemd läuft nicht – Pinokio-Dienste können hier nicht laufen."
  fi
  local version="" state="" enabled="" svc
  version="$(dpkg-query -W -f='${Version}' pinokio 2>/dev/null)" || version=""
  if [ -z "$version" ]; then
    warn "Pinokio ist auf diesem System NICHT installiert."
    info "Installation (in einer Debian/Ubuntu-VM als root):"
    echo "  bash -c \"\$(curl -fsSL ${REPO_RAW}/install.sh)\""
    return 0
  fi
  ok "Pinokio-Version: ${version}"
  for svc in pinokio pinokio-xvfb pinokio-vnc; do
    state="$(systemctl is-active "$svc.service" 2>/dev/null)" || state="inaktiv"
    enabled="$(systemctl is-enabled "$svc.service" 2>/dev/null)" || enabled="deaktiviert"
    if [ "$state" = "active" ]; then
      ok "  ${svc}.service : ${state} (${enabled})"
    else
      warn "  ${svc}.service : ${state} (${enabled})"
    fi
  done
  local ip=""
  ip="$(detect_primary_ip)"
  echo
  if systemctl is-active --quiet pinokio.service 2>/dev/null; then
    ok "Web-UI: http://${ip:-<VM-IP>}:${PINOKIO_PORT}   (Logs: journalctl -u pinokio -f)"
  else
    warn "Dienst 'pinokio' läuft nicht – Details: journalctl -u pinokio -e"
    warn "Neustart: systemctl restart pinokio pinokio-xvfb"
  fi
  return 0
}

# ── Deinstallation (--uninstall; Logik identisch zu uninstall.sh) ───────────
do_uninstall() {
  header "Pinokio deinstallieren"
  export DEBIAN_FRONTEND=noninteractive

  info "Stoppe und deaktiviere Dienste..."
  local svc
  for svc in pinokio.service pinokio-vnc.service pinokio-xvfb.service; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
  rm -f /etc/systemd/system/pinokio.service \
        /etc/systemd/system/pinokio-vnc.service \
        /etc/systemd/system/pinokio-xvfb.service
  systemctl daemon-reload || true
  ok "Dienste entfernt."

  if dpkg -l pinokio >/dev/null 2>&1; then
    info "Deinstalliere Pinokio-Paket..."
    apt-get purge -y -qq pinokio >/dev/null \
      || die "apt-get purge pinokio fehlgeschlagen – manuell prüfen: dpkg -l pinokio"
    ok "Pinokio-Paket entfernt."
  else
    warn "Pinokio-Paket war nicht installiert, überspringe."
  fi

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
    info "Zum vollständigen Löschen: install.sh --uninstall --purge-data"
  fi

  echo
  ok "Deinstallation abgeschlossen."
  return 0
}

# ── Installations-/Update-Ablauf ────────────────────────────────────────────
do_install() {
  if [ "$MODE" = "update" ]; then
    header "Pinokio aktualisieren (idempotenter Lauf)"
  fi
  install_base_packages
  detect_and_install_gpu_drivers
  create_service_user
  install_pinokio_package
  configure_pinokio
  setup_services
  wait_for_pinokio
  print_summary
}

# ── Hauptprogramm ───────────────────────────────────────────────────────────
main() {
  parse_args "$@"

  echo
  echo -e "  ${C_BOLD}🖥️  Pinokio AI Browser – Installer${C_RESET}"
  echo -e "  ${C_STEP}https://github.com/HatchetMan111/Pinokio-Proxmox  (Build ${SCRIPT_BUILD})${C_RESET}"
  echo -e "  ${C_STEP}Wenn hier NICHT 'Build ${SCRIPT_BUILD}' steht, führst du eine alte Kopie aus!${C_RESET}"
  echo

  if [ "$DEBUG" = "1" ]; then
    enable_debug
  fi

  # Proxmox-Host? Dann routen (gilt für Install/Update; --status/--uninstall
  # sind bewusst erlaubt, um versehentlich installierte Reste auf dem Host
  # entfernen bzw. prüfen zu können).
  if is_proxmox_host; then
    case "$MODE" in
      install|update) handle_proxmox_host ;;
      status|uninstall) ;;
    esac
  fi

  case "$MODE" in
    status)    do_status ;;
    uninstall) check_prerequisites; do_uninstall ;;
    install)   check_prerequisites; do_install ;;
  esac
}

main "$@"
