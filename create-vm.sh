#!/usr/bin/env bash
#
# Pinokio Proxmox VM Creator
# --------------------------
# Läuft auf dem Proxmox-HOST (nicht in einer VM!). Erstellt automatisch eine
# neue VM aus einem Debian/Ubuntu Cloud-Image (q35 + OVMF/UEFI, Cloud-Init),
# und installiert darin beim ersten Boot automatisch Pinokio als Server
# (führt intern install.sh aus diesem Repo aus).
#
# Aufruf (Einzeiler, auf dem Proxmox-Host als root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
#
# Alle Werte lassen sich vor dem Aufruf per Umgebungsvariable überschreiben, z.B.:
#   CORES=8 MEMORY=16384 DISK_SIZE=200 OS_IMAGE=ubuntu2404 \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
#
# GPU direkt bei der Erstellung durchreichen (optional, IOMMU/vfio-Setup auf
# dem Host muss vorher bereits erledigt sein, siehe README.md):
#   PCI_HOSTPCI=01:00 bash -c "$(curl -fsSL .../create-vm.sh)"
#
set -euo pipefail

C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
msg_info() { echo -e "${C_INFO}➜${C_RESET} $*"; }
msg_ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
msg_warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
msg_err()  { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }

# ----------------------------------------------------------------------------
# Konfiguration (per ENV-Variable überschreibbar)
# ----------------------------------------------------------------------------
VMID="${VMID:-}"
VM_NAME="${VM_NAME:-pinokio}"
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
PCI_HOSTPCI="${PCI_HOSTPCI:-}"          # z.B. "01:00" -> GPU direkt bei Erstellung durchreichen

# ----------------------------------------------------------------------------
# Vorabprüfungen
# ----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  msg_err "Bitte als root ausführen."
  exit 1
fi
for cmd in qm pvesh pvesm python3; do
  command -v "$cmd" >/dev/null 2>&1 || { msg_err "'$cmd' nicht gefunden – dieses Skript muss auf dem Proxmox-Host laufen."; exit 1; }
done

if [ -z "$VMID" ]; then
  VMID="$(pvesh get /cluster/nextid)"
fi
if qm status "$VMID" >/dev/null 2>&1; then
  msg_err "VMID ${VMID} existiert bereits. Andere VMID mit VMID=<id> angeben."
  exit 1
fi
msg_info "Verwende VMID ${VMID}."

# ----------------------------------------------------------------------------
# SSH-Key ermitteln (für root-Login in der VM)
# ----------------------------------------------------------------------------
if [ -z "$SSH_PUBKEY_FILE" ]; then
  for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do
    [ -f "$f" ] && SSH_PUBKEY_FILE="$f" && break
  done
fi
if [ -z "$SSH_PUBKEY_FILE" ] || [ ! -f "$SSH_PUBKEY_FILE" ]; then
  msg_warn "Kein bestehender SSH-Key auf dem Host gefunden. Erzeuge einen neuen..."
  mkdir -p /root/.ssh
  ssh-keygen -t ed25519 -N "" -f /root/.ssh/pinokio_vm_key -q
  SSH_PUBKEY_FILE="/root/.ssh/pinokio_vm_key.pub"
  msg_warn "Neuer privater Schlüssel liegt auf dem Host unter: /root/.ssh/pinokio_vm_key"
  msg_warn "Login später mit: ssh -i /root/.ssh/pinokio_vm_key root@<VM-IP>"
fi
SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"

# ----------------------------------------------------------------------------
# Cloud-Image herunterladen (mit lokalem Cache)
# ----------------------------------------------------------------------------
case "$OS_IMAGE" in
  debian12)   IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2" ;;
  debian13)   IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
  ubuntu2204) IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" ;;
  ubuntu2404) IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
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
# Snippets auf dem gewünschten Storage aktivieren (für Cloud-Init user-data)
# ----------------------------------------------------------------------------
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

# ----------------------------------------------------------------------------
# Cloud-Init user-data Snippet erzeugen (Root-Login + automatischer Pinokio-Install)
# ----------------------------------------------------------------------------
SNIPPET_NAME="pinokio-${VMID}-user.yaml"
cat > "${SNIPPET_PATH}/snippets/${SNIPPET_NAME}" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh-authorized-keys:
      - ${SSH_PUBKEY}
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSL ${INSTALL_SCRIPT_URL} -o /root/install.sh
  - bash /root/install.sh > /var/log/pinokio-install.log 2>&1
  - touch /root/.pinokio-install-done
EOF
msg_ok "Cloud-Init-Konfiguration erstellt."

# ----------------------------------------------------------------------------
# VM erstellen
# ----------------------------------------------------------------------------
msg_info "Erstelle VM ${VMID} (${VM_NAME})..."

CREATE_ARGS=(
  --name "$VM_NAME"
  --machine q35
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
  --vga serial0
  --agent enabled=1
  --ostype l26
  --ipconfig0 "$IPCONFIG"
  --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}"
)

if [ -n "$PCI_HOSTPCI" ]; then
  CREATE_ARGS+=(--hostpci0 "${PCI_HOSTPCI},pcie=1,x-vga=1")
  msg_info "GPU ${PCI_HOSTPCI} wird direkt bei der Erstellung durchgereicht."
fi

qm create "$VMID" "${CREATE_ARGS[@]}"
qm resize "$VMID" scsi0 "${DISK_SIZE}G" >/dev/null
msg_ok "VM ${VMID} erstellt (q35 + OVMF/UEFI, ${DISK_SIZE}G Disk)."

if [ "$START_VM" = "yes" ]; then
  qm start "$VMID"
  msg_ok "VM gestartet."
fi

# ----------------------------------------------------------------------------
# Zusammenfassung
# ----------------------------------------------------------------------------
echo
msg_ok "Fertig. Pinokio installiert sich jetzt selbstständig beim ersten Boot (dauert einige Minuten)."
echo
echo "  VMID          : ${VMID}"
echo "  Name          : ${VM_NAME}"
echo "  SSH-Key       : ${SSH_PUBKEY_FILE}"
echo
msg_info "IP-Adresse ermitteln, sobald der Gast-Agent läuft (ca. 1 Minute nach Boot):"
echo "    qm guest cmd ${VMID} network-get-interfaces"
echo
msg_info "Installationsfortschritt live verfolgen:"
echo "    ssh -i ${SSH_PUBKEY_FILE%.pub} root@<VM-IP> 'tail -f /var/log/pinokio-install.log'"
echo
msg_info "Ist /root/.pinokio-install-done in der VM vorhanden, ist die Installation fertig."
msg_info "Danach: einmalige Ersteinrichtung per VNC-Tunnel + LAN-Zugriff aktivieren (siehe README.md)."
echo "    http://<VM-IP>:42000"
