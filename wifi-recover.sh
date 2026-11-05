#!/usr/bin/env bash
# wifi-recover — bring BCM43602 Wi-Fi (MacBookPro13,2) back from a firmware
# hang or dead PCIe state, without rebooting.
#
# Recovery ladder (stops as soon as the interface is up):
#   1. brcmfmac driver unbind/bind        (firmware hang, e.g. PSM watchdog)
#   2. PCI remove + rescan of the card    (chip wedged: "MMIO read failed")
#   3. root-port D3cold cycle + rescan    (card not reappearing after rescan)
#
# Usage: sudo wifi-recover [-y]
#   -y  non-interactive (default asks before escalating levels 2/3)
#
# The card is found by ID (14e4:43ba), not address — it may not be at
# 02:00.0 after a Thunderbolt rescan.
set -u

ASK=1
[[ ${1:-} == -y ]] && ASK=0
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2; exit 1
fi

log() { echo "[wifi-recover] $*"; }

confirm() {  # $1 = level description
  [[ $ASK -eq 0 ]] && return 0
  read -r -p "[wifi-recover] escalate to $1? [y/N] " ans
  [[ $ans == [yY]* ]]
}

find_card() {
  local dev
  for dev in /sys/bus/pci/devices/*; do
    if [[ $(cat "$dev/vendor") == 0x14e4 && $(cat "$dev/device") == 0x43ba ]]; then
      basename "$dev"; return 0
    fi
  done
  return 1
}

iface_up() {
  local dev=$1 ifc
  ifc=$(ls /sys/bus/pci/devices/$dev/net 2>/dev/null | head -1)
  [[ -n $ifc ]] || return 1
  ip link show "$ifc" >/dev/null 2>&1 || return 1
  # an unassociated STA sits at operstate "down" - count association too,
  # so a healthy-but-still-connecting chip is not escalated needlessly
  iw dev "$ifc" link 2>/dev/null | grep -q '^Connected' && return 0
  [[ $(cat /sys/class/net/$ifc/operstate) != down ]]
}

show_state() {
  local dev=${1:-}
  log "recent wifi kernel messages:"
  dmesg | grep -iE 'brcmf|14e4:43ba' | tail -5 | sed 's/^/    /'
  [[ -z $dev ]] && return
  log "card $dev: runtime $(cat /sys/bus/pci/devices/$dev/power/runtime_status 2>/dev/null)"
}

DEV=$(find_card)

# --- Level 1: driver rebind ---------------------------------------------
if [[ -n $DEV ]] && [[ -e /sys/bus/pci/devices/$DEV/driver ]]; then
  log "level 1: rebinding brcmfmac on $DEV"
  echo "$DEV" > /sys/bus/pci/drivers/brcmfmac/unbind 2>/dev/null
  sleep 1
  echo "$DEV" > /sys/bus/pci/drivers/brcmfmac/bind 2>/dev/null
  sleep 10   # NetworkManager needs 5-15 s to re-associate after a rebind
  if iface_up "$DEV"; then
    log "OK: interface is up after rebind"
    exit 0
  fi
  log "rebind did not restore the interface"
  show_state "$DEV"
  confirm "level 2 (PCI remove/rescan of $DEV)" || exit 1
fi

# --- Level 2: PCI remove/rescan ------------------------------------------
if [[ -n $DEV ]]; then
  log "level 2: removing and rescanning $DEV"
  echo 1 > /sys/bus/pci/devices/$DEV/remove
  sleep 1
else
  log "card not present in sysfs; trying plain rescan"
fi
echo 1 > /sys/bus/pci/rescan
sleep 5
DEV=$(find_card)
if [[ -n $DEV ]] && iface_up "$DEV"; then
  log "OK: $DEV back after rescan"
  exit 0
fi
show_state "$DEV"

# --- Level 3: root-port D3cold cycle --------------------------------------
# Parent root port of the wifi card (ARPT); falls back to 0000:00:1d.3.
PORT=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$DEV" 2>/dev/null || true)")" 2>/dev/null || true)
if [[ -z $PORT || ! -e /sys/bus/pci/devices/$PORT ]]; then
  PORT=0000:00:1d.3
fi
confirm "level 3 (D3cold power cycle of root port $PORT)" || { log "aborted"; exit 1; }
log "level 3: power-cycling root port $PORT"
echo 0 > "/sys/bus/pci/devices/$PORT/d3cold_allowed" 2>/dev/null
echo 1 > "/sys/bus/pci/devices/$PORT/remove" 2>/dev/null
sleep 2
echo 1 > /sys/bus/pci/rescan
sleep 5
DEV=$(find_card)
if [[ -n $DEV ]] && iface_up "$DEV"; then
  log "OK: $DEV back after root-port power cycle"
  exit 0
fi

show_state "$DEV"
log "FAILED: card did not come back. Reboot (full power-off if a warm reboot is not enough)."
exit 2
