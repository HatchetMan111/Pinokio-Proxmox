#!/usr/bin/env bash
#
# Pinokio Proxmox VM Creator
# --------------------------
# Läuft auf dem Proxmox-HOST (nicht in einer VM!). Erstellt automatisch eine
# neue VM aus einem Debian/Ubuntu Cloud-Image (Cloud-Init), und installiert
# darin beim ersten Boot automatisch Pinokio als Server (führt intern
# install.sh aus diesem Repo aus).
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
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
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
SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
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

if [ -f "$IMG_PATH" ]; then
  msg_info "Cloud-Image bereits im Cache, überspringe Download (${IMG_PATH})."
else
  msg_info "Lade Cloud-Image herunter (${OS_IMAGE})..."
  curl -fL --progress-bar -o "$IMG_PATH" "$IMG_URL"
  msg_ok "Download abgeschlossen."
fi

# ----------------------------------------------------------------------------
# Schritt 4: Snippets auf dem gewünschten Storage aktivieren
# ----------------------------------------------------------------------------
step 4 "Cloud-Init vorbereiten"

STORAGE_JSON="$(pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json 2>/dev/null || true)"
if [ -z "$STORAGE_JSON" ]; then
  msg_err "Storage '${SNIPPET_STORAGE}' existiert nicht."
  exit 1
fi
CONTENT="$(echo "$STORAGE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content",""))')"
SNIPPET_PATH="$(echo "$STORAGE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("path",""))')"
if [ -z "$SNIPPET_PATH" ]; then
  msg_err "Storage '${SNIPPET_STORAGE}' unterstützt keine Snippets (kein Verzeichnis-Storage)."
  msg_err "Bitte SNIPPET_STORAGE=local (oder ein anderes Verzeichnis-Storage) verwenden."
  exit 1
fi
if [[ ",${CONTENT}," != *",snippets,"* ]]; then
  msg_info "Aktiviere Inhaltstyp 'snippets' auf Storage '${SNIPPET_STORAGE}'..."
  pvesm set "$SNIPPET_STORAGE" --content "${CONTENT:+$CONTENT,}snippets"
fi
mkdir -p "${SNIPPET_PATH}/snippets"

SNIPPET_NAME="pinokio-${VMID}-user.yaml"
cat > "${SNIPPET_PATH}/snippets/${SNIPPET_NAME}" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
chpasswd:
  expire: false
  list: |
    root:${CONSOLE_PASSWORD}
users:
  - name: root
    ssh-authorized-keys:
      - ${SSH_PUBKEY}
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
  - hostname -I >> /etc/issue
  - curl -fsSL ${INSTALL_SCRIPT_URL} -o /root/install.sh
  - bash /root/install.sh > /var/log/pinokio-install.log 2>&1
  - touch /root/.pinokio-install-done
EOF

# Generierte Cloud-Config auf YAML-Gültigkeit prüfen, BEVOR die VM damit
# startet (eine ungültige Config würde still dazu führen, dass weder Passwort
# noch Gast-Agent noch die Installation angewendet werden).
if python3 -c 'import yaml' >/dev/null 2>&1; then
  if ! python3 -c "import yaml; yaml.safe_load(open('${SNIPPET_PATH}/snippets/${SNIPPET_NAME}'))" 2>/dev/null; then
    msg_err "Die generierte Cloud-Init-Config ist kein gültiges YAML:"
    msg_err "  ${SNIPPET_PATH}/snippets/${SNIPPET_NAME}"
    exit 1
  fi
  msg_ok "Cloud-Init-Konfiguration ist valides YAML."
fi
msg_ok "Cloud-Init-Konfiguration erstellt (${SNIPPET_PATH}/snippets/${SNIPPET_NAME})."

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
  --net0 "virtio,bridge=${BRIDGE}"
  --scsihw virtio-scsi-pci
  --scsi0 "${STORAGE}:0,import-from=${IMG_PATH}"
  --ide2 "${STORAGE}:cloudinit"
  --boot order=scsi0
  --serial0 socket
  --agent enabled=1
  --ostype l26
  --onboot 1
  --ipconfig0 "$IPCONFIG"
  --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"
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
    msg_warn "Konnte die IP-Adresse nach $((MAX_WAIT_ITER * 5 / 60)) Minuten nicht automatisch ermitteln."
  fi
fi

# ----------------------------------------------------------------------------
# Schritt 8: Auf Pinokio-Webserver warten
# ----------------------------------------------------------------------------
if [ -n "$VM_IP" ] && [ "$WAIT_FOR_PINOKIO" = "yes" ]; then
  step 8 "Auf Pinokio-Server warten (http://${VM_IP}:${PINOKIO_PORT})"

  msg_info "Die Installation in der VM dauert einige Minuten. Warte auf Port ${PINOKIO_PORT}..."
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
      msg_info "... ${ELAPSED}s vergangen - Installation läuft noch (Logs: siehe Zusammenfassung unten)"
    fi
  done
  set -e
  QUIET_ERR=0

  if [ "$PINOKIO_READY" = "1" ]; then
    msg_ok "Pinokio-Server ist online!"
  else
    msg_warn "Port ${PINOKIO_PORT} nach $((WAIT_TIMEOUT / 60)) Minuten nicht erreichbar."
    msg_warn "Installation läuft evtl. noch – Fortschritt prüfen:"
    msg_warn "  ssh -i ${SSH_PUBKEY_FILE%.pub} root@${VM_IP} 'tail -f /var/log/pinokio-install.log'"
  fi
else
  PINOKIO_READY=0
fi

# ----------------------------------------------------------------------------
# Schritt 9: Zusammenfassung
# ----------------------------------------------------------------------------
step 9 "Zusammenfassung"

echo
msg_ok "Fertig. Pinokio installiert sich jetzt selbstständig beim ersten Boot (dauert einige Minuten)."
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
  echo "    tail -f /var/log/pinokio-install.log   # Pinokio-Installationsfortschritt"
  echo
  echo "  Konsole verlassen mit: Strg+O, dann Strg+Q"
  echo
  msg_info "Öffne Konsole in 3 Sekunden..."
  sleep 3
  qm terminal "$VMID" || true
  echo
  msg_info "Sobald du die IP kennst, weiter mit:"
  echo "    ssh -i ${SSH_PUBKEY_FILE%.pub} root@<VM-IP> 'tail -f /var/log/pinokio-install.log'"
  echo "    http://<VM-IP>:42000"
  exit 0
fi

msg_info "Installationsfortschritt live verfolgen:"
echo "    ssh -i ${SSH_PUBKEY_FILE%.pub} root@${VM_IP} 'tail -f /var/log/pinokio-install.log'"
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
