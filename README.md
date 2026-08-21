# Pinokio Server auf Proxmox

Installiert [Pinokio](https://pinokio.co) als dauerhaft laufenden Server-Dienst auf einer
Debian/Ubuntu-VM in Proxmox VE. Nach der Installation ist Pinokio unter
`http://<VM-IP>:42000` von jedem Gerät im Netzwerk erreichbar – die VM selbst braucht
danach keinen Monitor, keine Tastatur und keine grafische Sitzung mehr.

Pinokio bietet offiziell keinen "headless"-Modus (die Electron-App braucht immer ein
Display). Dieses Skript löst das, indem es die App dauerhaft gegen ein virtuelles
Display (`Xvfb`) laufen lässt und als systemd-Dienst betreibt. Pinokios eingebaute
Server-Funktion lauscht danach automatisch auf Port 42000 – die Konfiguration wird
vom Skript vorgeschrieben, sodass **keine grafische Ersteinrichtung nötig ist** und
die VM keinen Monitor, keine Tastatur und keine grafische Sitzung braucht.

## Die zwei Skripte

| Skript | Läuft auf | Zweck |
|---|---|---|
| `create-vm.sh` | Proxmox-**Host** | Erstellt die komplette VM (Cloud-Image, q35+OVMF, Cloud-Init) und stößt die Installation automatisch an |
| `install.sh` | in der **VM** | Installiert Pinokio als Server-Dienst. Wird von `create-vm.sh` automatisch aufgerufen – manueller Aufruf ist nur nötig, wenn du die VM selbst erstellt hast |

`create-vm.sh`:
- Lädt automatisch ein offizielles Debian/Ubuntu Cloud-Image herunter (gecacht für spätere Läufe)
- Erstellt die VM bereits mit `q35` + `OVMF (UEFI)` (Voraussetzung für späteres GPU-Passthrough)
- Richtet Cloud-Init ein (root-SSH-Zugang per Key, DHCP-Netzwerk)
- Startet die VM und lässt sie beim ersten Boot automatisch `install.sh` ausführen
- Wartet am Ende, bis der Pinokio-Webserver erreichbar ist, und gibt die URL (`http://<VM-IP>:42000`) aus
- Optional: kann eine GPU direkt bei der Erstellung durchreichen (`PCI_HOSTPCI=...`)

`install.sh`:
- Erkennt die GPU (NVIDIA/AMD/Intel) und installiert passende Treiber/Firmware
- Legt einen eigenen, unprivilegierten Systembenutzer `pinokio` an
- Lädt automatisch die **jeweils neueste** Pinokio-Version von GitHub herunter und installiert sie
- Konfiguriert Pinokio vor (`~/.pinokio/config.json`), sodass **keine grafische
  Ersteinrichtung nötig ist** – der Webserver läuft direkt nach dem Start
- Richtet drei systemd-Dienste ein: `pinokio-xvfb`, `pinokio` und `pinokio-vnc` (nur als Fallback)
- Wartet am Ende, bis der Webserver auf Port 42000 antwortet, und zeigt die URL an
- Öffnet bei aktivem `ufw` automatisch Port 42000

## Voraussetzungen

- Proxmox VE (getestet mit aktuellen 9.x-Versionen), Root-Zugriff auf den Host
- Internetzugang auf dem Host (Cloud-Image-Download) und in der VM (Pinokio-Download)
- Empfohlen: mind. 4 vCPUs, 8 GB RAM, 100+ GB Plattenplatz (KI-Modelle werden schnell groß)
- Optional, aber empfehlenswert: eine durchgereichte GPU (siehe unten)

## GPU beim Erstellen oder erst später durchreichen?

**Beides geht – die GPU ist nicht zwingend schon bei der VM-Erstellung nötig.**

- Passthrough besteht aus zwei unabhängigen Teilen: (1) IOMMU/vfio-Einrichtung auf dem
  **Host** – geht jederzeit, auch Monate später, unabhängig vom Zustand der VM – und
  (2) das PCI-Gerät der VM zuweisen – dafür muss die VM nur kurz gestoppt sein, kein
  Neuinstallieren nötig.
- **Einzige Voraussetzung, die von Anfang an stimmen sollte:** Maschinentyp `q35` +
  BIOS `OVMF (UEFI)`. `create-vm.sh` setzt das automatisch, auch wenn du die GPU
  (noch) nicht mitgibst. Wird das nachträglich auf einer bereits mit SeaBIOS/Legacy
  installierten VM umgestellt, bootet sie meist nicht mehr ohne Neuinstallation.
- Willst du die GPU direkt bei der Erstellung mitgeben (Host-Setup aus Schritt 2 muss
  dafür schon erledigt sein): `PCI_HOSTPCI=01:00 bash -c "$(curl -fsSL .../create-vm.sh)"`
- Willst du sie später nachrüsten: einfach Schritt 2 unten durchführen und danach in
  der laufenden (kurz gestoppten) VM das PCI-Gerät hinzufügen.

## Schritt 1: VM erstellen

### Option A: Vollautomatisch (empfohlen)

Auf dem Proxmox-**Host** per SSH einloggen und als root ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
```

Das erstellt VM, Betriebssystem und Pinokio-Installation komplett automatisch und
**wartet am Ende, bis der Pinokio-Server unter `http://<VM-IP>:42000` erreichbar
ist** – die finale URL wird groß ausgegeben. Alle Werte sind per
Umgebungsvariable vor dem Aufruf anpassbar:

| Variable | Standard | Bedeutung |
|---|---|---|
| `VMID` | nächste freie ID | Proxmox VM-ID |
| `VM_NAME` | `pinokio` | Hostname/Anzeigename |
| `CORES` | `4` | vCPUs |
| `MEMORY` | `8192` | RAM in MB |
| `DISK_SIZE` | `100` | Festplattengröße in GB |
| `STORAGE` | `local-lvm` | Ziel-Storage für Disks |
| `SNIPPET_STORAGE` | `local` | Storage für die Cloud-Init-Konfiguration |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `OS_IMAGE` | `debian12` | `debian12` \| `debian13` \| `ubuntu2204` \| `ubuntu2404` (Architektur wird automatisch an den Host angepasst: amd64/arm64) |
| `IPCONFIG` | `ip=dhcp` | z.B. `ip=192.168.1.50/24,gw=192.168.1.1` |
| `PCI_HOSTPCI` | *(leer)* | z.B. `01:00`, um die GPU direkt mitzugeben |
| `WAIT_FOR_PINOKIO` | `yes` | `no` = nach dem VM-Start nicht auf Port 42000 warten |
| `WAIT_TIMEOUT` | `1800` | max. Wartezeit auf den Pinokio-Server in Sekunden |

Beispiel mit mehr Ressourcen und Ubuntu statt Debian:
```bash
CORES=8 MEMORY=16384 DISK_SIZE=250 OS_IMAGE=ubuntu2404 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
```

Fortschritt verfolgen, sobald die VM eine IP hat:
```bash
ssh -i /root/.ssh/pinokio_vm_key root@<VM-IP> 'tail -f /var/log/pinokio-install.log'
```
Am Ende gibt `create-vm.sh` die fertige URL aus:
```
http://<VM-IP>:42000
```
Weiter geht's direkt bei [Schritt 5](#schritt-5-von-jedem-gerät-zugreifen).

### Option B: Manuell

1. Neue VM erstellen, **Maschinentyp `q35`** und **BIOS `OVMF (UEFI)`** wählen (Voraussetzung
   für GPU-Passthrough).
2. Debian oder Ubuntu Server installieren (Netzwerk mit fester IP/DHCP-Reservierung
   erleichtert den späteren Zugriff).
3. Weiter mit [Schritt 3](#schritt-3-pinokio-installieren-einzeiler-in-der-vm).

## Schritt 2: GPU Passthrough einrichten (optional, auf dem Proxmox-Host)

Dieser Teil betrifft ausschließlich den Proxmox-**Host**, nicht die VM. Er wird bewusst
**nicht** vom Skript automatisiert, da er hostspezifisch ist und ein Neustart des Hosts
nötig ist.

### 2.1 IOMMU aktivieren

Auf dem Host, je nach Bootloader:

**GRUB** (`/etc/default/grub`), Intel:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```
AMD:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```
Danach:
```bash
update-grub
```

**systemd-boot** (z.B. bei ZFS-Root-Installationen), Datei unter
`/etc/kernel/cmdline` ergänzen und danach `proxmox-boot-tool refresh` ausführen.

> Hinweis: Auf aktuellen Intel-Systemen mit Kernel 6.8+ ist IOMMU teils bereits per
> Default aktiv – die explizite Angabe schadet trotzdem nicht.

### 2.2 VFIO-Module laden

```bash
echo -e "vfio\nvfio_iommu_type1\nvfio_pci" >> /etc/modules
update-initramfs -u -k all
reboot
```

### 2.3 GPU identifizieren und an vfio-pci binden

```bash
lspci -nnk | grep -A3 -Ei 'vga|3d controller'
```
Notiere die PCI-Adresse (z.B. `01:00.0`) und die Vendor:Device-IDs (z.B. `10de:2504`)
von GPU **und** dem zugehörigen Audio-Gerät (meist `01:00.1`).

```bash
echo "options vfio-pci ids=10de:2504,10de:228e" > /etc/modprobe.d/vfio.conf
update-initramfs -u -k all
reboot
```

Nach dem Neustart prüfen, dass die GPU an `vfio-pci` gebunden ist (nicht an
`nouveau`/`nvidia`/`amdgpu`):
```bash
lspci -nnk -s 01:00.0
```
Bei `Kernel driver in use: vfio-pci` war es erfolgreich.

### 2.4 GPU der VM zuweisen

Über die Proxmox-Weboberfläche: **VM → Hardware → Add → PCI Device** → Raw Device
auswählen, **All Functions**, **PCI-Express** und ggf. **Primary GPU** aktivieren
(falls es die einzige GPU im System ist).

Alternativ per CLI (`/etc/pve/qemu-server/<VMID>.conf`):
```
machine: q35
bios: ovmf
hostpci0: 01:00,pcie=1,x-vga=1
```

### 2.5 Bekannte Stolperfallen

- **NVIDIA "Code 43" / Treiber startet nicht in der VM:** CPU-Flags ergänzen:
  ```
  cpu: host,hidden=1,flags=+pcid
  args: -cpu host,kvm=off,hv_vendor_id=proxmox
  ```
- **GPU teilt sich eine IOMMU-Gruppe mit anderen Geräten:** GPU in einen anderen
  PCIe-Slot stecken, oft ändert das die Gruppierung.
- **AMD-GPU meldet `Failed to set group container` beim VM-Start:** häufig ein
  Firmware-/Reset-Bug neuerer AMD-Karten – Kernel/Firmware des Hosts aktualisieren.
- **Radeon/GeForce als einzige Host-Grafik:** ohne zweite GPU für die Konsole
  ist die Proxmox-Weboberfläche der einzige Zugriffsweg, sobald die GPU an die VM geht.

Ausführliche, laufend aktualisierte Referenz: [Proxmox-Wiki – PCI(e) Passthrough](https://pve.proxmox.com/wiki/PCI(e)_Passthrough).

## Schritt 3: Pinokio installieren (Einzeiler, in der VM)

*(Bei Option A bereits automatisch erledigt – dieser Schritt ist nur bei manuell
erstellten VMs nötig.)*

In der VM per SSH einloggen und als root ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)"
```

Das Skript erkennt automatisch die GPU, installiert bei Bedarf Treiber, lädt die
aktuellste Pinokio-Version herunter und startet den Dienst. Falls GPU-Treiber
installiert wurden, am Ende einmal neu starten:
```bash
reboot
```

## Schritt 4: Ersteinrichtung (normalerweise nicht nötig)

Das Installationsskript schreibt Pinokios Konfiguration (`~/.pinokio/config.json`)
vor dem ersten Start vor und richtet den systemd-Dienst so ein, dass der Webserver
sofort auf Port 42000 lauscht. **Ein grafischer Ersteinrichtungs-Dialog oder VNC ist
in der Regel nicht mehr erforderlich** – einfach direkt bei Schritt 5 weitermachen.

Falls die Web-UI beim ersten Aufruf doch einen Einrichtungsdialog zeigt, gibt es
zwei Möglichkeiten:

1. **Direkt im Browser:** den Dialog einfach im Browser unter `http://<VM-IP>:42000`
   abschließen (die Web-UI ist ja bereits erreichbar).
2. **Per VNC-Tunnel** (Fallback, falls die Web-UI noch nicht lädt):

   ```bash
   # Auf dem eigenen PC:
   ssh -L 5900:localhost:5900 root@<VM-IP>

   # In der laufenden SSH-Sitzung, auf der VM:
   systemctl start pinokio-vnc
   ```

   Anschließend mit einem beliebigen VNC-Viewer (z.B. TigerVNC, RealVNC) auf dem
   eigenen PC gegen `localhost:5900` verbinden (kein Passwort gesetzt, da nur per
   Tunnel erreichbar). Danach den VNC-Dienst wieder stoppen:

   ```bash
   systemctl stop pinokio-vnc
   ```

## Schritt 5: Von jedem Gerät zugreifen

Einfach im Browser eines beliebigen Geräts im selben Netzwerk öffnen:

```
http://<VM-IP>:42000
```

## Sicherheitshinweis

Pinokio kann beliebige Skripte und Shell-Befehle als Benutzer `pinokio` ausführen –
das ist sein Zweck (Installation/Ausführung von KI-Apps). Netzwerkzugriff auf Port
42000 ist damit faktisch gleichbedeutend mit Ausführungsrechten auf der VM. Deshalb:

- Die VM **nicht** direkt ins Internet exponieren (kein Port-Forwarding auf 42000).
- Zugriff nach Möglichkeit auf ein vertrauenswürdiges LAN/VLAN begrenzen, z.B. über
  die Proxmox-Firewall oder einen separaten Netzwerk-Bridge.
- Für Fernzugriff besser einen VPN-Tunnel (z.B. WireGuard/Tailscale) statt einer
  offenen Portfreigabe verwenden.

## Aktualisieren

Das Installationsskript ist idempotent – einfach erneut ausführen, um auf die
neueste Pinokio-Version zu aktualisieren:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)"
```

## Troubleshooting

- Logs ansehen: `journalctl -u pinokio -f`
- Dienst neu starten: `systemctl restart pinokio`
- Status aller drei Dienste: `systemctl status pinokio pinokio-xvfb pinokio-vnc`
- Port 42000 antwortet nicht: in der VM `curl -I http://localhost:42000` testen –
  klappt es lokal aber nicht aus dem Netzwerk, blockiert eine Firewall (Proxmox-
  Firewall / ufw prüfen); läuft der Dienst nicht, mit `journalctl -u pinokio -e` weitersehen
- Pinokio zeigt einen Einrichtungsdialog: siehe Schritt 4 (per Browser oder VNC-Tunnel abschließen)
- Keine GPU erkannt: `lspci -nnk` in der VM prüfen, ob das Gerät überhaupt sichtbar
  ist (falls nicht: Passthrough-Konfiguration auf dem Host prüfen, siehe Schritt 2)
- NVIDIA-Treiber lädt nicht: `nvidia-smi` in der VM ausführen; ggf. fehlt bei
  aktiviertem Secure Boot in der VM die Signierung des DKMS-Moduls (Secure Boot in
  der VM-UEFI-Firmware deaktivieren oder MOK-Enrollment durchführen)
- `create-vm.sh` bricht mit "VMID existiert bereits" ab: andere ID mit `VMID=<id>` angeben
- Proxmox-Konsole hängt bei "waiting for serial interface" (nur bei VMs, die mit
  einer Version von `create-vm.sh` vor dem 2026-08-Fix erstellt wurden): die VM
  wurde mit `vga: serial0` erstellt, das erzwingt eine reine Serial-Konsole ohne
  normale Anzeige. Fix für eine bestehende VM (VM darf dabei laufen):
  ```bash
  qm set <VMID> --vga std
  ```
  Danach in der Proxmox-Weboberfläche die Konsole neu öffnen – sie zeigt jetzt
  wieder normal Text/Boot-Meldungen an. Neu erstellte VMs sind davon nicht mehr
  betroffen.
- VM bekommt beim ersten Boot keine IP / `qm guest cmd` schlägt fehl: dem
  Cloud-Init-/Boot-Vorgang noch etwas Zeit geben (ca. 1–2 Minuten), danach erneut
  versuchen; alternativ per `qm terminal <VMID>` auf die serielle Konsole schauen

## VM wieder entfernen (bei Nutzung von `create-vm.sh`)

```bash
qm stop <VMID>
qm destroy <VMID>
```

## Pinokio deinstallieren (VM bleibt bestehen)

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/uninstall.sh -o uninstall.sh
bash uninstall.sh              # Apps/Modelle bleiben erhalten
bash uninstall.sh --purge-data # löscht zusätzlich alle Apps/Modelle
```

## Contributing

Pull Requests sind willkommen, z.B. für ROCm-Unterstützung, LXC-Unterstützung
(sofern ohne volles GPU-Passthrough sinnvoll nutzbar) oder Verbesserungen an der
Xvfb/VNC-Ersteinrichtung.
