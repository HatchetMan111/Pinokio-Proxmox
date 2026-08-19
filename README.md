# Pinokio Server auf Proxmox

Installiert [Pinokio](https://pinokio.co) als dauerhaft laufenden Server-Dienst auf einer
Debian/Ubuntu-VM in Proxmox VE. Nach der Installation ist Pinokio unter
`http://<VM-IP>:42000` von jedem Gerät im Netzwerk erreichbar – die VM selbst braucht
danach keinen Monitor, keine Tastatur und keine grafische Sitzung mehr.

Pinokio bietet offiziell keinen "headless"-Modus (die Electron-App braucht immer ein
Display). Dieses Skript löst das, indem es die App dauerhaft gegen ein virtuelles
Display (`Xvfb`) laufen lässt und als systemd-Dienst betreibt – die eingebaute
[Home-Server-Funktion](https://github.com/pinokiocomputer/pinokio) von Pinokio 8
übernimmt danach den eigentlichen Netzwerkzugriff auf Port 42000.

## Was macht das Skript

- Erkennt die GPU (NVIDIA/AMD/Intel) und installiert passende Treiber/Firmware
- Legt einen eigenen, unprivilegierten Systembenutzer `pinokio` an
- Lädt automatisch die **jeweils neueste** Pinokio-Version von GitHub herunter und installiert sie
- Richtet drei systemd-Dienste ein: `pinokio-xvfb`, `pinokio` und `pinokio-vnc` (nur für die Ersteinrichtung)
- Öffnet bei aktivem `ufw` automatisch Port 42000

## Voraussetzungen

- Proxmox VE (getestet mit aktuellen 9.x-Versionen)
- Eine VM mit **Debian 12/13** oder **Ubuntu 22.04/24.04** (Server-Installation reicht,
  kein Desktop nötig)
- Empfohlen: mind. 4 vCPUs, 8 GB RAM, 100+ GB Plattenplatz (KI-Modelle werden schnell groß)
- Root-Zugriff auf die VM (SSH)
- Optional, aber empfehlenswert: eine durchgereichte GPU (siehe unten)

## Schritt 1: VM in Proxmox anlegen

1. Neue VM erstellen, **Maschinentyp `q35`** und **BIOS `OVMF (UEFI)`** wählen (Voraussetzung
   für GPU-Passthrough).
2. Debian oder Ubuntu Server installieren (Netzwerk mit fester IP/DHCP-Reservierung
   erleichtert den späteren Zugriff).
3. Falls eine GPU durchgereicht werden soll: **vor** dem ersten Start der VM die Schritte
   aus dem nächsten Abschnitt auf dem Proxmox-**Host** durchführen.

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

In der VM per SSH einloggen und als root ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)"
```

*(`HatchetMan111/Pinokio-Proxmox` durch den Namen deines GitHub-Repos ersetzen, nachdem du
`install.sh`, `uninstall.sh` und diese README dorthin hochgeladen hast.)*

Das Skript erkennt automatisch die GPU, installiert bei Bedarf Treiber, lädt die
aktuellste Pinokio-Version herunter und startet den Dienst. Falls GPU-Treiber
installiert wurden, am Ende einmal neu starten:
```bash
reboot
```

## Schritt 4: Ersteinrichtung abschließen

Pinokio zeigt beim allerersten Start einen kurzen Einrichtungsdialog (Speicherort
wählen, Nutzungsbedingungen). Dafür braucht man einmalig eine grafische Verbindung
zur VM – danach nicht mehr. Das Skript richtet dafür einen VNC-Zugriff ein, der
**nur über einen SSH-Tunnel** erreichbar ist (kein offener VNC-Port im Netzwerk):

```bash
# Auf dem eigenen PC:
ssh -L 5900:localhost:5900 root@<VM-IP>

# In der laufenden SSH-Sitzung, auf der VM:
systemctl start pinokio-vnc
```

Anschließend mit einem beliebigen VNC-Viewer (z.B. TigerVNC, RealVNC) auf dem eigenen
PC gegen `localhost:5900` verbinden (kein Passwort gesetzt, da nur per Tunnel
erreichbar). Ersteinrichtung abschließen und in Pinokio unter **Settings → Home
Server** den LAN-Zugriff aktivieren. Danach den VNC-Dienst wieder stoppen:

```bash
systemctl stop pinokio-vnc
```

## Schritt 5: Von jedem Gerät zugreifen

Sobald "Home Server" aktiviert ist, einfach im Browser eines beliebigen Geräts im
selben Netzwerk öffnen:

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
- Keine GPU erkannt: `lspci -nnk` in der VM prüfen, ob das Gerät überhaupt sichtbar
  ist (falls nicht: Passthrough-Konfiguration auf dem Host prüfen, siehe Schritt 2)
- NVIDIA-Treiber lädt nicht: `nvidia-smi` in der VM ausführen; ggf. fehlt bei
  aktiviertem Secure Boot in der VM die Signierung des DKMS-Moduls (Secure Boot in
  der VM-UEFI-Firmware deaktivieren oder MOK-Enrollment durchführen)

## Deinstallation

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/uninstall.sh -o uninstall.sh
bash uninstall.sh              # Apps/Modelle bleiben erhalten
bash uninstall.sh --purge-data # löscht zusätzlich alle Apps/Modelle
```

## Contributing

Pull Requests sind willkommen, z.B. für ROCm-Unterstützung, LXC-Unterstützung
(sofern ohne volles GPU-Passthrough sinnvoll nutzbar) oder Verbesserungen an der
Xvfb/VNC-Ersteinrichtung.
