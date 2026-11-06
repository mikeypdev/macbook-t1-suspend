#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run with sudo: sudo $0" >&2
    exit 1
fi
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DRVSRC=${MBP_T1_DRVDIR:-/usr/src/apple-ib-drv-0.1}
DKMSSRC=/usr/src/apple-ib-drv-0.1

echo "==> 1/8 GRUB: back to real S3 (deep), drop pcie_port_pm=off"
GRUB=/etc/default/grub
cp "$GRUB" "$GRUB.bak-s3fix" 2>/dev/null || true
sed -i 's/ mem_sleep_default=s2idle//; s/ pcie_port_pm=off//' "$GRUB"
grep -q 'mem_sleep_default=deep' "$GRUB" || sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mem_sleep_default=deep"/' "$GRUB"
grep -q 'mem_sleep_default=deep' "$GRUB" && ! grep -Eq 'mem_sleep_default=s2idle|pcie_port_pm=off' "$GRUB" \
    || { echo "ERROR: failed to edit $GRUB" >&2; exit 1; }
grep '^GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB"
grub-mkconfig -o /boot/grub/grub.cfg

echo "==> 2/8 systemd sleep config: SuspendState=mem + MemorySleepMode=deep"
DROPDIR=/etc/systemd/sleep.conf.d
mkdir -p "$DROPDIR"
rm -f "$DROPDIR/90-mbp132-s2idle.conf" "$DROPDIR/90-mbp132-deep.conf.bak-suspendfix"
install -m 644 "$SRC/systemd/90-mbp132-deep.conf" "$DROPDIR/90-mbp132-deep.conf"
cat "$DROPDIR/90-mbp132-deep.conf"

echo "==> 3/8 S3 sleep hook + Thunderbolt remove/rescan + systemd-suspend drop-in"
install -m 755 "$SRC/hooks/macbook-sleep-hook" /usr/local/sbin/macbook-sleep-hook
install -m 755 "$SRC/hooks/macbook-wifi-watchdog" /usr/local/sbin/macbook-wifi-watchdog
install -m 755 "$SRC/wifi-recover.sh" /usr/local/sbin/wifi-recover
install -m 755 "$SRC/hooks/macbook-thunderbolt-remove-rescan" /usr/local/sbin/macbook-thunderbolt-remove-rescan
install -m 644 -D "$SRC/systemd/50-mbp132-s3.conf" /etc/systemd/system/systemd-suspend.service.d/50-mbp132-s3.conf
systemctl daemon-reload
echo "    installed /usr/local/sbin/macbook-sleep-hook (pre/post via systemd-suspend.service)"
echo "    installed macbook-wifi-watchdog (scheduled +45 s after every resume) + wifi-recover"

echo "==> 4/8 udev rules (NVMe d3cold, USB-C runtime) + USB-C runtime service"
install -m 644 "$SRC/systemd/61-mbp132-nvme-d3cold.rules" /etc/udev/rules.d/61-mbp132-nvme-d3cold.rules
install -m 644 "$SRC/systemd/99-mbp132-usbc-runtime.rules" /etc/udev/rules.d/99-mbp132-usbc-runtime.rules
install -m 644 "$SRC/systemd/macbook-usbc-runtime.service" /etc/systemd/system/macbook-usbc-runtime.service
systemctl daemon-reload
systemctl enable --now macbook-usbc-runtime.service
udevadm control --reload
udevadm trigger --action=change --subsystem-match=pci --attr-match=vendor=0x106b --attr-match=device=0x2003
for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/vendor") == 0x106b && $(cat "$d/device") == 0x2003 ]] || continue
    echo 0 > "$d/d3cold_allowed" 2>/dev/null || true
    echo "    NVMe ${d##*/} d3cold_allowed=$(cat "$d/d3cold_allowed")"
done

echo "==> 4b/8 NetworkManager: 802.11 power save OFF (BCM43602 PSM firmware hang)"
install -m 644 -D "$SRC/systemd/networkmanager-wifi-powersave.conf" /etc/NetworkManager/conf.d/macbook-wifi-powersave.conf
cat /etc/NetworkManager/conf.d/macbook-wifi-powersave.conf
nmcli general reload 2>/dev/null || echo "    (re-run 'nmcli general reload' once NetworkManager is up)"
echo "    replaces any older conf with wifi.powersave=2 (enable) - that one re-enabled"
echo "    power save at every resume re-probe, after TLP and the hook had turned it off"

echo "==> 5/8 Removing superseded s2idle-era hooks"
rm -f /usr/lib/systemd/system-sleep/mbp132-tbt-recover \
      /usr/lib/systemd/system-sleep/mbp132-pci-resume \
      /usr/lib/systemd/system-sleep/mbp132-pci-resume.bak-suspendfix
echo "    removed: mbp132-tbt-recover, mbp132-pci-resume (superseded by macbook-sleep-hook)"

echo "==> 6/8 DKMS: rebuild driver + new macbook_t1_socw module"
echo "    driver source: override with MBP_T1_DRVDIR=/path/to/apple-ib-drv if needed"
if [[ ! -d $DRVSRC ]]; then
    echo "ERROR: $DRVSRC missing" >&2
    echo "       set MBP_T1_DRVDIR=/path/to/apple-ib-drv and re-run" >&2
    exit 1
fi
if [[ -d "$DKMSSRC" ]] && cmp -s "$DRVSRC/apple-touchbar.c" "$DKMSSRC/apple-touchbar.c" \
   && cmp -s "$DRVSRC/apple-ibridge.c" "$DKMSSRC/apple-ibridge.c" \
   && cmp -s "$DRVSRC/macbook_t1_socw.c" "$DKMSSRC/macbook_t1_socw.c" \
   && cmp -s "$DRVSRC/Makefile" "$DKMSSRC/Makefile" \
   && cmp -s "$DRVSRC/dkms.conf" "$DKMSSRC/dkms.conf" \
   && dkms status apple-ib-drv/0.1 2>/dev/null | grep -q "$(uname -r), x86_64: installed"; then
    echo "    driver already rebuilt, skipping"
else
    [[ -d "$DKMSSRC" ]] || { echo "ERROR: $DKMSSRC missing" >&2; exit 1; }
    install -m 644 "$DRVSRC/apple-touchbar.c" "$DRVSRC/apple-ibridge.c" \
                   "$DRVSRC/apple-ibridge.h" "$DRVSRC/hid-ids.h" \
                   "$DRVSRC/macbook_t1_socw.c" "$DRVSRC/Makefile" "$DRVSRC/dkms.conf" "$DKMSSRC/"
    dkms remove apple-ib-drv/0.1 --all >/dev/null 2>&1 || true
    dkms install apple-ib-drv/0.1 -k "$(uname -r)"
fi

echo "==> 6b/8 DKMS: audio cs8409 resume fix (speakers after S3)"
if [[ -f "$SRC/cs8409-resume-fix/cirrus_apple.h" ]]; then
    if cmp -s "$SRC/cs8409-resume-fix/cirrus_apple.h" /usr/src/snd_hda_macbookpro-0.1/patch_cirrus/cirrus_apple.h 2>/dev/null \
       && modinfo snd-hda-codec-cs8409 2>/dev/null | grep -q resume_reinit; then
        echo "    cs8409 resume fix already installed, skipping"
    else
        "$SRC/cs8409-resume-fix/install-cs8409-resume-fix.sh"
    fi
else
    echo "    cs8409-resume-fix/ not present, skipping (stock audio driver)"
fi

echo "==> 7/8 Power: TLP battery profile, touchbar idle, TLP usb-denylist repair"
# Battery-mode CPU/platform tuning (EPP=power, no turbo, PCIe runtime PM)
install -m 644 "$SRC/systemd/tlp-40-battery.conf" /etc/tlp.d/40-battery.conf
# Touch bar strip sleeps 30 s after last activity (T1 USB itself can never
# runtime-suspend: gnome-shell holds the input node open)
install -m 644 "$SRC/systemd/50-mbp132-touchbar-idle.conf" /etc/modprobe.d/50-mbp132-touchbar-idle.conf
# /etc/tlp.conf is read AFTER /etc/tlp.d/*.conf by TLP 1.10: a stale
# hand-edited USB_DENYLIST there silently overrides 20-usb.conf and re-enables
# autosuspend on the pinned Alpine Ridge root hubs on every TLP run.
# 20-usb.conf owns the denylist now — comment any uncommented line out.
sed -i 's/^\(USB_DENYLIST=\)/# \1/' /etc/tlp.conf
grep -q '^USB_DENYLIST' /etc/tlp.conf && { echo "ERROR: could not neutralize USB_DENYLIST in /etc/tlp.conf" >&2; exit 1; }
echo "    USB_DENYLIST owner: $(tlp-stat -c 2>/dev/null | grep -m1 USB_DENYLIST)"
# Apply the touchbar timeout now (module param takes effect next boot)
TBATTR=$(ls /sys/devices/pci0000:00/0000:00:14.0/usb1/1-3/*/*/*/idle_timeout 2>/dev/null | head -1)
[[ -n $TBATTR ]] && echo 30 > "$TBATTR" && echo "    touchbar idle_timeout=$(cat "$TBATTR") (now + default 30 s for future boots)"
# Apply TLP battery/AC settings with the fixed configs
tlp start 2>/dev/null || true
echo "    TLP: $(tlp-stat -s 2>/dev/null | grep 'TLP profile')"

echo "==> 7b/8 Power: PCIe ASPM L1 on validated links (~-2 W awake on battery)"
# Apple firmware leaves ASPM disabled on every link it controls and never
# grants Linux _OSC ASPM control (policy writes fail EPERM), but both link
# ends advertise L1 in LnkCap - macOS enables it on the same links. setpci on
# the config bits is the only lever; matched by vendor:device id because the
# sleep-time TBT remove/rescan renumbers the TBT tree. The sleep hook
# re-applies it after every resume (links reset to firmware defaults).
install -m 755 "$SRC/hooks/macbook-pcie-aspm-l1" /usr/local/sbin/macbook-pcie-aspm-l1
install -m 644 "$SRC/systemd/macbook-pcie-aspm-l1.service" /etc/systemd/system/macbook-pcie-aspm-l1.service
systemctl daemon-reload
systemctl enable --now macbook-pcie-aspm-l1.service
/usr/local/sbin/macbook-pcie-aspm-l1

echo "==> 8/8 Verification"
echo "    mem_sleep (current boot): $(cat /sys/power/mem_sleep)  (deep only after reboot)"
echo "    socw module: $(modinfo -k "$(uname -r)" -n macbook_t1_socw 2>/dev/null || echo MISSING)"
systemd-analyze cat-config systemd/sleep.conf | grep -E 'SuspendState|MemorySleepMode' | sort -u

echo
echo "DONE. Now REBOOT (required for mem_sleep + new modules), then run:"
echo "  sudo $SRC/test/mbp132-auto-test.sh 1 180"
echo "Wake with KEYBOARD or POWER BUTTON (lid-open suspends disable LID0 wake)."
