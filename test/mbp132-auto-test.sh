#!/bin/bash
# Unattended MacBookPro13,2 S3 suspend test with automatic RTC wake.
#   sudo ~/src/macbook-linux/mbp132-auto-test.sh [cycles=1] [seconds=180] [nowake=SPIT,...]
# No keypresses needed: RTC wakes the machine; the systemd suspend path
# (macbook-sleep-hook) runs normally. nowake= disables extra wake sources for
# the test only: /proc/acpi/wakeup names (e.g. SPIT), gpeXX (disables that GPE
# via /sys/firmware/acpi/interrupts, e.g. gpe07), or "nohda" (unbinds the HDA
# audio controller 00:1f.3 - audio lost until rebind; if a sleep happened the
# rebind may fail and audio needs a reboot). Full log -> logs/auto-<time>.log
# (symlinked logs/latest). HANDS OFF the whole time - it wakes itself.
set -u
CYCLES=${1:-1}
SECS=${2:-180}
NOWAKE=${3:-}
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOGDIR=$SRC/logs
OUT=$LOGDIR/auto-$(date +%Y%m%d-%H%M%S).log
fail() { echo "REFUSED: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail "run with sudo"
[[ $CYCLES =~ ^[0-9]+$ ]] && (( CYCLES >= 1 && CYCLES <= 10 )) || fail "cycles 1..10"
[[ $SECS =~ ^[0-9]+$ ]] && (( SECS >= 60 && SECS <= 1800 )) || fail "seconds 60..1800"
[[ $(cat /sys/class/dmi/id/product_name) == MacBookPro13,2 ]] || fail "model"
[[ -x $SRC/hooks/macbook-sleep-hook && -x $SRC/hooks/macbook-thunderbolt-remove-rescan ]] || fail "sources missing"
install -m 755 "$SRC/hooks/macbook-sleep-hook" /usr/local/sbin/macbook-sleep-hook
install -m 755 "$SRC/hooks/macbook-thunderbolt-remove-rescan" /usr/local/sbin/macbook-thunderbolt-remove-rescan
[[ -e /sys/bus/usb/devices/1-3/product ]] || fail "iBridge (usb 1-3) missing - reboot first"
AC=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null || echo 0)
BAT=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo 0)
if (( AC != 1 )); then (( BAT >= 30 )) || fail "battery ${BAT}% < 30% - plug in the charger"; fi
for d in /sys/bus/usb/devices/*; do
    [[ -e $d/idVendor && ${d##*/} != usb* && ${d##*/} != *:* ]] || continue
    p=$(readlink -f "$d")
    [[ $p == */0000:00:14.0/* ]] || fail "USB device ${d##*/} on a USB-C controller - unplug it"
done
mkdir -p "$LOGDIR"; chmod 777 "$LOGDIR" 2>/dev/null
touch "$OUT"; ln -sfn "$(basename "$OUT")" "$LOGDIR/latest"
exec > >(tee -a "$OUT") 2>&1
echo "=== auto S3 test: $CYCLES cycle(s) x ${SECS}s, nowake='$NOWAKE', $(date) ==="
echo "power: $( (( AC == 1)) && echo AC || echo battery ) ${BAT}%"
systemd-inhibit --what=sleep sleep infinity & INHIBIT_PID=$!
trap 'kill $INHIBIT_PID 2>/dev/null' EXIT
xhci() { ls /sys/bus/pci/drivers/xhci_hcd 2>/dev/null | grep -c '^0000'; }
tbinst() { ls -d /sys/bus/hid/devices/0003:1D6B:0301.* 2>/dev/null | tail -1; }
gpes() { for g in /sys/firmware/acpi/interrupts/gpe*; do v=$(cat "$g" 2>/dev/null); [[ ${v%% *} == 0 ]] || echo "  ${g##*/}: $v"; done; }
ts() { journalctl -k -o short-precise --since "$1" --no-pager | grep "$2" | tail -1 | awk '{print $1" "$2}'; }
devwake() { awk -v d="$1" '$1==d {print ($3 ~ /enabled/) ? "enabled" : "disabled"}' /proc/acpi/wakeup; }
wifi_wait() { for i in $(seq 1 8); do [[ $(cat /sys/class/net/wlp2s0/operstate 2>/dev/null) == up ]] && return 0; sleep 5; done; return 1; }
RESTORE_WAKE=(); RESTORE_GPE=(); NOHDA=0
for w in ${NOWAKE//,/ }; do
    [[ -n $w ]] || continue
    case $w in
    gpe[0-9A-Fa-f]*)
        G=/sys/firmware/acpi/interrupts/$w
        [[ -e $G ]] || fail "unknown GPE: $w"
        echo disable > "$G" 2>/dev/null || fail "cannot disable $w"
        RESTORE_GPE+=("$w"); echo "test-only: $w -> disabled" ;;
    nohda)
        [[ -e /sys/bus/pci/drivers/snd_hda_intel/0000:00:1f.3 ]] || fail "snd_hda_intel not bound"
        echo 0000:00:1f.3 > /sys/bus/pci/drivers/snd_hda_intel/unbind
        NOHDA=1; echo "test-only: snd_hda_intel unbound (00:1f.3, HDA out of the picture)" ;;
    *)
        [[ $(devwake "$w") == enabled ]] && { echo "$w" > /proc/acpi/wakeup; RESTORE_WAKE+=("$w"); }
        echo "test-only: $w wake -> $(devwake "$w")" ;;
    esac
done

for c in $(seq 1 "$CYCLES"); do
    echo; echo "########## CYCLE $c/$CYCLES ##########"
    DEV_PRE=$(cat /sys/bus/usb/devices/1-3/devnum 2>/dev/null)
    INST_PRE=$(tbinst); XHCI_PRE=$(xhci)
    echo "pre : mem_sleep=$(cat /sys/power/mem_sleep) xhci=$XHCI_PRE tb_devnum=$DEV_PRE tb_inst=${INST_PRE##*/}"
    echo "pre : nonzero GPEs:"; gpes
    START=$(date '+%Y-%m-%d %H:%M:%S'); T0=$(date +%s)
    echo 1 > /sys/power/pm_print_times 2>/dev/null
    rtcwake -m no -s "$SECS" || fail "rtcwake failed"
    sync
    echo "suspending $(date +%T); RTC wake in ${SECS}s - HANDS OFF"
    systemctl suspend --ignore-inhibitors
    for i in $(seq 1 $((SECS + 600))); do
        journalctl -k --since "$START" --no-pager 2>/dev/null | grep -q 'PM: suspend exit' && break
        sleep 1
    done
    echo 0 > /sys/power/pm_print_times 2>/dev/null
    echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
    sleep 20   # hook post + TBT retries + wifi rebind settle
    T1=$(date +%s)

    echo "--- all suspend entries/exits since $START ---"
    journalctl -k --since "$START" --no-pager | grep -E 'PM: suspend (entry|exit)' | grep -v 'Modules linked'
    E=$(date -d "$(ts "$START" 'suspend entry')" +%s 2>/dev/null)
    X=$(date -d "$(ts "$START" 'suspend exit')" +%s 2>/dev/null)
    HELD=$(( ${X:-0} - ${E:-0} )); WALL=$(( T1 - T0 ))
    echo "RESULT: held=${HELD}s of ${SECS}s wanted, round-trip=${WALL}s"
    if (( HELD < SECS - 10 )); then echo "RESULT: *** EARLY WAKE - see wake-source lines below ***"; fi
    echo "post: pm_wakeup_irq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null)"
    echo "post: active_wakeup_source=$(head -1 /sys/kernel/debug/wakeup_sources 2>/dev/null || echo 'n/a (debugfs)')"
    echo "post: wakeup_sources with events: $(awk 'NR>1 && ($3>0 || $4>0 || $10>0) {printf "%s(ev=%s,ws=%s,prevent=%s) ", $1, $3, $4, $10}' /sys/kernel/debug/wakeup_sources 2>/dev/null)"
    echo "post: acpi wake enabled: $(awk '$3 ~ /enabled/ {printf "%s(%s) ", $1, $2}' /proc/acpi/wakeup)"
    echo "post: nonzero GPEs:"; gpes
    echo "--- hook (incl. GPE/wakeup capture) ---"
    journalctl --since "$START" --no-pager -t macbook-sleep 2>/dev/null | tail -30
    echo "--- usb 1-3 (T1) ---"
    journalctl -k --since "$START" --no-pager | grep -E 'usb 1-3|reset_resume' | grep -v 'Modules linked' | tail -12
    if journalctl -k --since "$START" --no-pager | grep -q 'usb 1-3: new high-speed USB device'; then
        echo "RESULT: T1 RE-ENUMERATED (power was truly cut - input should be alive)"
    else
        echo "RESULT: T1 stayed on the bus (no re-enumeration)"
    fi
    echo "--- touchbar driver ---"
    journalctl -k --since "$START" --no-pager | grep -E 'Touchbar' | tail -6
    echo "--- TBT/USB-C ---"
    journalctl --since "$START" --no-pager -t thunderbolt-remove-rescan 2>/dev/null | tail -8
    echo "xhci now: $(xhci) (was $XHCI_PRE; want 3)"
    echo "--- wifi ---"
    if wifi_wait; then echo "WIFI: UP after resume"; else echo "WIFI: DOWN"; fi
    nmcli -t -f DEVICE,STATE device status 2>/dev/null | head -4
    echo "post: tb_devnum=$(cat /sys/bus/usb/devices/1-3/devnum 2>/dev/null) tb_inst=$(tbinst)"
done

for w in "${RESTORE_WAKE[@]}"; do
    [[ -n $w ]] || continue
    [[ $(devwake "$w") == disabled ]] && echo "$w" > /proc/acpi/wakeup
    echo "$w wake restored: $(devwake "$w")"
done
for g in "${RESTORE_GPE[@]}"; do
    [[ -n $g ]] || continue
    echo enable > "/sys/firmware/acpi/interrupts/$g" 2>/dev/null \
        && echo "$g -> enabled" || echo "WARNING: could not re-enable $g"
done
if (( NOHDA )); then
    echo 0000:00:1f.3 > /sys/bus/pci/drivers/snd_hda_intel/bind 2>/dev/null \
        && echo "snd_hda_intel rebound (00:1f.3)" \
        || echo "WARNING: 00:1f.3 rebind failed - audio needs a REBOOT (post-S3 codec subsystem ID reset)"
fi
echo; echo "=== ALL CYCLES DONE ($(date)) ==="
echo "FINAL CHECK (human): tap the touchbar - ESC and volume/brightness must act."
echo "Log: $OUT"
