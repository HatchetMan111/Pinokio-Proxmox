#!/usr/bin/env bash
#
# Pinokio Proxmox VM Creator
# --------------------------
# Läuft auf dem Proxmox-HOST (nicht in einer VM!). Erstellt automatisch eine
# neue VM aus einem Debian/Ubuntu Cloud-Image (Cloud-Init), ermittelt deren
# IP-Adresse und installiert anschließend per SSH Pinokio als Server
# (führt intern install.sh aus diesem Repo aus) - am Ende steht die fertige
# URL http://<VM-IP>:42000 im Terminal.
#
# Aufruf (Einzeiler, auf dem Proxmox-Host als root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
#
# Wird interaktiv an einem Terminal ausgeführt, öffnet sich ein Auswahlmenü
# (wie bei den Proxmox Community-Scripts). Alle Werte lassen sich zusätzlich
# per Umgebungsvariable vorbelegen bzw. bei nicht-interaktiver Ausführung
# (z.B. in einem eigenen Automatisierungsskript) direkt setzen:
#   CORES=8 MEMORY=16384 DISK_SIZE=200 OS_IMAGE=ubuntu2404 NONINTERACTIVE=1 \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Ausgabe-Hilfsfunktionen + Fehler-Transparenz
# ----------------------------------------------------------------------------
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_STEP='\033[1;36m'; C_RESET='\033[0m'
msg_info() { echo -e "${C_INFO}➜${C_RESET} $*"; }
msg_ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
msg_warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
msg_err()  { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }

SCRIPT_BUILD="2026-08-21-v5"
echo -e "${C_STEP}Pinokio-Proxmox create-vm.sh – Build ${SCRIPT_BUILD}${C_RESET}"
echo -e "${C_STEP}Wenn hier NICHT 'Build ${SCRIPT_BUILD}' steht, führst du eine alte Kopie aus!${C_RESET}"

TOTAL_STEPS=9
step() { echo -e "\n${C_STEP}════ Schritt $1/${TOTAL_STEPS}: $2 ════${C_RESET}"; }

# Zeigt bei JEDEM unerwarteten Fehler exakt, in welcher Zeile und bei welchem
# Befehl das Skript abgebrochen ist - keine stillen Abbrüche mehr.
# Ausnahme: In Warte-Schleifen sind fehlgeschlagene Befehle erwartete
# Zwischenergebnisse (z.B. Gast-Agent noch nicht bereit). Solange QUIET_ERR=1
# ist, gibt der Trap nichts aus.
QUIET_ERR=0
on_err() {
  local ec=$?
  [ "$QUIET_ERR" = "1" ] && return 0
  echo -e "\n${C_ERR}✖ FEHLER in Zeile ${BASH_LINENO[0]}: Befehl \"${BASH_COMMAND}\" ist mit Exit-Code ${ec} fehlgeschlagen.${C_RESET}" >&2
}
trap on_err ERR

# ----------------------------------------------------------------------------
# Aktive Netzwerk-Diagnose: IP der VM auch dann finden, wenn Gast-Agent fehlt
# und die ARP-Tabelle leer bleibt (z.B. weil cloud-init/DHCP in der VM hängt).
# ----------------------------------------------------------------------------
# Lauscht auf dem Bridge-Interface nach Paketen der VM und extrahiert deren
# Quell-IP (aus ARP-Sender-Adressen oder IP-Paket-Headern).
sniff_vm_ip() {
  local mac="$1" bridge="$2" secs="$3" raw="" ip=""
  command -v tcpdump >/dev/null 2>&1 || return 0
  raw="$(timeout "$secs" tcpdump -i "$bridge" -n -l -c 200 "ether src ${mac}" 2>/dev/null || true)"
  SNIFF_PACKETS="$(echo "$raw" | grep -c . || true)"
  # 1) ARP-Sender-IP: 'who-has X tell Y' -> Y ist die IP der VM
  ip="$(echo "$raw" | grep -oE 'tell [0-9]+(\.[0-9]+){3}' | awk '{print $2}' \
      | grep -vE '^(0\.|127\.|169\.254\.)' | head -1 || true)"
  # 2) Quell-IP aus IP-Paketen (Port-Anteil am Ende abschneiden)
  if [ -z "$ip" ]; then
    ip="$(echo "$raw" | grep -oE 'IP [0-9]+(\.[0-9]+){3}(\.[0-9]+)?' \
        | sed -E 's/^IP //; s/\.[0-9]+$//' | tr -d ' ' \
        | grep -vE '^(0\.|127\.|255\.|169\.254\.)' | head -1 || true)"
  fi
  [ -n "$ip" ] && echo "$ip"
  return 0
}

# Pingt alle Hosts der /24-Subnetze der Bridge, damit deren MAC->IP-Zuordnung
# in der ARP-Tabelle des Hosts landet. Danach lohnt ein erneuter arp-Blick.
ping_sweep() {
  local cidr net prefix base i
  cidr="$(ip -4 -o addr show dev "${BRIDGE}" 2>/dev/null | awk '{print $4; exit}' || true)"
  [ -z "$cidr" ] && return 0
  prefix="${cidr#*/}"
  [ "$prefix" != "24" ] && return 0   # nur /24 zuverlässig sweep-bar
  net="${cidr%/*}"
  base="${net%.*}"
  for i in $(seq 1 254); do
    ping -c1 -W1 "${base}.${i}" >/dev/null 2>&1 &
  done
  wait 2>/dev/null || true
  return 0
}

# ----------------------------------------------------------------------------
# Schritt 1: Vorabprüfungen
# ----------------------------------------------------------------------------
step 1 "Vorabprüfungen"

if [ "$(id -u)" -ne 0 ]; then
  msg_err "Bitte als root ausführen."
  exit 1
fi
for cmd in qm pvesh pvesm python3 lspci; do
  command -v "$cmd" >/dev/null 2>&1 || { msg_err "'$cmd' nicht gefunden – dieses Skript muss auf dem Proxmox-Host laufen."; exit 1; }
done
msg_ok "Läuft auf einem Proxmox-Host."

# ----------------------------------------------------------------------------
# Konfiguration - Standardwerte (per ENV-Variable überschreibbar)
# ----------------------------------------------------------------------------
VMID="${VMID:-}"
VM_NAME="${VM_NAME:-pinokio}"
MACHINE="${MACHINE:-q35}"               # q35 (modern, empfohlen) oder i440fx (Legacy)
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"                # MB
DISK_SIZE="${DISK_SIZE:-100}"           # GB (Gesamtgröße nach Resize)
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_MODEL="${NET_MODEL:-virtio}"        # virtio (Standard) oder e1000 (Fallback-Diagnose)
OS_IMAGE="${OS_IMAGE:-debian12}"        # debian12 | debian13 | ubuntu2204 | ubuntu2404
IPCONFIG="${IPCONFIG:-ip=dhcp}"         # oder z.B. ip=192.168.1.50/24,gw=192.168.1.1
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
INSTALL_SCRIPT_URL="${INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh}"
START_VM="${START_VM:-yes}"
WAIT_FOR_PINOKIO="${WAIT_FOR_PINOKIO:-yes}"   # ja = auf http://<IP>:42000 warten, bis Pinokio installiert ist
PINOKIO_PORT="${PINOKIO_PORT:-42000}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"          # max. Wartezeit in Sekunden (30 min)
IP_WAIT_TIMEOUT="${IP_WAIT_TIMEOUT:-600}"     # max. Wartezeit auf die VM-IP in Sekunden (10 min)
PCI_HOSTPCI="${PCI_HOSTPCI:-}"           # z.B. "01:00" -> GPU direkt bei Erstellung durchreichen
NONINTERACTIVE="${NONINTERACTIVE:-}"     # 1 = Assistent überspringen, nur ENV-Variablen/Standardwerte nutzen

# ----------------------------------------------------------------------------
# Interaktiver Assistent (whiptail) - wie bei den Proxmox Community-Scripts
# ----------------------------------------------------------------------------
wt() {
  # Wrapper um whiptail: korrekt gefangenes Abbrechen (ESC/Cancel) fuehrt zu
  # sauberem Skriptabbruch statt zu einem stillen set-e-Fehler.
  whiptail "$@" 3>&1 1>&2 2>&3
}

run_wizard() {
  whiptail --title "Pinokio Proxmox VM" --msgbox \
"Dieser Assistent legt eine neue VM an, in der sich Pinokio danach automatisch selbst installiert.\n\nNavigation: Pfeiltasten, Leertaste/Enter bestätigt, ESC bricht ab." 12 74

  MACHINE=$(wt --title "Maschinentyp" --default-item "$MACHINE" --menu \
"q35 = moderner Standard-Chipsatz, PCIe-fähig, Voraussetzung für GPU-Passthrough (empfohlen).
i440fx = alter Legacy-Chipsatz, nur bei konkretem Bedarf wählen." \
    17 76 2 \
    "q35" "Modern, PCIe/GPU-Passthrough (Standard)" \
    "i440fx" "Legacy-Chipsatz") || { msg_err "Abgebrochen."; exit 1; }

  OS_IMAGE=$(wt --title "Betriebssystem" --default-item "$OS_IMAGE" --menu "Cloud-Image auswählen:" 17 76 4 \
    "debian12" "Debian 12 Bookworm (Standard)" \
    "debian13" "Debian 13 Trixie" \
    "ubuntu2204" "Ubuntu 22.04 LTS" \
    "ubuntu2404" "Ubuntu 24.04 LTS") || { msg_err "Abgebrochen."; exit 1; }

  VMID=$(wt --title "VM-ID" --inputbox "VM-ID (leer lassen = nächste freie automatisch):" 10 70 "$VMID") || { msg_err "Abgebrochen."; exit 1; }
  VM_NAME=$(wt --title "Name" --inputbox "Hostname/Name der VM:" 10 70 "$VM_NAME") || { msg_err "Abgebrochen."; exit 1; }
  CORES=$(wt --title "CPU-Kerne" --inputbox "Anzahl vCPUs:" 10 70 "$CORES") || { msg_err "Abgebrochen."; exit 1; }
  MEMORY=$(wt --title "Arbeitsspeicher" --inputbox "RAM in MB:" 10 70 "$MEMORY") || { msg_err "Abgebrochen."; exit 1; }
  DISK_SIZE=$(wt --title "Festplatte" --inputbox "Festplattengröße in GB:" 10 70 "$DISK_SIZE") || { msg_err "Abgebrochen."; exit 1; }

  # Storage-Auswahl aus tatsächlich vorhandenen Storages des Hosts
  local storage_menu=() sname stype sstatus
  while read -r sname stype sstatus _; do
    if [ -z "$sname" ] || [ "$sname" = "Name" ]; then
      continue
    fi
    storage_menu+=("$sname" "$stype ($sstatus)")
  done < <(pvesm status 2>/dev/null || true)
  if [ "${#storage_menu[@]}" -gt 0 ]; then
    STORAGE=$(wt --title "Storage" --default-item "$STORAGE" --menu "Ziel-Storage für die VM-Disks:" 20 76 8 "${storage_menu[@]}") || { msg_err "Abgebrochen."; exit 1; }
  fi

  # Bridge-Auswahl aus tatsächlich vorhandenen Bridges des Hosts
  local bridge_menu=() b bn
  for b in /sys/class/net/vmbr*; do
    [ -e "$b" ] || continue
    bn="$(basename "$b")"
    bridge_menu+=("$bn" "")
  done
  if [ "${#bridge_menu[@]}" -gt 0 ]; then
    BRIDGE=$(wt --title "Netzwerk-Bridge" --default-item "$BRIDGE" --menu "Bridge auswählen:" 16 76 6 "${bridge_menu[@]}") || { msg_err "Abgebrochen."; exit 1; }
  fi

  if wt --title "Netzwerk" --yesno "IP-Adresse per DHCP beziehen?\n\n(Nein = statische IP manuell eingeben)" 11 70; then
    IPCONFIG="ip=dhcp"
  else
    local static_ip static_gw
    static_ip=$(wt --title "Statische IP" --inputbox "IP-Adresse inkl. Prefix, z.B. 192.168.1.50/24:" 10 70 "") || { msg_err "Abgebrochen."; exit 1; }
    static_gw=$(wt --title "Gateway" --inputbox "Gateway-IP, z.B. 192.168.1.1:" 10 70 "") || { msg_err "Abgebrochen."; exit 1; }
    IPCONFIG="ip=${static_ip},gw=${static_gw}"
  fi

  PCI_HOSTPCI=""
  if wt --title "GPU-Passthrough" --defaultno --yesno \
"Jetzt schon eine GPU durchreichen?\n\nDas Host-seitige IOMMU/vfio-Setup muss dafür bereits erledigt sein (siehe README). Kann auch jederzeit später nachgerüstet werden - hier \"Nein\" ist der sichere Standard." 13 76; then
    local pci_menu=() pciid pcidesc
    while read -r pciid pcidesc; do
      if [ -z "$pciid" ]; then
        continue
      fi
      pci_menu+=("$pciid" "$pcidesc")
    done < <(lspci -nn 2>/dev/null | grep -Ei 'vga compatible controller|3d controller' || true)
    if [ "${#pci_menu[@]}" -gt 0 ]; then
      PCI_HOSTPCI=$(wt --title "GPU auswählen" --menu "PCI-Gerät:" 16 76 6 "${pci_menu[@]}") || PCI_HOSTPCI=""
    else
      whiptail --title "GPU-Passthrough" --msgbox "Keine passende GPU über lspci gefunden - überspringe." 10 70
    fi
  fi

  whiptail --title "Zusammenfassung" --yesno \
"VMID:      ${VMID:-automatisch}
Name:      ${VM_NAME}
Maschine:  ${MACHINE}
OS-Image:  ${OS_IMAGE}
Cores:     ${CORES}    RAM: ${MEMORY} MB    Disk: ${DISK_SIZE} GB
Storage:   ${STORAGE}
Bridge:    ${BRIDGE}
Netzwerk:  ${IPCONFIG}
GPU:       ${PCI_HOSTPCI:-keine}

Jetzt erstellen?" 19 74 || { msg_err "Abgebrochen."; exit 1; }
}

if [ -z "$NONINTERACTIVE" ] && [ -t 0 ] && [ -t 1 ]; then
  if ! command -v whiptail >/dev/null 2>&1; then
    msg_info "Installiere whiptail für den interaktiven Assistenten..."
    apt-get install -y -qq whiptail >/dev/null 2>&1 || true
  fi
  if command -v whiptail >/dev/null 2>&1; then
    run_wizard
  else
    msg_warn "whiptail nicht verfügbar, fahre mit ENV-Variablen/Standardwerten fort."
  fi
else
  msg_info "Nicht-interaktiver Modus - verwende ENV-Variablen/Standardwerte."
fi

case "$MACHINE" in
  q35|i440fx) ;;
  *) msg_err "Unbekannter MACHINE-Typ: ${MACHINE} (erlaubt: q35, i440fx)"; exit 1 ;;
esac

if [ -z "$VMID" ]; then
  VMID="$(pvesh get /cluster/nextid)"
fi
if qm status "$VMID" >/dev/null 2>&1; then
  msg_err "VMID ${VMID} existiert bereits. Andere VMID mit VMID=<id> angeben."
  exit 1
fi
msg_ok "Konfiguration steht. Verwende VMID ${VMID} (Maschine: ${MACHINE})."

# ----------------------------------------------------------------------------
# Schritt 2: SSH-Key ermitteln (für root-Login in der VM)
# ----------------------------------------------------------------------------
step 2 "SSH-Key ermitteln"

if [ -z "$SSH_PUBKEY_FILE" ]; then
  for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    if [ -f "$f" ]; then
      SSH_PUBKEY_FILE="$f"
      break
    fi
  done
fi
if [ -z "$SSH_PUBKEY_FILE" ] || [ ! -f "$SSH_PUBKEY_FILE" ]; then
  msg_warn "Kein bestehender SSH-Key auf dem Host gefunden. Erzeuge einen neuen..."
  mkdir -p /root/.ssh
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/pinokio_vm_key -q
  SSH_PUBKEY_FILE="/root/.ssh/pinokio_vm_key.pub"
  msg_warn "Neuer privater Schlüssel liegt auf dem Host unter: /root/.ssh/pinokio_vm_key"
fi
msg_ok "SSH-Key: ${SSH_PUBKEY_FILE}"

# Notfall-Konsolenpasswort: funktioniert NUR über die lokale Konsole
# (qm terminal / noVNC), NICHT über SSH (ssh_pwauth bleibt deaktiviert).
CONSOLE_PASSWORD="$(openssl rand -base64 12 2>/dev/null | tr -d '=+/' | head -c 16)"
if [ -z "$CONSOLE_PASSWORD" ]; then
  CONSOLE_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)"
fi

# ----------------------------------------------------------------------------
# Schritt 3: Cloud-Image herunterladen (mit lokalem Cache)
# ----------------------------------------------------------------------------
step 3 "Cloud-Image herunterladen"

HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$HOST_ARCH" in
  amd64|x86_64) IMG_ARCH="amd64" ;;
  arm64|aarch64) IMG_ARCH="arm64" ;;
  *)
    msg_err "Nicht unterstützte Host-Architektur: ${HOST_ARCH} (nur amd64/arm64)."
    exit 1
    ;;
esac

case "$OS_IMAGE" in
  debian12)   IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-${IMG_ARCH}.qcow2" ;;
  debian13)   IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-${IMG_ARCH}.qcow2" ;;
  ubuntu2204) IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-${IMG_ARCH}.img" ;;
  ubuntu2404) IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${IMG_ARCH}.img" ;;
  *)
    msg_err "Unbekanntes OS_IMAGE: ${OS_IMAGE} (erlaubt: debian12, debian13, ubuntu2204, ubuntu2404)"
    exit 1
    ;;
esac
IMG_FILE="${IMG_URL##*/}"
CACHE_DIR="/var/lib/vz/template/pinokio-cache"
mkdir -p "$CACHE_DIR"
IMG_PATH="${CACHE_DIR}/${IMG_FILE}"

# IMG_REDOWNLOAD=yes erzwingt frischen Download (z.B. bei Verdacht auf korrupten Cache)
if [ "${IMG_REDOWNLOAD:-}" = "yes" ] && [ -f "$IMG_PATH" ]; then
  msg_warn "IMG_REDOWNLOAD=yes: lösche gecachtes Image (${IMG_PATH})."
  rm -f "$IMG_PATH"
fi

if [ -f "$IMG_PATH" ]; then
  msg_info "Cloud-Image bereits im Cache, überspringe Download (${IMG_PATH})."
else
  msg_info "Lade Cloud-Image herunter (${OS_IMAGE})..."
  curl -fL --progress-bar -o "$IMG_PATH" "$IMG_URL"
  msg_ok "Download abgeschlossen."
fi

# Integritätsprüfung: Ein korruptes/trunkiertes Image bootet evtl. teilweise,
# produziert aber im Gast beliebige Folgefehler (z.B. cloud-init ohne Netz).
if ! qemu-img check "$IMG_PATH" >/dev/null 2>&1; then
  msg_warn "qemu-img check meldet Fehler im Image (${IMG_PATH}) - lösche und lade neu..."
  rm -f "$IMG_PATH"
  curl -fL --progress-bar -o "$IMG_PATH" "$IMG_URL"
  if ! qemu-img check "$IMG_PATH" >/dev/null 2>&1; then
    msg_err "Auch das frisch heruntergeladene Image ist fehlerhaft. Abbruch."
    exit 1
  fi
fi
msg_info "Image OK: $(du -h "$IMG_PATH" | awk '{print $1}'), geändert am $(stat -c %y "$IMG_PATH" | cut -d. -f1) ($(qemu-img info "$IMG_PATH" | grep '^virtual size' || true))"

# Prüfsummen-Verifikation gegen die offiziellen Hashes des Image-Anbieters.
# Ein korrupter/partieller Download kann strukturell intakt wirken (qemu-img
# check besteht), im Gast aber beliebige Pakete verlieren (z.B. cloud-init!).
verify_image_checksum() {
  local sums_url sum_file algo expected actual
  for entry in "SHA512SUMS:sha512sum" "SHA256SUMS:sha256sum"; do
    sum_file="${entry%%:*}"; algo="${entry##*:}"
    sums_url="${IMG_URL%/*}/${sum_file}"
    local tmp_sums="/tmp/pinokio-${sum_file}.$$"
    if curl -fsSL --max-time 30 "$sums_url" -o "$tmp_sums" 2>/dev/null; then
      expected="$(grep -E "[[:space:]]${IMG_FILE//./\\.}\$" "$tmp_sums" | awk '{print $1}' | head -1)"
      rm -f "$tmp_sums"
      if [ -n "$expected" ]; then
        actual="$($algo "$IMG_PATH" | awk '{print $1}')"
        if [ "$expected" != "$actual" ]; then
          msg_err "PRÜFSUMME FALSCH: ${IMG_FILE}"
          msg_err "  erwartet (${algo}): ${expected}"
          msg_err "  tatsächlich      : ${actual}"
          return 1
        fi
        msg_ok "Prüfsumme verifiziert (${algo}): Image ist original."
        return 0
      fi
    fi
  done
  msg_warn "Konnte keine offizielle Prüfsummendatei laden - Überspringe Verifikation."
  return 0
}

if ! verify_image_checksum; then
  msg_warn "Lösche das fehlerhafte Image und lade neu herunter..."
  rm -f "$IMG_PATH"
  curl -fL --progress-bar -o "$IMG_PATH" "$IMG_URL"
  if ! verify_image_checksum || ! qemu-img check "$IMG_PATH" >/dev/null 2>&1; then
    msg_err "Auch nach erneutem Download ist das Image fehlerhaft. Abbruch."
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Schritt 4: Cloud-Init-Zugangsdaten (Proxmox-native, ohne Custom-Snippets)
# ----------------------------------------------------------------------------
# Bewusst KEIN cicustom-Snippet: Passwort und SSH-Key werden über die
# nativen Proxmox-Mechanismen (--cipassword/--sshkeys) gesetzt. Das ist der
# am weitesten verbreitete und getestete Weg; ein fehlerhaftes/ignoriertes
# Custom-User-Data war die Ursache dafür, dass weder Passwort noch Netzwerk
# in der VM ankommen konnten.
step 4 "Cloud-Init-Zugangsdaten setzen"

if [ ! -s "${SSH_PUBKEY_FILE}" ]; then
  msg_err "SSH-Public-Key-Datei ist leer oder fehlt: ${SSH_PUBKEY_FILE}"
  exit 1
fi
msg_ok "Root-Passwort (nur lokale Konsole) und SSH-Key (${SSH_PUBKEY_FILE}) werden per Cloud-Init gesetzt."

# ----------------------------------------------------------------------------
# Schritt 5: VM erstellen
# ----------------------------------------------------------------------------
step 5 "VM erstellen"

CREATE_ARGS=(
  --name "$VM_NAME"
  --machine "$MACHINE"
  --bios ovmf
  --efidisk0 "${STORAGE}:0,pre-enrolled-keys=0"
  --cores "$CORES"
  --memory "$MEMORY"
  --cpu host
  --net0 "${NET_MODEL},bridge=${BRIDGE},firewall=0"
  --scsihw virtio-scsi-pci
  --scsi0 "${STORAGE}:0,import-from=${IMG_PATH}"
  --ide2 "${STORAGE}:cloudinit"
  --boot order=scsi0
  --serial0 socket
  --agent enabled=1
  --ostype l26
  --onboot 1
  --ciuser root
  --cipassword "$CONSOLE_PASSWORD"
  --sshkeys "$SSH_PUBKEY_FILE"
  --ipconfig0 "$IPCONFIG"
)

if [ -n "$PCI_HOSTPCI" ]; then
  CREATE_ARGS+=(--hostpci0 "${PCI_HOSTPCI},pcie=1,x-vga=1")
  msg_info "GPU ${PCI_HOSTPCI} wird direkt bei der Erstellung durchgereicht."
fi

qm create "$VMID" "${CREATE_ARGS[@]}"
qm resize "$VMID" scsi0 "${DISK_SIZE}G" >/dev/null
msg_ok "VM ${VMID} erstellt (${MACHINE} + OVMF/UEFI, ${DISK_SIZE}G Disk)."

# ----------------------------------------------------------------------------
# Schritt 6: VM starten
# ----------------------------------------------------------------------------
step 6 "VM starten"

VM_IP=""
if [ "$START_VM" = "yes" ]; then
  qm start "$VMID"
  msg_ok "VM gestartet."

  # --------------------------------------------------------------------------
  # Schritt 7: Auf IP-Adresse warten
  # --------------------------------------------------------------------------
  step 7 "Auf IP-Adresse warten"

  # Ab hier sind "noch keine IP", "grep findet nichts", "Agent noch nicht da"
  # normale Zwischenergebnisse beim Warten - kein echter Fehler. set -e wird
  # deshalb für diesen gesamten Erkennungsabschnitt gezielt deaktiviert und
  # der ERR-Trap verstummt (QUIET_ERR), damit es keine Fehlerspam-Ausgaben gibt.
  set +e
  QUIET_ERR=1

  MAC="$(qm config "$VMID" 2>/dev/null | grep -oE '^net0:.*' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1)"
  MAX_WAIT_ITER=$((IP_WAIT_TIMEOUT / 5))   # Standard: 600s / 5s = 120 Iterationen = 10 Minuten
  msg_info "MAC-Adresse der VM: ${MAC:-unbekannt}"

  for i in $(seq 1 "$MAX_WAIT_ITER"); do
    sleep 5

    AGENT_STATE="nicht erreichbar"
    IFACES_JSON="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null)"
    if [ -n "$IFACES_JSON" ]; then
      AGENT_STATE="läuft"
      VM_IP="$(echo "$IFACES_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for iface in data:
    if iface.get("name") == "lo":
        continue
    for addr in iface.get("ip-addresses", []):
        ip = addr.get("ip-address", "")
        if addr.get("ip-address-type") == "ipv4" and not ip.startswith("127."):
            print(ip)
            sys.exit(0)
' 2>/dev/null)"
    fi

    ARP_STATE="kein Eintrag"
    if [ -z "$VM_IP" ] && [ -n "$MAC" ]; then
      VM_IP="$(ip neigh show 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1)"
      if [ -n "$VM_IP" ]; then
        ARP_STATE="gefunden"
      fi
    fi

    if [ -n "$VM_IP" ]; then
      break
    fi

    # Alle 30 Sekunden Status mit sichtbarem Fortschritt, WAS genau versucht wurde
    if [ $((i % 6)) -eq 0 ]; then
      msg_info "... $((i * 5))s / ${IP_WAIT_TIMEOUT}s | Gast-Agent: ${AGENT_STATE} | ARP-Tabelle: ${ARP_STATE}"
    fi
  done

  set -e        # ab hier wieder normales Fehlverhalten
  QUIET_ERR=0

  if [ -n "$VM_IP" ]; then
    msg_ok "IP-Adresse gefunden: ${VM_IP}"
  else
    msg_warn "Gast-Agent und ARP-Tabelle liefern nach $((MAX_WAIT_ITER * 5 / 60)) Minuten nichts."
    msg_info "Starte aktive Diagnose: Lausche auf ${BRIDGE} und scanne das Subnetz..."

    # tcpdump ggf. nachinstallieren (nicht kritisch, falls nicht möglich)
    if ! command -v tcpdump >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null 2>&1 || true
    fi

    # Diagnosebereich: hier sind "nichts gefunden"-Ergebnisse normal -> Trap still
    QUIET_ERR=1

    # Ist der Tap-Geräte-Port der VM überhaupt an der Bridge angeschlossen?
    TAP_DEV="tap${VMID}i0"
    if ip link show "$TAP_DEV" >/dev/null 2>&1; then
      if ip link show "$TAP_DEV" | grep -q "master ${BRIDGE}"; then
        msg_ok "${TAP_DEV} ist an ${BRIDGE} angeschlossen."
      else
        msg_warn "Diagnose: ${TAP_DEV} existiert, hängt aber NICHT an ${BRIDGE}! (master: $(ip link show "$TAP_DEV" | grep -oE 'master [^ ]+' || echo 'keine'))"
      fi
    else
      msg_warn "Diagnose: Tap-Gerät ${TAP_DEV} existiert nicht - VM-NIC nicht verbunden?"
    fi

    SNIFF_PACKETS=0
    if [ -n "$MAC" ] && command -v tcpdump >/dev/null 2>&1; then
      # 1) Direkt am Tap lauschen: Zeigt Pakete, die der GUEST selbst sendet
      if ip link show "$TAP_DEV" >/dev/null 2>&1; then
        msg_info "Lausche 20s direkt an ${TAP_DEV} (was sendet der Gast?)..."
        VM_IP="$(sniff_vm_ip "$MAC" "$TAP_DEV" 20)"
        if [ -n "$VM_IP" ]; then
          msg_ok "IP aus dem Traffic des Gastes ermittelt: ${VM_IP}"
        elif [ "${SNIFF_PACKETS:-0}" -eq 0 ]; then
          DIAG_NO_TRAFFIC=1
          msg_warn "Diagnose: Der Gast sendet NICHT EINMAL am Tap-Gerät (${TAP_DEV}) etwas."
          msg_warn "=> Das Netzwerk im Gast ist tot (cloud-init läuft nicht / kein DHCP-Versuch)."
          msg_warn "=> Bitte beim nächsten Lauf direkt nach VM-Start 'qm terminal ${VMID}' öffnen"
          msg_warn "   und die Boot-Zeilen (insbesondere alles mit 'Cloud-init') hier posten."
        else
          DIAG_TAP_OK=1
          msg_info "Der Gast sendet Pakete am Tap (${SNIFF_PACKETS} gesehen) - prüfe Bridge-Weiterleitung..."
        fi
      fi
      # 2) Fallback: an der Bridge lauschen
      if [ -z "$VM_IP" ] && [ "${DIAG_NO_TRAFFIC:-0}" != "1" ]; then
        VM_IP="$(sniff_vm_ip "$MAC" "$BRIDGE" 20)"
        if [ -n "$VM_IP" ]; then
          msg_ok "IP aus dem Netzwerk-Traffic ermittelt: ${VM_IP}"
        elif [ "${SNIFF_PACKETS:-0}" -eq 0 ] && [ "${DIAG_TAP_OK:-0}" = "1" ]; then
          msg_warn "Diagnose: Gast sendet am Tap, aber NICHTS kommt an ${BRIDGE} an -"
          msg_warn "=> Bridge-Weiterleitung/Firewall blockt (pve-firewall status prüfen!)."
        fi
      fi
    fi

    if [ -z "$VM_IP" ] && [ -n "$MAC" ]; then
      msg_info "Ping-Sweep über das Subnetz der Bridge (dauert ~10s), danach erneuter ARP-Blick..."
      ping_sweep
      VM_IP="$(ip neigh show 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1 || true)"
      [ -n "$VM_IP" ] && msg_ok "IP nach Ping-Sweep gefunden: ${VM_IP}"
    fi

    QUIET_ERR=0

    # Tiefendiagnose: Wenn der Gast komplett schweigt, mounten wir seine Disk
    # vom Host aus (read-only) und lesen die Cloud-Init-Logs des Gastes.
    # Das liefert die definitve Ursache, ohne Login/Netzwerk zu benötigen.
    if [ "${DIAG_NO_TRAFFIC:-0}" = "1" ] && [ "${DEEP_DIAG:-yes}" != "no" ]; then
      msg_info "Tiefendiagnose: Stoppe VM, mounte Disk read-only, lese Gast-Logs..."
      DEEP_FILE="/tmp/pinokio-deepdiag-${VMID}.txt"
      NBD_DEV="/dev/nbd0"
      MNT="/mnt/pinokio-diag"

      (
        set +e
        qm stop "$VMID" >/dev/null 2>&1
        SCASI_LINE="$(qm config "$VMID" 2>/dev/null | awk '/^scsi0:/{print $2}' | head -1)"
        VOL_SPEC="${SCASI_LINE%%,*}"
        VOL_DEV="$(pvesm path "$VOL_SPEC" 2>/dev/null)"
        [ -z "$VOL_DEV" ] && exit 1
        modprobe nbd max_part=16 >/dev/null 2>&1
        [ -b "$NBD_DEV" ] || exit 1
        qemu-nbd -c "$NBD_DEV" --read-only "$VOL_DEV" >/dev/null 2>&1
        sleep 1
        partprobe "$NBD_DEV" >/dev/null 2>&1
        mkdir -p "$MNT"
        ROOT_PART=""
        for p in "${NBD_DEV}p1" "${NBD_DEV}p2" "${NBD_DEV}p15" "$NBD_DEV"; do
          if [ -b "$p" ] && blkid -o value -s TYPE "$p" 2>/dev/null | grep -qE '^ext[234]$'; then
            if mount -o ro "$p" "$MNT" 2>/dev/null; then ROOT_PART="$p"; break; fi
          fi
        done
        {
          echo "=== Root-Partition: ${ROOT_PART:-NICHT GEFUNDEN}"
          echo
          echo "=== Ist cloud-init ueberhaupt installiert?"
          ls -la "$MNT/usr/bin/cloud-init" 2>&1 || true
          echo
          echo "=== /etc/cloud Verzeichnis"
          ls "$MNT/etc/cloud/" 2>&1 || true
          ls "$MNT/etc/cloud/cloud.cfg.d/" 2>&1 || true
          echo
          echo "=== Netzwerk-Konfiguration im Gast"
          echo "--- /etc/network/interfaces:"
          cat "$MNT/etc/network/interfaces" 2>&1 || true
          echo "--- /etc/network/interfaces.d/:"
          ls "$MNT/etc/network/interfaces.d/" 2>&1 || true
          cat "$MNT/etc/network/interfaces.d/"* 2>/dev/null || true
          echo "--- /etc/netplan/:"
          ls "$MNT/etc/netplan/" 2>&1 || true
          cat "$MNT/etc/netplan/"* 2>/dev/null || true
          echo
          echo "=== /var/log/cloud-init.log (letzte 80 Zeilen)"
          tail -80 "$MNT/var/log/cloud-init.log" 2>&1 || true
          echo
          echo "=== /var/log/cloud-init-output.log (letzte 50 Zeilen)"
          tail -50 "$MNT/var/log/cloud-init-output.log" 2>&1 || true
          echo
          echo "=== /var/lib/cloud Struktur"
          find "$MNT/var/lib/cloud" -maxdepth 3 2>&1 | head -40 || true
        } > "$DEEP_FILE" 2>&1
        umount "$MNT" >/dev/null 2>&1
        qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1
      ) || true

      qm start "$VMID" >/dev/null 2>&1 || true

      if [ -s "$DEEP_FILE" ]; then
        msg_ok "Gast-Logs extrahiert ($DEEP_FILE):"
        echo -e "${C_STEP}──────────────── BEGINN GAST-DIAGNOSE ────────────────${C_RESET}"
        cat "$DEEP_FILE"
        echo -e "${C_STEP}───────────────── ENDE GAST-DIAGNOSE ─────────────────${C_RESET}"
        msg_warn "Bitte diesen Abschnitt vollständig kopieren und beim Issue melden."
      else
        msg_warn "Tiefendiagnose fehlgeschlagen (nbd/mount nicht möglich?). Log manuell prüfen."
      fi
    fi

    if [ -z "$VM_IP" ]; then
      msg_warn "Konnte die IP-Adresse auch mit aktiver Diagnose nicht ermitteln."
      if [ "${DIAG_NO_TRAFFIC:-0}" = "1" ]; then
        msg_warn "Nächster Schritt: Proxmox-WebUI -> VM -> Console öffnen und die Boot-/Cloud-Init-"
        msg_warn "Ausgabe prüfen. Alternativ anderes OS testen: OS_IMAGE=ubuntu2404 beim Neuerstellen."
      elif [ "${DIAG_DHCP_ONLY:-0}" = "1" ]; then
        msg_warn "Nächster Schritt: VM neu erstellen MIT statischer IP, z.B.:"
        msg_warn "  IPCONFIG=\"ip=<freie-IP>/24,gw=<Gateway>\" bash -c \"\$(curl -fsSL <create-vm-url>)\""
      fi
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Schritt 8: Pinokio per SSH installieren und auf Webserver warten
# ----------------------------------------------------------------------------
if [ -n "$VM_IP" ] && [ "$WAIT_FOR_PINOKIO" = "yes" ]; then
  step 8 "Pinokio installieren (per SSH auf ${VM_IP})"

  # 8a: Auf SSH warten (sshd läuft in Cloud-Images sofort nach dem Boot)
  msg_info "Warte auf SSH-Port 22..."
  set +e
  QUIET_ERR=1
  SSH_READY=0
  for _ in $(seq 1 60); do   # 60 x 5s = max. 5 Minuten
    if timeout 3 bash -c "</dev/tcp/${VM_IP}/22" 2>/dev/null; then
      SSH_READY=1
      break
    fi
    sleep 5
  done
  QUIET_ERR=0
  set -e

  if [ "$SSH_READY" != "1" ]; then
    msg_err "SSH auf ${VM_IP} nach 5 Minuten nicht erreichbar – Installation kann nicht starten."
    msg_err "Manuell prüfen: ssh -i ${SSH_PUBKEY_FILE%.pub} root@${VM_IP}"
    exit 1
  fi
  msg_ok "SSH erreichbar."

  # 8b: install.sh herunterladen und in der VM ausführen (Output wird live gestreamt)
  TMP_INSTALL="/tmp/pinokio-install-$$.sh"
  curl -fsSL "${INSTALL_SCRIPT_URL}" -o "${TMP_INSTALL}"
  msg_info "Führe install.sh in der VM aus (dauert einige Minuten, Output live)..."
  ssh -i "${SSH_PUBKEY_FILE%.pub}" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o LogLevel=ERROR \
      "root@${VM_IP}" 'bash -s' < "${TMP_INSTALL}"
  rm -f "${TMP_INSTALL}"

  # 8c: Auf den Pinokio-Webserver warten
  msg_info "Warte auf Pinokio-Webserver (Port ${PINOKIO_PORT})..."
  set +e
  QUIET_ERR=1
  PINOKIO_READY=0
  ELAPSED=0
  while [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ]; do
    if timeout 3 bash -c "</dev/tcp/${VM_IP}/${PINOKIO_PORT}" 2>/dev/null; then
      PINOKIO_READY=1
      break
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    # Status alle 2 Minuten ausgeben
    if [ $((ELAPSED % 120)) -eq 0 ]; then
      msg_info "... ${ELAPSED}s vergangen - Installation läuft noch"
    fi
  done
  set -e
  QUIET_ERR=0

  if [ "$PINOKIO_READY" = "1" ]; then
    msg_ok "Pinokio-Server ist online!"
  else
    msg_warn "Port ${PINOKIO_PORT} nach $((WAIT_TIMEOUT / 60)) Minuten nicht erreichbar."
    msg_warn "In der VM prüfen: journalctl -u pinokio -e"
  fi
else
  PINOKIO_READY=0
fi

# ----------------------------------------------------------------------------
# Schritt 9: Zusammenfassung
# ----------------------------------------------------------------------------
step 9 "Zusammenfassung"

echo
if [ "${PINOKIO_READY:-0}" = "1" ]; then
  msg_ok "Fertig! Pinokio ist installiert und der Server läuft."
else
  msg_warn "VM erstellt, aber Pinokio-Installation noch nicht abgeschlossen (siehe Hinweise unten)."
fi
echo
echo "  VMID          : ${VMID}"
echo "  Name          : ${VM_NAME}"
echo "  Maschine      : ${MACHINE}"
echo "  SSH-Key       : ${SSH_PUBKEY_FILE}"
echo "  Konsolen-PW   : ${CONSOLE_PASSWORD}  (NUR lokal über 'qm terminal ${VMID}' / Proxmox-Konsole, nicht per SSH)"
if [ -n "$VM_IP" ]; then
  echo "  VM-IP         : ${VM_IP}"
fi
echo

# Erfolg: Pinokio ist erreichbar -> großes Abschluss-Banner mit der URL
if [ "${PINOKIO_READY:-0}" = "1" ]; then
  echo
  msg_ok "════════════════════════════════════════════════════════"
  msg_ok "  Pinokio-Server ist fertig eingerichtet und erreichbar:"
  msg_ok ""
  msg_ok "    ${C_OK}http://${VM_IP}:${PINOKIO_PORT}${C_RESET}"
  msg_ok ""
  msg_ok "  Einfach im Browser eines beliebigen Geräts im Netzwerk öffnen."
  msg_ok "════════════════════════════════════════════════════════"
  echo
  exit 0
fi

if [ -z "$VM_IP" ]; then
  msg_warn "Automatische IP-Erkennung fehlgeschlagen (kein DHCP über den Host sichtbar und/oder"
  msg_warn "Gast-Agent noch nicht bereit). Öffne jetzt automatisch die Konsole - dort einfach"
  msg_warn "einloggen und die IP selbst ablesen:"
  echo
  echo "    Login:    root"
  echo "    Passwort: ${CONSOLE_PASSWORD}"
  echo
  msg_warn "WICHTIG: Das Root-Passwort wird erst von cloud-init gesetzt - das dauert nach"
  msg_warn "dem ersten Boot ca. 2-5 Minuten. Kommt 'Login incorrect', ist cloud-init"
  msg_warn "noch nicht fertig: einfach 1-2 Minuten warten und erneut versuchen."
  echo
  echo "  In der Konsole nach dem Login ausführen:"
  echo "    ip a                              # zeigt die IP-Adresse"
  echo "    cloud-init status                 # zeigt, ob Cloud-Init noch läuft oder fehlgeschlagen ist"
  echo "    journalctl -u cloud-init -b       # Details bei Fehlern"
  echo
  echo "  Konsole verlassen mit: Strg+O, dann Strg+Q"
  echo
  msg_info "Öffne Konsole in 3 Sekunden..."
  sleep 3
  if [ -t 0 ]; then
    qm terminal "$VMID" || true
  else
    msg_warn "Kein interaktives Terminal (Skript lief per curl|bash) - Konsole manuell öffnen:"
    msg_warn "  Proxmox-WebUI -> VM ${VMID} -> Console   oder:   qm terminal ${VMID}"
  fi
  echo
  msg_info "Sobald du die IP kennst, Pinokio installieren mit:"
  echo "    curl -fsSL ${INSTALL_SCRIPT_URL} -o /tmp/i.sh && ssh -i ${SSH_PUBKEY_FILE%.pub} root@<VM-IP> 'bash -s' < /tmp/i.sh"
  echo "    http://<VM-IP>:42000"
  exit 0
fi

msg_info "Installation später nachholen oder Logs ansehen:"
echo "    ssh -i ${SSH_PUBKEY_FILE%.pub} root@${VM_IP}"
echo
msg_info "Sobald Port ${PINOKIO_PORT} antwortet, ist der Server fertig erreichbar unter:"
echo "    http://${VM_IP}:${PINOKIO_PORT}"
echo
if [ "$WAIT_FOR_PINOKIO" = "yes" ]; then
  msg_warn "Das Warten auf Port ${PINOKIO_PORT} wurde nach $((WAIT_TIMEOUT / 60)) Minuten abgebrochen."
else
  msg_warn "Das Warten auf Port ${PINOKIO_PORT} wurde übersprungen (WAIT_FOR_PINOKIO=no)."
fi
msg_info "Selbst prüfen, ob der Server schon online ist:"
echo "    timeout 3 bash -c '</dev/tcp/${VM_IP}/${PINOKIO_PORT}' && echo online || echo noch nicht bereit"
echo
