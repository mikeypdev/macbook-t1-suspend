# MacBookPro13,2 (T1) Linux suspend/resume — working setup (Arch)

Working after resume: **touchbar (display + buttons), wifi, ethernet, keyboard,
trackpad, TBT/USB-C, NVMe.** Sleep mode: real **S3 (deep)**, RTC-measured
standby. Based on the proven recipe from github.com/rcarmo/fedora-silverblue-macbook
(same machine, same kernel generation), ported to Arch.

## Root causes fixed (in causal order)

1. **s2idle leaves the T1 touch-report MCU dead** — display/commands work, input
   never returns (no USB-level or ACPI-level revival exists). Real S3 fixes it.
2. **Wifi firmware hangs across S3** — brcmfmac is unbound before sleep, rebound
   after (NVRAM/firmware files untouched; it re-probes the standard paths).
3. **TBT/USB-C dies across S3** (firmware cuts controller power; bridges come
   back with collapsed windows) — upstream ports removed cleanly before sleep,
   rescan after resume. Tree returns on the first rescan after any sleep ≥ ~60s.
4. **Instant wakes ~4s into S3** — two wake sources on this unit: ARPT (wifi
   PCIe PME; unbinding does NOT mask it) and SPIT (keyboard SPI; ghost events).
   Both masked at suspend, restored at resume.
5. **Apple S3X NVMe (106b:2003) must never enter D3cold** — machine would not
   wake. udev rule pins `d3cold_allowed=0` at boot; the hook re-checks and
   ABORTS the suspend if it cannot be set.
6. **T1 needs the host sleep/wake message** — ASOC.SOCW(0) before sleep, SOCW(1)
   first thing after wake (without SOCW(1) the bar stays dark). Sent by the
   `macbook_t1_socw` DKMS module (never evaluates anything at load;
   `apple_ibridge skip_acpi_power=1` stays REQUIRED — SOCW(1) at probe
   hard-freezes T1 Macs).
7. **Driver regression during the s2idle era** — apple-touchbar's `reset_work`
   (extra `usb_reset_device` after resume) wedged the touch MCU after S3.
   Driver is now the Fedora-proven minimal version: `.resume`/`.reset_resume` =
   reset-resume that INVALIDATES the cached mode (stale cache = dark bar).
   Backup of the s2idle-era file: `apple-touchbar.c.bak-s2idle-hacks`.
8. **Intermittent S3 instant-wake chain (platform quirk, also on the reference
   machine, first trigger never attributed)** — occasionally something wakes
   S3 ~3-4 s after entry (gpe6D group = PWRB/XHC1/HDEF fires; no OS-visible
   wake source, lid state irrelevant). Any sleep <60 s leaves the TBT tree
   dead, and while it is dead further sleeps keep instant-waking; the chain
   clears once one sleep holds ≥60 s (reference: Fedora SLEEP.md 14:05-14:10,
   KNOWN-ISSUES "self-heals via logind re-suspend"). Their machine re-suspends
   while the lid stays closed; this one (on AC) stayed awake with a dead TB
   tree, which also looked like "wifi eventually died". Fix: the hook
   re-suspends automatically (bounded 5x) when it wakes <20 s with the lid
   closed. The hook also idles the CS8409 codec before the suspend sequence
   (profile off + autosuspend 0) as hardening, since an active-codec power-down
   inside the suspend path coincided with early wakes on 2026-11-03.

## Install

Requires: Arch Linux, GRUB, DKMS, the `apple-ib-drv` T1 driver source (path
overridable via `MBP_T1_DRVDIR=...`, default `/usr/src/apple-ib-drv-0.1`), and
the `snd_hda_macbookpro` DKMS package (`/usr/src/snd_hda_macbookpro-0.1`) for
the audio fix. Secure Boot must be off (or set up DKMS module signing).

    sudo ./apply-suspend-fix.sh

Reboot, then run the automated test:

    sudo ./test/mbp132-auto-test.sh 1 180

Machine sleeps ~3 min, wakes itself by RTC (screen stays black — one keypress
lights it), then check `logs/latest` + tap the bar. Held duration must equal
the requested seconds; EARLY WAKE lines indicate a new wake source.

## Files

| File | Installs to | Role |
|---|---|---|
| `apply-suspend-fix.sh` | — | installer: GRUB `mem_sleep_default=deep` (no pcie_port_pm), sleep.conf, hooks, udev rules, DKMS rebuild |
| `hooks/macbook-sleep-hook` | /usr/local/sbin | pre: force deep, NVMe guard, wifi unbind, CS8409 codec idle (profile off + autosuspend 0), TBT removal, XHC1/ARPT/SPIT/LID0(if lid open) wake masks, SOCW(0). post: SOCW(1), TBT rescan, wifi rebind, wake restores, codec profile restore, touchbar mode re-send (idle_timeout -2 → saved) |
| `hooks/macbook-thunderbolt-remove-rescan` | /usr/local/sbin | TBT upstream-port removal before sleep + rescan/retries after (journal tag: thunderbolt-remove-rescan) |
| `systemd/90-mbp132-deep.conf` | /etc/systemd/sleep.conf.d | SuspendState=mem, MemorySleepMode=deep |
| `systemd/50-mbp132-s3.conf` | systemd-suspend.service.d | ExecStartPre/ExecStopPost = the hook |
| `systemd/61-mbp132-nvme-d3cold.rules` | /etc/udev/rules.d | NVMe d3cold_allowed=0 |
| `systemd/99-mbp132-usbc-runtime.rules` + `systemd/macbook-usbc-runtime.service` | udev/systemd | keep Alpine Ridge USB3 root hubs runtime-awake (USB-C hotplug detection) |
| `test/mbp132-auto-test.sh` | — | unattended S3 test: RTC self-wake, wake-source capture, GPE deltas, T1/TBT/wifi verdicts → `logs/latest` |
| apple-ib-drv (external, `MBP_T1_DRVDIR`) | DKMS apple-ib-drv/0.1 | apple-ibridge + apple-touchbar + macbook_t1_socw |
| `cs8409-resume-fix/` | /usr/src/snd_hda_macbookpro-0.1 (patch_cirrus/) | CS8409 audio resume fix: re-runs Apple boot setup after S3 (port of Fedora patch 0002; param `resume_reinit`) |
| `firmware/brcmfmac43602-pcie.txt` | /lib/firmware/brcm/ | Broadcom BCM43602 NVRAM (macaddr zeroed — the driver uses the real MAC anyway) |

## Known limitations

- **Keyboard cannot wake from suspend** (SPIT masked — ghost events woke it in
  ~4s). Wake with power button (short-press when awake = GNOME suspend menu
  action) or lid. Lid-open suspends also disable LID0 wake (GPE 0x6F fires
  immediately otherwise).
- Audio: CS8409 DKMS driver (`snd_hda_macbookpro`) with the resume fix —
  speakers work, also after S3. Installed by `cs8409-resume-fix/`
  (module param `resume_reinit`, default on). NEVER unbind/rebind 00:1f.3 or
  reload `snd_hda_codec_cs8409` in a boot that has already slept: S3 resets the
  codec subsystem ID and built-in audio is lost until reboot. Also never play
  to `hw:0,0`/`plughw:0,0` — no hardware volume control (VERY loud).
- gsettings `caps:escape` (interim ESC workaround) can be reset now:
  `gsettings reset org.gnome.desktop.input-sources xkb-options`.
