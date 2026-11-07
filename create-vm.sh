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

# ==== TTY-STATUS: BEGIN (auch von den Tests gesourct) ====
# Die TTY-Erkennung muss VOR jeglicher Ausgabenumleitung passieren: weiter
# unten leitet 'exec > >(tee ...)' stdout in die Log-Pipe um - danach wäre
# [ -t 1 ] dauerhaft false, obwohl ein echtes Terminal existiert. HAVE_TTY
# steuert, ob interaktive Befehle erlaubt sind (whiptail-Assistent, qm
# terminal). Ohne TTY: niemals interaktive Befehle versuchen - nur klare
# Textanleitungen ausgeben (Live-Bug: 'qm terminal' ohne TTY crashte mit
# socat "Inappropriate ioctl for device").
if [ -t 0 ] && [ -t 1 ]; then
  HAVE_TTY=1
else
  HAVE_TTY=0
fi
# ==== TTY-STATUS: ENDE ====

# ----------------------------------------------------------------------------
# Ausgabe-Hilfsfunktionen + Fehler-Transparenz
# ----------------------------------------------------------------------------
C_INFO='\033[1;34m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_STEP='\033[1;36m'; C_RESET='\033[0m'
msg_info() { echo -e "${C_INFO}➜${C_RESET} $*"; }
msg_ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
msg_warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
msg_err()  { echo -e "${C_ERR}✖${C_RESET} $*" >&2; }

SCRIPT_BUILD="2026-11-07-v7"
echo -e "${C_STEP}Pinokio-Proxmox create-vm.sh – Build ${SCRIPT_BUILD}${C_RESET}"
echo -e "${C_STEP}Wenn hier NICHT 'Build ${SCRIPT_BUILD}' steht, führst du eine alte Kopie aus!${C_RESET}"
echo -e "${C_STEP}Log: /var/log/pinokio-create-vm-<VMID>.log (wird nach Feststehen der VMID angelegt)${C_RESET}"

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

# ==== IP-ERMITTLUNG: BEGIN (auch von den Tests gesourct) ====
# ============================================================================
# Aktive Netzwerk-Diagnose: IP der VM auch dann finden, wenn Gast-Agent fehlt
# und die ARP-Tabelle leer bleibt. Bewusst subnetz-unabhängig: Es gibt keine
# Filter oder Annahmen auf 192.168.* o.ä. - das VM-Netz kann jedes Präfix
# haben (Live-Fall: 10.120.1.x). Mehrstufig, siehe detect_vm_ip():
#   Stufe 1: Passiv pollen (Gast-Agent, ARP, Bridge-FDB)
#   Stufe 2: statische Wunsch-IP (ipconfig0) per Ping + Port 22 verifizieren
#   Stufe 3: aktive Runden - Ping-Sweep, DHCP-yiaddr-Sniff, tcpdump am Tap/an
#            der Bridge, danach erneut ARP
#   Stufe 4: Tiefendiagnose - Gast-Disk read-only mounten, Logs auslesen
# ============================================================================
# Strikte IPv4-Prüfung (4 Oktette, je 0-255). Schützt davor, trunkierte
# Sniff-/ARP-Treffer wie '192.168.178' in den SSH-Wait zu übernehmen (kostet
# sonst 5 Minuten Timeout auf einer Adresse, die nie antworten kann).
valid_ipv4() {
  echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++){if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1} exit 0} {exit 1}' >/dev/null 2>&1
}

sniff_vm_ip() {
  local mac="$1" dev="$2" secs="$3" raw="" ip=""
  SNIFF_PACKETS=0
  SNIFF_RESULT=""
  command -v tcpdump >/dev/null 2>&1 || return 0
  raw="$(timeout "$secs" tcpdump -i "$dev" -n -l -c 200 "ether src ${mac}" 2>/dev/null || true)"
  SNIFF_PACKETS="$(echo "$raw" | grep -c . || true)"
  # 1) ARP-Sender-IP: 'who-has X tell Y' -> Y ist die IP der VM
  ip="$(echo "$raw" | grep -oE 'tell [0-9]+(\.[0-9]+){3}' | awk '{print $2}' \
      | grep -vE '^(0\.|127\.|169\.254\.)' | head -1 || true)"
  # 1a) ARP-Reply der VM (Gratuitous ARP direkt nach der DHCP-Zuteilung):
  #     'ARP Reply <ip> is-at <mac>'
  if [ -z "$ip" ]; then
    ip="$(echo "$raw" | grep -oiE 'reply [0-9]+(\.[0-9]+){3}' | awk '{print $2}' \
        | grep -vE '^(0\.|127\.|255\.|169\.254\.)' | head -1 || true)"
  fi
  # 2) Quell-IP aus IP-Paketen MIT Port (tcpdump: 'IP A.B.C.D.port > ...') –
  #    nur die Port-Gruppe entfernen. (Alter Code hat hier auch bei portlosen
  #    Zeilen das letzte Oktett abgeschnitten -> '192.168.178'.)
  #    Sicher, weil der Capture-Filter 'ether src <mac>' nur eigenes Traffic
  #    der VM enthält - die Quell-IP gehört also der VM.
  if [ -z "$ip" ]; then
    ip="$(echo "$raw" | grep -oE 'IP ([0-9]+\.){3}[0-9]+\.[0-9]+' \
        | sed -E 's/^IP //; s/\.[0-9]+$//' \
        | grep -vE '^(0\.|127\.|255\.|169\.254\.)' | head -1 || true)"
  fi
  # 3) Portlose IP-Zeilen (z.B. ICMP: 'IP A.B.C.D > ...') als volle IP übernehmen.
  if [ -z "$ip" ]; then
    ip="$(echo "$raw" | grep -oE 'IP ([0-9]+\.){3}[0-9]+ ' \
        | sed -E 's/^IP //; s/ $//' \
        | grep -vE '^(0\.|127\.|255\.|169\.254\.)' | head -1 || true)"
  fi
  # 4) Sicherheitsnetz: nur gültige IPv4 weitergeben.
  if [ -n "$ip" ] && ! valid_ipv4 "$ip"; then
    # >&2: die Warnung darf nicht unbeabsichtigt im Skript-Output landen.
    msg_warn "Sniff-Treffer '${ip}' verworfen (ungültige IP)." >&2
    ip=""
  fi
  # Ergebnis als GLOBAL zurückgeben (nicht per stdout): Der Aufrufer ruft
  # diese Funktion direkt (ohne $( ... )) auf - nur so überleben auch die
  # Zähler SNIFF_PACKETS/SNIFF_RESULT den Subshell-Rand. (Alter Code verlor
  # SNIFF_PACKETS genau dadurch - die "Gast sendet Traffic"-Diagnose griff nie.)
  SNIFF_RESULT="$ip"
  return 0
}

# Lauscht auf DHCP-Verkehr der VM (beide Richtungen) und liest aus den
# OFFER/ACK-Paketen des Servers die zugewiesene Adresse ('your address' bzw.
# 'yiaddr'). Funktioniert subnetz-unabhängig und auch dann, wenn der Host
# selbst keine IPv4 an der Bridge hat (dann lernt er weder ARP-Einträge noch
# kann er pingen - das Mithören am Tap ist dort der einzige Host-seitige Weg).
# Rückgabe wie sniff_vm_ip: SNIFF_RESULT (IP oder leer) + DHCP_PACKETS als Globals.
sniff_dhcp_offer() {
  local mac="$1" dev="$2" secs="$3" raw="" ip=""
  DHCP_PACKETS=0
  SNIFF_RESULT=""
  command -v tcpdump >/dev/null 2>&1 || return 0
  raw="$(timeout "$secs" tcpdump -i "$dev" -n -l -v -c 40 \
      "ether host ${mac} and (udp port 67 or udp port 68)" 2>/dev/null || true)"
  DHCP_PACKETS="$(echo "$raw" | grep -c . || true)"
  ip="$(echo "$raw" | grep -oiE '(your address|yiaddr)[ :=]+[0-9]+(\.[0-9]+){3}' \
      | grep -oE '[0-9]+(\.[0-9]+){3}' \
      | grep -vE '^(0\.|127\.|169\.254\.)' | head -1 || true)"
  if [ -n "$ip" ] && valid_ipv4 "$ip"; then
    SNIFF_RESULT="$ip"
  fi
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

# Eine einzige Gast-Agent-Abfrage: gibt die erste globale IPv4 der VM aus
# (oder nichts). Der Agent liefert nach dem Boot erst nach einigen Sekunden
# Daten - daher wird diese Abfrage in Stufe 1 wiederholt gepollt. Der Filter
# nimmt nur echte globale IPv4-Adressen (kein Loopback, kein Link-Local/APIPA).
agent_query_ip() {
  local vmid="$1" json="" ip=""
  json="$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)"
  [ -n "$json" ] || return 0
  ip="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for iface in data:
    if iface.get("name") == "lo":
        continue
    for addr in iface.get("ip-addresses", []):
        ipaddr = addr.get("ip-address", "") or ""
        if addr.get("ip-address-type") != "ipv4":
            continue
        # global = weder Loopback noch Link-Local (APIPA) noch 0.0.0.0
        if ipaddr.startswith("127.") or ipaddr.startswith("169.254.") or ipaddr.startswith("0."):
            continue
        print(ipaddr)
        sys.exit(0)
' 2>/dev/null || true)"
  if [ -n "$ip" ] && valid_ipv4 "$ip"; then
    printf '%s\n' "$ip"
  fi
  return 0
}

# ARP-Tabelle des Hosts nach der MAC der VM durchsuchen (nur gültige IPv4).
arp_lookup() {
  local mac="$1" ip=""
  [ -n "$mac" ] || return 0
  ip="$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1 || true)"
  if [ -n "$ip" ] && valid_ipv4 "$ip"; then
    printf '%s\n' "$ip"
  fi
  return 0
}

# Statische Kandidaten-IP aktiv verifizieren: nur übernehmen, wenn der
# SSH-Port 22 antwortet (nie blind - sonst hängt der SSH-Wait 5 Minuten an
# einer toten Adresse).
try_static_ip() {
  local cand="$1"
  [ -n "$cand" ] || return 0
  ping -c2 -W2 "$cand" >/dev/null 2>&1 || true
  if timeout 3 bash -c "</dev/tcp/${cand}/22" 2>/dev/null; then
    printf '%s\n' "$cand"
  fi
  return 0
}

# Stufe 3: aktive Runden. Jede Runde: Subnetz anpingen (füllt die ARP-Tabelle),
# ARP prüfen, DHCP-yiaddr-Sniff am Tap, generischer Sniff am Tap und an der
# Bridge, danach erneut ARP. Mehrere Runden mit Pause, weil der Gast sein DHCP
# (besonders nach frischem Boot) zeitversetzt macht - ein einzelnes 20s-Fenster
# Minuten nach dem Boot sah im Live-Lauf nichts, weil der Gast da schon wieder
# funkstille hatte.
active_discovery_rounds() {
  local ip="" round_num=0 tap_dev="tap${VMID}i0"
  DIAG_NO_TRAFFIC=0
  DIAG_TAP_OK=0

  # tcpdump nur nachinstallieren, wenn überhaupt gesnifft werden kann
  if [ -n "$MAC" ] && ! command -v tcpdump >/dev/null 2>&1; then
    msg_info "Installiere tcpdump für die Netzwerk-Diagnose..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null 2>&1 || true
  fi

  # Ist der Tap-Geräte-Port der VM überhaupt an der Bridge angeschlossen?
  if ip link show "$tap_dev" >/dev/null 2>&1; then
    if ip link show "$tap_dev" | grep -q "master ${BRIDGE}"; then
      msg_ok "${tap_dev} ist an ${BRIDGE} angeschlossen."
    else
      msg_warn "Diagnose: ${tap_dev} existiert, hängt aber NICHT an ${BRIDGE}! (master: $(ip link show "$tap_dev" | grep -oE 'master [^ ]+' || echo 'keine'))"
    fi
  else
    msg_warn "Diagnose: Tap-Gerät ${tap_dev} existiert nicht - VM-NIC nicht verbunden?"
  fi

  if [ -z "$MAC" ]; then
    msg_warn "Keine MAC der VM ermittelbar - Sniffing übersprungen, nur Ping-Sweep + ARP."
  elif ! command -v tcpdump >/dev/null 2>&1; then
    msg_warn "tcpdump nicht verfügbar - Sniffing übersprungen, nur Ping-Sweep + ARP."
  fi

  while [ "$round_num" -lt "$SNIFF_ROUNDS" ]; do
    round_num=$((round_num + 1))
    msg_info "Aktive Runde ${round_num}/${SNIFF_ROUNDS}: Ping-Sweep -> ARP -> Sniff..."

    ping_sweep
    ip="$(arp_lookup "$MAC")"
    if [ -n "$ip" ]; then
      VM_IP="$ip"
      msg_ok "IP nach Ping-Sweep aus der ARP-Tabelle ermittelt: ${VM_IP}"
      return 0
    fi

    if [ -n "$MAC" ] && command -v tcpdump >/dev/null 2>&1; then
      # 0) Gezielt DHCP OFFER/ACK mitlesen (subnetz-unabhängig, liefert die
      #    zugewiesene Adresse direkt aus dem Server-Verkehr zur VM)
      if ip link show "$tap_dev" >/dev/null 2>&1; then
        msg_info "Lausche ${SNIFF_DHCP_SECS}s an ${tap_dev} auf DHCP-OFFER/ACK..."
        sniff_dhcp_offer "$MAC" "$tap_dev" "$SNIFF_DHCP_SECS"
        ip="$SNIFF_RESULT"
        if [ -n "$ip" ]; then
          VM_IP="$ip"
          msg_ok "IP aus dem DHCP-Verkehr ermittelt: ${VM_IP}"
          return 0
        fi
        if [ "$DHCP_PACKETS" -gt 0 ]; then
          msg_info "DHCP-Verkehr sichtbar (${DHCP_PACKETS} Pakete), aber kein 'your address' - der Server antwortet evtl. verzögert."
        fi
      fi
      # 1) Direkt am Tap lauschen: zeigt Pakete, die der GAST selbst sendet
      if ip link show "$tap_dev" >/dev/null 2>&1; then
        msg_info "Lausche ${SNIFF_SECS}s direkt an ${tap_dev} (was sendet der Gast?)..."
        sniff_vm_ip "$MAC" "$tap_dev" "$SNIFF_SECS"
        ip="$SNIFF_RESULT"
        if [ -n "$ip" ]; then
          VM_IP="$ip"
          msg_ok "IP aus dem Traffic des Gastes ermittelt: ${VM_IP}"
          return 0
        fi
        if [ "$SNIFF_PACKETS" -eq 0 ]; then
          DIAG_NO_TRAFFIC=1
          msg_warn "Diagnose: Der Gast sendet NICHT EINMAL am Tap-Gerät (${tap_dev}) etwas."
          msg_warn "=> Das Gast-Netzwerk ist vermutlich tot (networkd startet nicht / kein DHCP-Versuch)."
        else
          DIAG_TAP_OK=1
          msg_info "Der Gast sendet Pakete am Tap (${SNIFF_PACKETS} gesehen) - prüfe Bridge-Weiterleitung..."
        fi
      fi
      # 2) Fallback: an der Bridge lauschen
      if [ "$DIAG_NO_TRAFFIC" != "1" ]; then
        msg_info "Lausche ${SNIFF_SECS}s an ${BRIDGE}..."
        sniff_vm_ip "$MAC" "$BRIDGE" "$SNIFF_SECS"
        ip="$SNIFF_RESULT"
        if [ -n "$ip" ]; then
          VM_IP="$ip"
          msg_ok "IP aus dem Netzwerk-Traffic ermittelt: ${VM_IP}"
          return 0
        fi
        if [ "$SNIFF_PACKETS" -eq 0 ] && [ "$DIAG_TAP_OK" = "1" ]; then
          msg_warn "Diagnose: Gast sendet am Tap, aber NICHTS kommt an ${BRIDGE} an -"
          msg_warn "=> Bridge-Weiterleitung/Firewall blockt (pve-firewall status prüfen!)."
        fi
      fi
    fi

    # Nach dem Sniffen nochmals ARP prüfen (der Traffic füllt ggf. die Tabelle)
    ip="$(arp_lookup "$MAC")"
    if [ -n "$ip" ]; then
      VM_IP="$ip"
      msg_ok "IP aus der ARP-Tabelle ermittelt (nach Sniff): ${VM_IP}"
      return 0
    fi

    if [ "$round_num" -lt "$SNIFF_ROUNDS" ]; then
      msg_info "Pause ${SNIFF_PAUSE}s - der Gast könnte sein DHCP noch nachholen..."
      sleep "$SNIFF_PAUSE"
    fi
  done
  return 0
}

# Stufe 4: Tiefendiagnose - wenn der Gast komplett schweigt, seine Disk vom
# Host aus (read-only) mounten und die Netzwerk-/Cloud-Init-Logs des Gastes
# auslesen. Liefert die definitive Ursache, ohne Login/Netzwerk zu benötigen.
run_deep_diagnosis() {
  local deep_file="/tmp/pinokio-deepdiag-${VMID}.txt"
  local mnt="/mnt/pinokio-diag"
  msg_info "Tiefendiagnose: Stoppe VM, mounte Disk read-only, lese Gast-Logs..."

  (
    set +e
    qm stop "$VMID" >/dev/null 2>&1
    SCASI_LINE="$(qm config "$VMID" 2>/dev/null | awk '/^scsi0:/{print $2}' | head -1)"
    VOL_SPEC="${SCASI_LINE%%,*}"
    VOL_DEV="$(pvesm path "$VOL_SPEC" 2>/dev/null)"
    [ -z "$VOL_DEV" ] && exit 1
    modprobe nbd max_part=16 >/dev/null 2>&1
    NBD_DEV="$(find_free_nbd)"
    [ -z "$NBD_DEV" ] && exit 1
    VOL_FMT="$(qemu-img info --output=json "$VOL_DEV" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("format","raw"))
except Exception:
    print("raw")' 2>/dev/null)"
    [ -z "$VOL_FMT" ] && VOL_FMT="raw"
    qemu-nbd -c "$NBD_DEV" -f "$VOL_FMT" --read-only "$VOL_DEV" >/dev/null 2>&1
    sleep 1
    partprobe "$NBD_DEV" >/dev/null 2>&1
    mkdir -p "$mnt"
    ROOT_PART=""
    for p in "${NBD_DEV}p1" "${NBD_DEV}p2" "${NBD_DEV}p15" "$NBD_DEV"; do
      if [ -b "$p" ] && blkid -o value -s TYPE "$p" 2>/dev/null | grep -qE '^ext[234]$'; then
        if mount -o ro "$p" "$mnt" 2>/dev/null; then ROOT_PART="$p"; break; fi
      fi
    done
    {
      echo "=== Root-Partition: ${ROOT_PART:-NICHT GEFUNDEN}"
      echo
      echo "=== Unsere Netzconfig (muss existieren): /etc/systemd/network/89-pinokio.network"
      cat "$mnt/etc/systemd/network/89-pinokio.network" 2>&1 || echo "FEHLT!"
      echo
      echo "--- networkd enabled?"
      ls -l "$mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>&1 || true
      echo
      echo "--- Gast-Agent first-boot Unit (muss existieren):"
      ls -l "$mnt/etc/systemd/system/multi-user.target.wants/pinokio-install-guest-agent.service" 2>&1 || true
      echo
      echo "=== Ist cloud-init ueberhaupt installiert? (sollte disabled sein)"
      ls -la "$mnt/usr/bin/cloud-init" 2>&1 || true
      echo
      echo "=== /etc/cloud Verzeichnis"
      ls "$mnt/etc/cloud/" 2>&1 || true
      ls "$mnt/etc/cloud/cloud.cfg.d/" 2>&1 || true
      echo
      echo "=== Netzwerk-Konfiguration im Gast"
      echo "--- /etc/network/interfaces:"
      cat "$mnt/etc/network/interfaces" 2>&1 || true
      echo "--- /etc/network/interfaces.d/:"
      ls "$mnt/etc/network/interfaces.d/" 2>&1 || true
      cat "$mnt/etc/network/interfaces.d/"* 2>/dev/null || true
      echo "--- /etc/netplan/:"
      ls "$mnt/etc/netplan/" 2>&1 || true
      cat "$mnt/etc/netplan/"* 2>/dev/null || true
      echo
      echo "=== /var/log/cloud-init.log (letzte 80 Zeilen)"
      tail -80 "$mnt/var/log/cloud-init.log" 2>&1 || true
      echo
      echo "=== /var/log/cloud-init-output.log (letzte 50 Zeilen)"
      tail -50 "$mnt/var/log/cloud-init-output.log" 2>&1 || true
      echo
      echo "=== /var/lib/cloud Struktur"
      find "$mnt/var/lib/cloud" -maxdepth 3 2>&1 | head -40 || true
    } > "$deep_file" 2>&1
    umount "$mnt" >/dev/null 2>&1
    qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1
  ) || true

  qm start "$VMID" >/dev/null 2>&1 || true

  if [ -s "$deep_file" ]; then
    msg_ok "Gast-Logs extrahiert (${deep_file}):"
    echo -e "${C_STEP}──────────────── BEGINN GAST-DIAGNOSE ────────────────${C_RESET}"
    cat "$deep_file"
    echo -e "${C_STEP}───────────────── ENDE GAST-DIAGNOSE ─────────────────${C_RESET}"
    msg_warn "Bitte diesen Abschnitt vollständig kopieren und beim Issue melden."
  else
    msg_warn "Tiefendiagnose fehlgeschlagen (nbd/mount nicht möglich?). Log manuell prüfen."
  fi
  return 0
}

# Gezielte Checkliste für den manuellen Fehlerfall (statt generischem
# "Konsole öffnen"). Deckt die Live-Fall-Fragen ab: richtige Bridge?,
# Bridge-Subnetz vs. VM-Subnetz?, DHCP sichtbar?, Gast-Agent?, Lease?
print_ip_failure_checklist() {
  echo
  msg_info "Checkliste zur manuellen Fehlersuche (in dieser Reihenfolge):"
  echo "  1) Hängt die VM an der richtigen Bridge?"
  echo "       qm config ${VMID} | grep net0        # BRIDGE=${BRIDGE} erwartet"
  echo "  2) Hat ${BRIDGE} eine IPv4 im VM-Subnetz?"
  echo "       ip -4 addr show dev ${BRIDGE}"
  echo "     Ohne IPv4 an der Bridge lernt der Host keine ARP-Einträge und der"
  echo "     Ping-Sweep läuft leer - dann sind Tap-Sniff (oben automatisch gelaufen)"
  echo "     und der Gast-Agent die einzigen Host-seitigen Wege."
  echo "  3) Sieht der Host DHCP-Verkehr der VM? (30s mitlaufen lassen, Strg+C beendet)"
  echo "       tcpdump -ni ${BRIDGE} -v 'udp port 67 or udp port 68'"
  echo "     Zu sehen sein müssen DISCOVER/REQUEST der VM (MAC ${MAC:-?}) und OFFER/ACK"
  echo "     des Servers mit 'your address <IP>'. Bleibt es stumm, sendet der Gast nichts."
  echo "  4) Gast-Agent (wird seit diesem Build beim ersten Boot automatisch nachinstalliert):"
  echo "       qm guest cmd ${VMID} ping"
  echo "  5) DHCP-Server/Router prüfen: hat die MAC ${MAC:-?} eine Lease? Subnetz beachten -"
  echo "     das VM-Netz muss nicht 192.168.x sein (Live-Fall: 10.120.1.x)."
  echo "  6) Direkt in der Konsole nachsehen:"
  echo "       qm terminal ${VMID}  ->  Login: root  ->  'ip a; networkctl status'"
  return 0
}

# Orchestrierung der mehrstufigen IP-Ermittlung. Setzt bei Erfolg VM_IP
# (global), sonst leeres VM_IP. Läuft unter set +e / QUIET_ERR=1 (der Aufrufer
# setzt das) - "nichts gefunden" ist hier ein normales Zwischenergebnis,
# kein Fehler. Jede Stufe meldet ihr Ergebnis klar, bevor die nächste startet.
detect_vm_ip() {
  VM_IP=""
  DIAG_NO_TRAFFIC=0
  DIAG_TAP_OK=0
  local ip="" i=0 fdb_state="" qm_state=""
  local stage1_deadline=0

  # ── Stufe 1: Passiv pollen - Gast-Agent, ARP-Tabelle, Bridge-FDB ─────────
  # Der Gast-Agent braucht nach dem Boot einige Sekunden (systemd startet ihn
  # spät; die first-boot-Unit installiert ihn erst nach networkd). ARP lernt
  # der Host automatisch, sobald der Gast sein DHCP macht. Nach Ablauf des
  # Fensters wird NICHT aufgegeben, sondern mit Stufe 2 weitergemacht.
  msg_info "Stufe 1/4: Passiv auf Gast-Agent/ARP warten (max. ${AGENT_WAIT_TIMEOUT}s, Poll alle ${AGENT_POLL_INTERVAL}s)..."
  stage1_deadline=$(( SECONDS + AGENT_WAIT_TIMEOUT ))
  while [ "$SECONDS" -lt "$stage1_deadline" ]; do
    i=$((i + 1))
    ip="$(agent_query_ip "$VMID")"
    if [ -n "$ip" ]; then
      VM_IP="$ip"
      msg_ok "IP über den Gast-Agent ermittelt: ${VM_IP}"
      return 0
    fi
    ip="$(arp_lookup "$MAC")"
    if [ -n "$ip" ]; then
      VM_IP="$ip"
      msg_ok "IP aus der ARP-Tabelle ermittelt: ${VM_IP}"
      return 0
    fi
    fdb_state="kein Eintrag"
    if [ -n "$MAC" ] && command -v bridge >/dev/null 2>&1; then
      if bridge fdb show br "$BRIDGE" 2>/dev/null | grep -qi "$MAC"; then
        fdb_state="MAC an Bridge sichtbar (Gast sendet L2)"
      fi
    fi
    if [ $((i % 6)) -eq 0 ]; then
      qm_state="$(qm status "$VMID" 2>/dev/null || echo unbekannt)"
      msg_info "... $((i * AGENT_POLL_INTERVAL))s / ${AGENT_WAIT_TIMEOUT}s | VM: ${qm_state} | Agent: keine Antwort | ARP: leer | FDB: ${fdb_state}"
    fi
    sleep "$AGENT_POLL_INTERVAL"
  done
  msg_warn "Stufe 1 ohne Erfolg: Gast-Agent antwortet nicht, ARP/FDB blieb ${AGENT_WAIT_TIMEOUT}s leer."
  msg_warn "-> Fahre fort mit Stufe 2/3 (der Agent ist kein Muss - Cloud-Images bringen ihn erst nach der first-boot-Unit mit)."

  # ── Stufe 2: statische Wunsch-IP verifizieren (Ping + SSH-Port) ──────────
  if [ -n "$STATIC_CANDIDATE" ]; then
    msg_info "Stufe 2/4: Prüfe statische Wunsch-IP ${STATIC_CANDIDATE} direkt (Ping + Port 22)..."
    ip="$(try_static_ip "$STATIC_CANDIDATE")"
    if [ -n "$ip" ]; then
      VM_IP="$ip"
      msg_ok "Statische IP antwortet auf SSH - übernommen: ${VM_IP}"
      return 0
    fi
    msg_warn "Statische IP ${STATIC_CANDIDATE} antwortet nicht - fahre fort mit Stufe 3 (aktive Diagnose)."
  else
    msg_info "Stufe 2/4: Keine statische IP konfiguriert (ipconfig0 = DHCP) - übersprungen."
  fi

  # ── Stufe 3: aktive Runden (Ping-Sweep + ARP + tcpdump-Sniff) ────────────
  msg_info "Stufe 3/4: Aktive Diagnose (${SNIFF_ROUNDS} Runden: Ping-Sweep, DHCP-Sniff ${SNIFF_DHCP_SECS}s, tcpdump je ${SNIFF_SECS}s)..."
  active_discovery_rounds
  if [ -n "$VM_IP" ]; then
    return 0
  fi

  # ── Stufe 4: Tiefendiagnose (nur wenn der Gast komplett schweigt) ────────
  if [ "$DIAG_NO_TRAFFIC" = "1" ] && [ "${DEEP_DIAG:-yes}" != "no" ]; then
    run_deep_diagnosis
  fi

  return 0
}
# ==== IP-ERMITTLUNG: ENDE ====

# ==== TTY-KONSOLE: BEGIN (auch von den Tests gesourct) ====
# ============================================================================
# Die VM-Konsole darf NIE ohne echtes Terminal geöffnet werden: 'qm terminal'
# hängt stdin/stdout an socat, das tcgetattr auf beiden Filedeskriptoren
# macht - ohne TTY stirbt es mit "Inappropriate ioctl for device"
# (Live-Bug). Stattdessen: TTY-Gate + manuelle Anleitung, niemals crashen.
# ============================================================================
print_console_manual() {
  local vmid="$1"
  msg_info "Konsole manuell öffnen (dort einloggen und die IP ablesen):"
  echo "    Proxmox-WebUI -> VM ${vmid} -> Console (xterm.js)"
  echo "    oder auf dem Host:  qm terminal ${vmid}"
  echo
  echo "  In der Konsole nach dem Login (Benutzer: root) ausführen:"
  echo "    ip a                                # zeigt die IP-Adresse der VM"
  echo "    networkctl status                   # Netzwerk-Status im Gast"
  echo "    cat /etc/systemd/network/89-pinokio.network"
  echo "  Konsole verlassen: Strg+O (Anzeige lösen), dann Strg+Q (qm terminal beenden)"
  return 0
}

open_vm_console() {
  local vmid="$1"
  # TTY-Gate: stdin UND stdout müssen ein Terminal sein, gemessen VOR der
  # Log-Umleitung (in HAVE_TTY) - nach 'exec > >(tee ...)' wäre stdout eine
  # Pipe und [ -t 1 ] dauerhaft false, obwohl ein Terminal existiert.
  if [ "${HAVE_TTY:-0}" != "1" ]; then
    msg_info "Kein interaktives Terminal erkannt - die Konsole wird NICHT automatisch geöffnet."
    print_console_manual "$vmid"
    return 0
  fi
  msg_info "Öffne die VM-Konsole in 3 Sekunden..."
  sleep 3
  # stdout/stderr dieses Skripts laufen zu diesem Zeitpunkt in die Log-Pipe
  # (tee) - die Konsole wird deshalb explizit am echten Terminal (/dev/tty)
  # angeschlossen. Fehlschlag ist kein Abbruch, sondern nur die Anleitung.
  if qm terminal "$vmid" </dev/tty >/dev/tty 2>&1; then
    return 0
  fi
  msg_warn "'qm terminal' wurde beendet oder konnte nicht gestartet werden - Anleitung folgt."
  print_console_manual "$vmid"
  return 0
}
# ==== TTY-KONSOLE: ENDE ====

# ----------------------------------------------------------------------------
# Schritt 1: Vorabprüfungen
# ----------------------------------------------------------------------------
step 1 "Vorabprüfungen"

if [ "$(id -u)" -ne 0 ]; then
  msg_err "Bitte als root ausführen."
  exit 1
fi
for cmd in qm pvesh pvesm python3 lspci qemu-nbd qemu-img ip; do
  command -v "$cmd" >/dev/null 2>&1 || { msg_err "'$cmd' nicht gefunden – dieses Skript muss auf dem Proxmox-Host laufen."; exit 1; }
done
if command -v pveversion >/dev/null 2>&1; then
  msg_info "Proxmox-Version: $(pveversion 2>/dev/null | head -1 || echo unbekannt)"
fi
# tcpdump/bridge werden für die aktive IP-Diagnose gebraucht (kein harter Abbruch hier,
# sie werden bei Bedarf in Schritt 7 nachinstalliert/geprüft).
command -v tcpdump >/dev/null 2>&1 || msg_warn "tcpdump fehlt – wird bei Bedarf in Schritt 7 nachinstalliert."
command -v bridge >/dev/null 2>&1 || msg_warn "'bridge' (iproute2) fehlt – FDB-Fallback in Schritt 7 eingeschränkt."
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
# IP-Ermittlung (mehrstufig, siehe detect_vm_ip) - subnetz-unabhängig:
AGENT_WAIT_TIMEOUT="${AGENT_WAIT_TIMEOUT:-${IP_WAIT_TIMEOUT:-120}}"  # Stufe 1: passives Polling (Agent/ARP/FDB), Sekunden
AGENT_POLL_INTERVAL="${AGENT_POLL_INTERVAL:-5}"                      # Stufe 1: Poll-Intervall, Sekunden
SNIFF_ROUNDS="${SNIFF_ROUNDS:-3}"                                    # Stufe 3: aktive Runden (Ping-Sweep + Sniff)
SNIFF_DHCP_SECS="${SNIFF_DHCP_SECS:-15}"                             # Stufe 3: Fenster für DHCP-yiaddr-Sniff, Sekunden
SNIFF_SECS="${SNIFF_SECS:-30}"                                       # Stufe 3: Fenster für generischen Sniff je Lauscher, Sekunden
SNIFF_PAUSE="${SNIFF_PAUSE:-10}"                                     # Stufe 3: Pause zwischen den Runden, Sekunden
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

if [ -z "$NONINTERACTIVE" ] && [ "$HAVE_TTY" = "1" ]; then
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

# Ab hier alles zusätzlich in eine Log-Datei spiegeln (Fehlersuche beim Erstlauf).
LOG_FILE="/var/log/pinokio-create-vm-${VMID}.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
# shellcheck disable=SC2094
exec > >(tee -a "$LOG_FILE") 2>&1
msg_info "Log-Datei: ${LOG_FILE}"
msg_info "Effektive Konfiguration: VMID=${VMID} NAME=${VM_NAME} MACHINE=${MACHINE} OS=${OS_IMAGE} CORES=${CORES} MEM=${MEMORY} DISK=${DISK_SIZE}G STORAGE=${STORAGE} BRIDGE=${BRIDGE} NET=${NET_MODEL} IPCONFIG=${IPCONFIG}"

# Später Preflight: Storage + Bridge existieren wirklich?
if ! pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  msg_err "Storage '${STORAGE}' existiert nicht (pvesm status). Verfügbare Storages:"
  pvesm status 2>/dev/null || true
  exit 1
fi
if [ ! -e "/sys/class/net/${BRIDGE}" ]; then
  msg_err "Bridge '${BRIDGE}' existiert nicht (/sys/class/net). Vorhanden:"
  ls /sys/class/net/ 2>/dev/null || true
  exit 1
fi
BRIDGE_CIDR="$(ip -4 -o addr show dev "${BRIDGE}" 2>/dev/null | awk '{print $4; exit}' || true)"
if [ -n "$BRIDGE_CIDR" ]; then
  msg_ok "Bridge ${BRIDGE} hat IP ${BRIDGE_CIDR} (Ping-Sweep möglich bei /24)."
else
  msg_warn "Bridge ${BRIDGE} hat keine IPv4 – Ping-Sweep/FDB-Fallback eingeschränkt."
fi

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
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$IMG_PATH" "$IMG_URL"
  msg_ok "Download abgeschlossen."
fi

# Integritätsprüfung: Ein korruptes/trunkiertes Image bootet evtl. teilweise,
# produziert aber im Gast beliebige Folgefehler (z.B. cloud-init ohne Netz).
if ! qemu-img check "$IMG_PATH" >/dev/null 2>&1; then
  msg_warn "qemu-img check meldet Fehler im Image (${IMG_PATH}) - lösche und lade neu..."
  rm -f "$IMG_PATH"
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$IMG_PATH" "$IMG_URL"
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
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$IMG_PATH" "$IMG_URL"
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
# Schritt 5b: Image direkt vorbereiten (UNABHÄNGIG von cloud-init!)
# ----------------------------------------------------------------------------
# Passwort, SSH-Key, SSH-Hostkeys und DHCP-Netzwerkkonfiguration werden direkt
# in das importierte Image geschrieben (Disk via qemu-nbd gemountet). Damit
# funktioniert der erste Boot garantiert - egal ob cloud-init im Gast arbeitet
# oder nicht. Cloud-init wird zudem explizit deaktiviert, damit es uns nicht
# in die Quere kommen kann.
# Sucht ein tatsächlich freies /dev/nbdX (size=0 laut sysfs). Trennt zur
# Sicherheit vorher jede Verbindung auf dem Kandidaten, falls von einem
# abgebrochenen vorherigen Lauf noch etwas offen hängt ("Failed to set NBD
# socket" ist meist genau das: eine verwaiste Verbindung von einem früheren,
# fehlgeschlagenen Durchlauf, die nie sauber getrennt wurde).
find_free_nbd() {
  local dev base sizefile sz
  for dev in /dev/nbd0 /dev/nbd1 /dev/nbd2 /dev/nbd3 /dev/nbd4 /dev/nbd5 /dev/nbd6 /dev/nbd7; do
    [ -b "$dev" ] || continue
    base="$(basename "$dev")"
    sizefile="/sys/class/block/${base}/size"
    sz="$(cat "$sizefile" 2>/dev/null)"
    if [ -z "$sz" ] || [ "$sz" = "0" ]; then
      qemu-nbd -d "$dev" >/dev/null 2>&1 || true
      echo "$dev"
      return 0
    fi
  done
  return 1
}

prepare_image() {
  local mnt="/mnt/pinokio-prepare"
  local vol_spec vol_dev part p nbd_dev
  vol_spec="$(qm config "$VMID" 2>/dev/null | awk '/^scsi0:/{print $2}' | cut -d, -f1)"
  vol_dev="$(pvesm path "$vol_spec" 2>/dev/null)"
  [ -b "$vol_dev" ] || { msg_err "VM-Disk nicht gefunden (${vol_spec} -> ${vol_dev})"; return 1; }

  modprobe nbd max_part=16 >/dev/null 2>&1 || true
  nbd_dev="$(find_free_nbd)"
  [ -n "$nbd_dev" ] || { msg_err "Kein freies /dev/nbdX gefunden (Kernel-Modul nbd fehlt, oder alle 8 Geräte sind belegt)."; return 1; }

  # Format automatisch erkennen: LVM/LVM-thin/ZFS liefern rohe Block-Devices
  # (raw), Verzeichnis-/NFS-Storage oft qcow2. Ohne "-f" verweigert qemu-nbd
  # bei rohen Block-Devices sicherheitshalber die Verbindung.
  local vol_fmt
  vol_fmt="$(qemu-img info --output=json "$vol_dev" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("format","raw"))
except Exception:
    print("raw")' 2>/dev/null)"
  [ -z "$vol_fmt" ] && vol_fmt="raw"

  qemu-nbd -c "$nbd_dev" -f "$vol_fmt" "$vol_dev" >/dev/null || { msg_err "qemu-nbd Verbinden fehlgeschlagen (Format: ${vol_fmt}, Device: ${vol_dev}, NBD: ${nbd_dev})"; return 1; }
  # Der Kernel-Partitions-Scan an NBD hinkt manchmal hinterher (Race): bis zu 15s
  # warten, bis Partitionsgeräte sichtbar sind, statt nach fix 1s zu mounten.
  msg_info "Warte auf Partitionsgeräte an ${nbd_dev}..."
  for _w in $(seq 1 15); do
    partprobe "$nbd_dev" >/dev/null 2>&1 || true
    if ls "${nbd_dev}"p* >/dev/null 2>&1; then break; fi
    sleep 1
  done

  mkdir -p "$mnt"
  part=""
  # Alle Partitionen dynamisch aufzählen statt starrer p1/p2/p3-Liste (je nach Image
  # liegt root anders). Whole-Disk als letzter Fallback.
  _parts="$(ls "${nbd_dev}"p* 2>/dev/null || true)"
  # shellcheck disable=SC2086
  for p in $_parts "$nbd_dev"; do
    [ -b "$p" ] || continue
    _fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    msg_info "Prüfe ${p} (fstype: ${_fstype:-unbekannt})..."
    if echo "${_fstype:-}" | grep -qE '^ext[234]$'; then
      if mount "$p" "$mnt" 2>/dev/null; then part="$p"; break; fi
      msg_warn "Mount von ${p} fehlgeschlagen, versuche nächste Partition..."
    fi
  done
  if [ -z "$part" ]; then
    msg_err "Konnte keine Root-Partition im Image mounten. Diagnose:"
    lsblk "$nbd_dev" 2>&1 || true
    blkid "${nbd_dev}"* 2>&1 || true
    dmesg 2>/dev/null | tail -20 || true
    umount "$mnt" 2>/dev/null || true
    qemu-nbd -d "$nbd_dev" >/dev/null 2>&1 || true
    return 1
  fi
  msg_ok "Root-Partition gemountet: ${part}"

  # 1) Root-Passwort direkt setzen (das aus der Zusammenfassung, später per 'passwd' änderbar)
  echo "root:${CONSOLE_PASSWORD}" | chpasswd --root "$mnt" \
    || { msg_err "chpasswd fehlgeschlagen"; umount "$mnt"; qemu-nbd -d "$nbd_dev" >/dev/null 2>&1; return 1; }

  # 2) SSH-Key für root hinterlegen
  mkdir -p "$mnt/root/.ssh"
  chmod 700 "$mnt/root/.ssh"
  cp "$SSH_PUBKEY_FILE" "$mnt/root/.ssh/authorized_keys"
  chmod 600 "$mnt/root/.ssh/authorized_keys"

  # 3) SSH-Hostkeys erzeugen (fixt 'Failed to start ssh.service')
  ssh-keygen -A -f "$mnt" >/dev/null 2>&1
  mkdir -p "$mnt/etc/ssh/sshd_config.d"
  printf 'PermitRootLogin prohibit-password\n' > "$mnt/etc/ssh/sshd_config.d/60-pinokio.conf"

  # 4) Netzwerk: systemd-networkd (DHCP default, statisch wenn IPCONFIG statisch ist).
  # IPCONFIG (Proxmox-Format: ip=dhcp oder ip=ADDR/PREFIX,gw=GATEWAY) wurde bisher
  # nur an 'qm create' übergeben, aber cloud-init ist deaktiviert – statische Wahl
  # kam daher nie im Gast an. Fix: direkt ins Image schreiben.
  mkdir -p "$mnt/etc/systemd/network"
  rm -f "$mnt/etc/systemd/network/89-pinokio.network"
  PINOKIO_IPCFG="${IPCONFIG:-ip=dhcp}"
  PINOKIO_STATIC_IP="$(echo "$PINOKIO_IPCFG" | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | cut -d= -f2 || true)"
  PINOKIO_GW="$(echo "$PINOKIO_IPCFG" | grep -oE 'gw=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2 || true)"
  if [ -n "$PINOKIO_STATIC_IP" ]; then
    if [ -z "$PINOKIO_GW" ]; then
      msg_warn "Statische IP ohne Gateway in IPCONFIG (${PINOKIO_IPCFG}) – schreibe Adresse ohne Default-Route."
    fi
    {
      echo "[Match]"
      echo "Name=e* en* eth*"
      echo ""
      echo "[Network]"
      echo "Address=${PINOKIO_STATIC_IP}"
      if [ -n "$PINOKIO_GW" ]; then
        echo "Gateway=${PINOKIO_GW}"
      fi
      echo "DNS=${PINOKIO_GW:-1.1.1.1}"
    } > "$mnt/etc/systemd/network/89-pinokio.network"
    msg_info "Netzwerk im Gast: statisch ${PINOKIO_STATIC_IP} gw ${PINOKIO_GW:-keins}"
  else
    cat > "$mnt/etc/systemd/network/89-pinokio.network" <<'EOF'
[Match]
Name=e* en* eth*

[Network]
DHCP=yes
EOF
    msg_info "Netzwerk im Gast: DHCP via systemd-networkd"
  fi
  # networkd robust aktivieren (merged-usr: /usr/lib, alt: /lib). systemctl --root zuerst.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --root="$mnt" enable systemd-networkd.service >/dev/null 2>&1 || true
  fi
  mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
  # WICHTIG: Target muss der GAST-absolute Pfad sein (/usr/lib/... bzw. /lib/...),
  # NICHT "$mnt/..." (Host-Mount-Pfad) – sonst hängt der Symlink im Gast in der Luft
  # und systemd-networkd startet nie (v6-Bug: genau das ist passiert).
  if [ -f "$mnt/usr/lib/systemd/system/systemd-networkd.service" ]; then
    ln -sf /usr/lib/systemd/system/systemd-networkd.service \
      "$mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true
  elif [ -f "$mnt/lib/systemd/system/systemd-networkd.service" ]; then
    ln -sf /lib/systemd/system/systemd-networkd.service \
      "$mnt/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true
  else
    msg_warn "systemd-networkd.service im Image nicht gefunden – Netzwerk könnte tot sein."
  fi
  # Alte cloud-init-Netzreste entfernen, damit kein Renderer dazwischenfunkt.
  rm -f "$mnt/etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null || true

  # 5) Hostname + cloud-init deaktivieren (damit es nichts überschreibt)
  echo "$VM_NAME" > "$mnt/etc/hostname"
  mkdir -p "$mnt/etc/cloud"
  touch "$mnt/etc/cloud/cloud-init.disabled"

  # 5b) qemu-guest-agent beim ersten Boot nachinstallieren: Cloud-Images
  # bringen ihn nicht mit, ohne ihn liefert 'qm guest cmd ... network-get-
  # interfaces' nichts und die IP-Erkennung bleibt auf ARP/Sniffing beschränkt
  # (Live-Fall: der Agent lief nie). Die Unit läuft bewusst NACH
  # multi-user.target (der Oneshot darf Boot und Anmeldung nicht blockieren)
  # und ist Best Effort: schlägt sie fehl, bleiben ARP/Sniff als Wege.
  cat > "$mnt/usr/local/sbin/pinokio-install-guest-agent.sh" <<'EOF'
#!/bin/sh
# Installiert den QEMU-Gast-Agenten nach (mehrfache Versuche, Best Effort).
# Der Agent erlaubt dem Proxmox-Host, die VM-IP sauber auszulesen
# (qm guest cmd <vmid> network-get-interfaces).
command -v qemu-ga >/dev/null 2>&1 && exit 0
export DEBIAN_FRONTEND=noninteractive
i=0
while [ "$i" -lt 10 ]; do
    if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1; then
        exit 0
    fi
    i=$((i + 1))
    sleep 15
done
exit 0
EOF
  chmod 755 "$mnt/usr/local/sbin/pinokio-install-guest-agent.sh"
  cat > "$mnt/etc/systemd/system/pinokio-install-guest-agent.service" <<'EOF'
[Unit]
Description=Pinokio: qemu-guest-agent nachinstallieren (Best Effort)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pinokio-install-guest-agent.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  # WICHTIG: Guest-absolute Zielpfade im Symlink (gleiche Falle wie bei networkd)
  mkdir -p "$mnt/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/pinokio-install-guest-agent.service \
    "$mnt/etc/systemd/system/multi-user.target.wants/pinokio-install-guest-agent.service" 2>/dev/null || true

  # 6) Hinweis auf Konsole: IP nach Login sichtbar machen
  mkdir -p "$mnt/etc/issue.d" 2>/dev/null || true
  printf '\nPinokio-VM bereit. Netzwerk: %s (systemd-networkd)\n' "${PINOKIO_STATIC_IP:-DHCP}" > "$mnt/etc/issue.d/pinokio.issue" 2>/dev/null || true

  sync
  umount "$mnt"
  qemu-nbd -d "$nbd_dev" >/dev/null 2>&1 || true
  return 0
}

if prepare_image; then
  msg_ok "Image vorbereitet: Root-Passwort gesetzt, SSH-Key + Hostkeys hinterlegt,"
  msg_ok "Netzwerk über systemd-networkd aktiviert (${IPCONFIG}), cloud-init deaktiviert."
  msg_info "Geschriebene Netzconfig: /etc/systemd/network/89-pinokio.network (im Gast prüfen mit: cat /etc/systemd/network/89-pinokio.network; networkctl status)"
else
  msg_err "Image-Vorbereitung fehlgeschlagen - breche ab (VM wurde NICHT gestartet)."
  exit 1
fi

# ----------------------------------------------------------------------------
# Schritt 6: VM starten
# ----------------------------------------------------------------------------
step 6 "VM starten"

VM_IP=""
MAC=""
STATIC_CANDIDATE=""
if [ "$START_VM" = "yes" ]; then
  qm start "$VMID"
  msg_ok "VM gestartet."

  # --------------------------------------------------------------------------
  # Schritt 7: Auf IP-Adresse warten (mehrstufig - siehe detect_vm_ip)
  # --------------------------------------------------------------------------
  step 7 "Auf IP-Adresse warten (mehrstufig)"

  # "Noch keine IP", "grep findet nichts", "Agent noch nicht da" sind hier
  # normale Zwischenergebnisse beim Warten - kein echter Fehler. set -e wird
  # deshalb für die gesamte Ermittlung deaktiviert und der ERR-Trap verstummt
  # (QUIET_ERR), damit es keinen Fehlerspam gibt.
  set +e
  QUIET_ERR=1

  MAC="$(qm config "$VMID" 2>/dev/null | grep -oE '^net0:.*' | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 || true)"
  msg_info "MAC-Adresse der VM: ${MAC:-unbekannt}"
  msg_info "Hinweis: qemu-guest-agent ist im Cloud-Image ab Werk NICHT installiert. Das"
  msg_info "Image-Setup richtet eine first-boot-Unit ein, die ihn nachinstalliert - die"
  msg_info "IP-Ermittlung läuft daher subnetz-unabhängig mehrstufig (siehe Stufen unten)."

  # Statische Wunsch-IP: bevorzugt aus der erstellten VM-Konfig (ipconfig0)
  # lesen, Fallback: IPCONFIG-ENV. Verifiziert wird sie erst in Stufe 2
  # (Ping + Port 22), nie blind übernommen.
  STATIC_CANDIDATE="$(qm config "$VMID" 2>/dev/null | awk '/^ipconfig0:/{print $2}' | grep -oE 'ip=[0-9]+(\.[0-9]+){3}' | cut -d= -f2 | head -1 || true)"
  if [ -z "$STATIC_CANDIDATE" ] && [ -n "${IPCONFIG:-}" ]; then
    STATIC_CANDIDATE="$(echo "$IPCONFIG" | grep -oE 'ip=[0-9]+(\.[0-9]+){3}' | cut -d= -f2 | head -1 || true)"
  fi
  if [ -n "$STATIC_CANDIDATE" ] && ! valid_ipv4 "$STATIC_CANDIDATE"; then
    msg_warn "Statische Kandidaten-IP '${STATIC_CANDIDATE}' ist ungültig - verworfen."
    STATIC_CANDIDATE=""
  fi

  detect_vm_ip

  set -e        # ab hier wieder normales Fehlverhalten
  QUIET_ERR=0

  if [ -n "$VM_IP" ]; then
    msg_ok "IP-Adresse gefunden: ${VM_IP}"
  else
    msg_warn "Konnte die VM-IP nach Ausschöpfen aller Stufen nicht ermitteln (Details oben in Schritt 7)."
  fi
fi

# Letztes Sicherheitsnetz: keine ungültige IP in den SSH-Wait übernehmen
# (fängt auch ARP-/Sweep-Treffer ab, falls dort je Müll durchkommt).
if [ -n "$VM_IP" ] && ! valid_ipv4 "$VM_IP"; then
  msg_err "Erkannte IP '${VM_IP}' ist ungültig – verwerfe sie (kein SSH-Versuch auf Müll)."
  VM_IP=""
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
  curl -fsSL --retry 3 --retry-delay 2 "${INSTALL_SCRIPT_URL}" -o "${TMP_INSTALL}"
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
  echo
  msg_warn "Automatische IP-Ermittlung nach allen Stufen erfolglos. Versucht wurden:"
  msg_warn "  Stufe 1: Gast-Agent + ARP/FDB passiv gepollt (${AGENT_WAIT_TIMEOUT}s)"
  msg_warn "  Stufe 2: statische Wunsch-IP ${STATIC_CANDIDATE:-nicht konfiguriert} per Ping + Port 22"
  msg_warn "  Stufe 3: ${SNIFF_ROUNDS} aktive Runden (Ping-Sweep, DHCP-Sniff, tcpdump am Tap/${BRIDGE})"
  if [ "${DIAG_NO_TRAFFIC:-0}" = "1" ]; then
    msg_warn "  Befund: Der Gast sendet KEINEN Traffic am Tap - Gast-Netzwerk vermutlich tot"
    msg_warn "          (Details in der Tiefendiagnose oben und in ${LOG_FILE})."
  else
    msg_warn "  Befund: Der Gast sendet Traffic, aber es war keine verwertbare IPv4 erkennbar."
  fi
  echo
  msg_info "Nächster Schritt: Konsole öffnen, einloggen und die IP selbst ablesen:"
  echo
  echo "    Login:    root"
  echo "    Passwort: ${CONSOLE_PASSWORD}"
  echo
  msg_warn "WICHTIG: Passwort/Keys wurden direkt ins Image geschrieben und sind ab dem"
  msg_warn "ersten Boot aktiv - kein Warten auf cloud-init nötig (cloud-init ist bewusst deaktiviert)."
  echo
  echo "  In der Konsole nach dem Login ausführen:"
  echo "    ip a                              # zeigt die IP-Adresse"
  echo "    networkctl status                 # Netzwerk-Status im Gast"
  echo "    cat /etc/systemd/network/89-pinokio.network"
  echo "    journalctl -u systemd-networkd -b # Details, wenn enp*/eth* keine IP hat"
  echo
  echo "  Konsole verlassen mit: Strg+O, dann Strg+Q"
  echo
  print_ip_failure_checklist
  echo
  open_vm_console "$VMID"
  echo
  msg_info "Sobald du die IP kennst, Pinokio auf dem Host ausrollen mit:"
  echo "    curl -fsSL ${INSTALL_SCRIPT_URL} -o /tmp/i.sh && ssh -i ${SSH_PUBKEY_FILE%.pub} root@<VM-IP> 'bash -s' < /tmp/i.sh"
  echo "    Danach erreichbar unter: http://<VM-IP>:42000"
  echo "    Später auf dem Host (Update/Status): curl -fsSL ${INSTALL_SCRIPT_URL} | ssh -i ${SSH_PUBKEY_FILE%.pub} root@<VM-IP> 'bash -s -- --update'"
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
