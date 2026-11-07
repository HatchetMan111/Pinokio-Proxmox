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
| `create-vm.sh` | Proxmox-**Host** | Erstellt die komplette VM (Cloud-Image, q35+OVMF, direkt vorkonfiguriert – ohne auf Cloud-Init angewiesen zu sein) und installiert Pinokio per SSH |
| `install.sh` | in der **VM** | Installiert Pinokio als Server-Dienst (Modi: Installation/Update, `--status`, `--uninstall`, `--debug`). Wird von `create-vm.sh` automatisch aufgerufen – manueller Aufruf ist nur nötig, wenn du die VM selbst erstellt hast. Auf einem Proxmox-**Host** erkannt, verweigert es bewusst die Ausführung und leitet zu `create-vm.sh` weiter |

`create-vm.sh`:
- Lädt automatisch ein offizielles Debian/Ubuntu Cloud-Image herunter (gecacht,
  Integrität wird per Prüfsumme + `qemu-img check` verifiziert)
- Erstellt die VM bereits mit `q35` + `OVMF (UEFI)` (Voraussetzung für späteres GPU-Passthrough)
- Schreibt root-Passwort, SSH-Key, SSH-Hostkeys und DHCP-Netzwerkkonfiguration
  **direkt in das Image** (per `qemu-nbd`, vor dem ersten Boot) und deaktiviert
  Cloud-Init explizit – das funktioniert unabhängig davon, ob Cloud-Init im Gast
  zuverlässig arbeitet, und ist der Grund, warum Login/Netzwerk garantiert ab dem
  allerersten Boot funktionieren
- Wartet auf SSH, überträgt `install.sh` und führt es aus – Ausgabe wird live im
  Terminal mitgestreamt, keine Blackbox
- Wartet danach, bis der Pinokio-Webserver auf Port 42000 antwortet, und gibt die
  fertige URL groß aus
- Läuft interaktiv an einem Terminal automatisch als Auswahl-Assistent (whiptail,
  wie bei den Proxmox Community-Scripts) – Maschinentyp, OS, Ressourcen, Storage,
  Bridge, IP-Konfiguration und optional GPU lassen sich dort auswählen, ohne
  Umgebungsvariablen von Hand zu setzen. Ohne TTY (z.B. `curl | bash` oder in
  Automationen) wird nie interaktiv gefragt und nie eine Konsole automatisch
  geöffnet – stattdessen erscheint eine klare Textanleitung
- Findet die IP subnetz-unabhängig (das VM-Netz muss kein 192.168.x sein) und
  mehrstufig: (1) passives Polling von Gast-Agent/ARP/Bridge-FDB, (2) statische
  `ipconfig0` per Ping + SSH verifizieren, (3) mehrere aktive Runden mit
  Ping-Sweep, DHCP-yiaddr-Mithören und `tcpdump` am Tap/an der Bridge, (4) als
  Eskalationsstufe eine Tiefendiagnose (Disk read-only mounten, echte
  Gast-Netzconfig `/etc/systemd/network/89-pinokio.network` + Logs auslesen).
  Am Ende steht bei Erfolglosigkeit eine gezielte Checkliste (Bridge prüfen,
  DHCP-Verkehr mithören, Lease am Router, Gast-Agent, Konsole)
- Richtet eine first-boot-Unit ein, die `qemu-guest-agent` in der VM
  nachinstalliert (Cloud-Images bringen ihn nicht mit) – damit liefert der
  Gast-Agent künftig die IP zuverlässig direkt an den Host
- Die automatische Konsolenöffnung (`qm terminal`) passiert nur bei echtem
  Terminal auf stdin UND stdout; sonst (und bei jedem Fehler) gibt das Skript
  die manuelle Anleitung aus und crasht nie
- Optional: kann eine GPU direkt bei der Erstellung durchreichen (`PCI_HOSTPCI=...`)

`install.sh`:
- Erkennt, ob es auf einem Proxmox-Host läuft (`pveversion` vorhanden): dann wird
  **nichts** auf den Hypervisor installiert – interaktiv fragt es, ob `create-vm.sh`
  direkt gestartet werden soll, ohne TTY bricht es mit der exakten Anleitung ab
- Installiert in KVM/QEMU-VMs automatisch den `qemu-guest-agent` (hilft der
  IP-Erkennung auf dem Proxmox-Host)
- Installiert die kompletten Electron-Laufzeit-Bibliotheken vorab (die Pinokio-.deb
  deklariert sie nicht selbst; auf minimalen Cloud-Images crashte der Dienst sonst
  mit Exit 127) und verifiziert nach der Installation per `ldd`, dass alle
  Bibliotheken auflösbar sind – bricht sonst mit den konkreten fehlenden
  Bibliotheksnamen ab
- Schaltet Pinokios optionalen Secure-Localhost-/HTTPS-Modus ab
  (`PINOKIO_HTTPS_ACTIVE=0` im systemd-Unit): der zugehörige Dialog fragt nach
  einem Systempasswort, das der Dienstbenutzer `pinokio` bewusst nicht hat.
  Die Web-UI läuft bewusst per HTTP auf Port 42000; falls der Dialog trotzdem
  erscheint, einfach abbrechen
- Erkennt die GPU (NVIDIA/AMD/Intel) und installiert passende Treiber/Firmware
- Legt einen eigenen, unprivilegierten Systembenutzer `pinokio` an
- Lädt automatisch die **jeweils neueste** Pinokio-Version von GitHub herunter und installiert sie
  (Versionsermittlung tolerant gegenüber GitHub-API-Ausfällen: API → Redirect-Fallback;
  Downloads mit `--retry`, halbe `.deb`-Dateien werden per `trap` aufgeräumt)
- Konfiguriert Pinokio vor (`~/.pinokio/config.json`), sodass **keine grafische
  Ersteinrichtung nötig ist** – der Webserver läuft direkt nach dem Start
- Richtet drei systemd-Dienste ein: `pinokio-xvfb`, `pinokio` und `pinokio-vnc` (nur als Fallback)
- Wartet am Ende, bis der Webserver auf Port 42000 antwortet, und zeigt die URL an
- Öffnet bei aktivem `ufw` automatisch Port 42000
- Ist idempotent: erneutes Ausführen aktualisiert auf die neueste Version und startet die Dienste neu

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

> Wichtig: unbedingt `bash -c "$(curl …)"` nutzen, **nicht** `curl … | bash` – nur so
> hat der whiptail-Auswahl-Assistent ein Terminal. Log läuft mit unter
> `/var/log/pinokio-create-vm-<VMID>.log`. Ohne TTY funktioniert der Lauf trotzdem
> definiert: kein Assistent, keine automatische Konsolenöffnung, dafür klare
> Textanleitungen (und nie ein `qm terminal`-Crash).

Das erstellt VM, Betriebssystem und Pinokio-Installation komplett automatisch und
**wartet am Ende, bis der Pinokio-Server unter `http://<VM-IP>:42000` erreichbar
ist** – die finale URL wird groß ausgegeben.

> Tipp: Auch der klassische `install.sh`-Einzeiler ist auf dem Host "sicher": läuft er
> auf einem Proxmox-Host (`pveversion` vorhanden), installiert er **nicht** Pinokio auf
> den Hypervisor, sondern fragt interaktiv, ob `create-vm.sh` gleich gestartet werden
> soll (ohne TTY, z.B. `curl | bash`, bricht er sauber mit der Anleitung ab).
> Umgebungsvariablen wie `CORES=8 NONINTERACTIVE=1` werden dabei an `create-vm.sh`
> durchgereicht.

Alle Werte sind per
Umgebungsvariable vor dem Aufruf anpassbar:

Wird `create-vm.sh` **interaktiv an einem Terminal** ausgeführt (also nicht in
einem eigenen Automatisierungsskript), öffnet sich automatisch ein Auswahlmenü
für alle wichtigen Werte – die folgende Tabelle ist dann nur für die
nicht-interaktive Nutzung bzw. zum Vorbelegen von Standardwerten relevant:

| Variable | Standard | Bedeutung |
|---|---|---|
| `VMID` | nächste freie ID | Proxmox VM-ID |
| `VM_NAME` | `pinokio` | Hostname/Anzeigename |
| `MACHINE` | `q35` | `q35` (modern, empfohlen) oder `i440fx` (Legacy) |
| `CORES` | `4` | vCPUs |
| `MEMORY` | `8192` | RAM in MB |
| `DISK_SIZE` | `100` | Festplattengröße in GB |
| `STORAGE` | `local-lvm` | Ziel-Storage für Disks |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `NET_MODEL` | `virtio` | NIC-Modell (`e1000` nur zur Fehlersuche, falls virtio-Treiber im Gast fehlen) |
| `OS_IMAGE` | `debian12` | `debian12` \| `debian13` \| `ubuntu2204` \| `ubuntu2404` (Architektur wird automatisch an den Host angepasst: amd64/arm64) |
| `IPCONFIG` | `ip=dhcp` | z.B. `ip=192.168.1.50/24,gw=192.168.1.1` |
| `SSH_PUBKEY_FILE` | automatisch erkannt | Pfad zu einem öffentlichen SSH-Key; wird sonst neu erzeugt |
| `PCI_HOSTPCI` | *(leer)* | z.B. `01:00`, um die GPU direkt mitzugeben |
| `WAIT_FOR_PINOKIO` | `yes` | `no` = nach dem VM-Start nicht auf Port 42000 warten |
| `WAIT_TIMEOUT` | `1800` | max. Wartezeit auf den Pinokio-Server in Sekunden |
| `AGENT_WAIT_TIMEOUT` | `120` | IP-Erkennung Stufe 1: wie lange passiv auf Gast-Agent/ARP gepollt wird (Sekunden; der Legacy-Alias `IP_WAIT_TIMEOUT` wird weiterhin gelesen) |
| `AGENT_POLL_INTERVAL` | `5` | Poll-Intervall der passiven IP-Erkennung (Sekunden) |
| `SNIFF_ROUNDS` | `3` | IP-Erkennung Stufe 3: Anzahl aktiver Runden (Ping-Sweep + DHCP-Sniff + tcpdump + ARP) |
| `SNIFF_DHCP_SECS` | `15` | Dauer des DHCP-yiaddr-Sniffs pro Runde (Sekunden) |
| `SNIFF_SECS` | `30` | Dauer des generischen tcpdump-Sniffs pro Lauscher (Sekunden) |
| `SNIFF_PAUSE` | `10` | Pause zwischen den aktiven Runden (Sekunden) |
| `IMG_REDOWNLOAD` | *(leer)* | `yes` = gecachtes Cloud-Image verwerfen und neu herunterladen (bei Verdacht auf einen beschädigten Cache) |
| `NONINTERACTIVE` | *(leer)* | `1` = Auswahl-Assistent überspringen, nur ENV-Variablen/Standardwerte nutzen |

Beispiel mit mehr Ressourcen und Ubuntu statt Debian:
```bash
CORES=8 MEMORY=16384 DISK_SIZE=250 OS_IMAGE=ubuntu2404 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/create-vm.sh)"
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
aktuellste Pinokio-Version herunter und startet den Dienst. Läuft auch ohne TTY
(z.B. `curl -fsSL .../install.sh | bash`). Optionen:

```bash
# Update (identisch zur erneuten Installation – idempotent):
bash -c "$(curl -fsSL .../install.sh)" -- --update

# Status der Dienste + Version + URL (kein root nötig):
bash -c "$(curl -fsSL .../install.sh)" -- --status

# Deinstallieren (Apps/Modelle bleiben; mit --purge-data alles löschen):
bash -c "$(curl -fsSL .../install.sh)" -- --uninstall [--purge-data]

# Fehlerdiagnose: jeder ausgeführte Befehl sichtbar (bash -x):
bash -c "$(curl -fsSL .../install.sh)" -- --debug
```

Falls GPU-Treiber
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

Das Installationsskript ist idempotent – einfach erneut ausführen (oder explizit mit
`--update`), um auf die neueste Pinokio-Version zu aktualisieren; die Dienste werden
dabei neu gestartet:
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)" -- --update
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
- VM bekommt beim ersten Boot keine IP: `create-vm.sh` ermittelt die IP mehrstufig
  und subnetz-unabhängig – erst passives Polling von Gast-Agent/ARP/FDB
  (`AGENT_WAIT_TIMEOUT`, Standard 120 s), dann aktive Runden (Ping-Sweep,
  DHCP-yiaddr-Mithören, `tcpdump` am Tap/an der Bridge), bei totalem Funkstille
  eine Tiefendiagnose (Gast-Netzconfig per read-only Disk-Mount) und am Ende eine
  gezielte Checkliste. Volles Log: `/var/log/pinokio-create-vm-<VMID>.log`.
  Wichtig: das VM-Subnetz muss nicht dem "üblichen" 192.168.x entsprechen
  (Live-Fall: 10.120.1.x) – die Erkennung filtert bewusst nicht nach Präfixen.
  Hat die Bridge keine IPv4, kann der Host keine ARP-Einträge lernen – dann
  tragen Tap-Sniff und Gast-Agent (wird per first-boot-Unit nachinstalliert).
  In der VM selbst hilft: `networkctl status; ip a; cat /etc/systemd/network/89-pinokio.network`.
  Alternativ manuell: `qm terminal <VMID>` (Login: `root`, Passwort steht in der Skript-Ausgabe unter
  "Konsolen-PW" – funktioniert nur lokal über die Konsole, nicht per SSH)
- Pinokio-Web-UI fragt nach "System password to generate an HTTPS certificate":
  einfach abbrechen. Das ist Pinokios optionaler Secure-Localhost-Modus – der
  Installer schaltet ihn per `PINOKIO_HTTPS_ACTIVE=0` im systemd-Unit ab, da der
  Dienstbenutzer `pinokio` bewusst kein Passwort hat. HTTP auf Port 42000 ist der
  vorgesehene Weg (siehe Sicherheitshinweis)
- Pinokio-Dienst crasht mit Exit 127 ("error while loading shared libraries"):
  `install.sh` installiert die Electron-Laufzeit-Bibliotheken vorab und prüft per
  `ldd`; falls trotzdem eine fehlt, nennt die Healthcheck-Ausgabe die konkrete
  Bibliothek. Manuell: fehlendes Paket installieren (z.B. `apt-get install -y
  libasound2` – Ubuntu 24.04: `libasound2t64`) und `systemctl restart pinokio`
- Bei wiederholten, unerklärlichen Fehlern im Gast (fehlende Pakete, kein Netzwerk
  trotz allem): das gecachte Cloud-Image könnte beschädigt sein. Mit
  `IMG_REDOWNLOAD=yes` beim nächsten Lauf erzwingt man einen frischen Download.

## VM wieder entfernen (bei Nutzung von `create-vm.sh`)

```bash
qm stop <VMID>
qm destroy <VMID>
```

## Pinokio deinstallieren (VM bleibt bestehen)

Entweder das separate Skript:

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/uninstall.sh -o uninstall.sh
bash uninstall.sh              # Apps/Modelle bleiben erhalten
bash uninstall.sh --purge-data # löscht zusätzlich alle Apps/Modelle
```

oder direkt über `install.sh` (gleiches Ergebnis):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/Pinokio-Proxmox/main/install.sh)" -- --uninstall [--purge-data]
```

## Contributing

Pull Requests sind willkommen, z.B. für ROCm-Unterstützung, LXC-Unterstützung
(sofern ohne volles GPU-Passthrough sinnvoll nutzbar) oder Verbesserungen an der
Xvfb/VNC-Ersteinrichtung.
