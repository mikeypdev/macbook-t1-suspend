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
9. **Wi-Fi dead after resume despite clean re-enumeration (2026-11-05 12:45)** —
   two stacked causes. (a) NetworkManager re-applies its `wifi.powersave`
   setting every time it initializes a wifi device — i.e. every resume, when
   the hook's PCI rescan re-creates the card as a new phy, one second AFTER
   the hook turned power save off; TLP cannot counter (its resume hook runs
   while the card is still removed, and `tlp-pd` only serves GNOME's profile
   slider). A stale pre-kit NM conf had `wifi.powersave=2` (enable), so every
   resume rolled the dice on the documented PSM firmware hang. (b) Even with
   fresh firmware the chip sometimes comes up wedged: assoc rejects
   (status 16) + EAPOL timeouts; only a reboot recovered it. Fix: NM conf
   pins `wifi.powersave=1` (disable) + a watchdog 45 s after every resume
   (`macbook-wifi-watchdog`) that enforces power_save off, rebinds brcmfmac
   if nothing associated, then escalates through `wifi-recover` (PCI
   remove/rescan → ARPT root-port D3cold cycle).
10. **Wi-Fi watchdog raced the resume and wedged a healthy chip (2026-11-09
    20:47)** - three stacked bugs, all fixable without a reboot next time.
    Sequence: lid closed 20:34, the instant-wake chain re-suspended the box
    (issue 8) at 20:39:06 with the card PCI-removed; AC plugged in mid-sleep
    (did NOT wake it - lid open at 20:47:22 did, gpe6F). (a) A watchdog
    timer still pending from the resume before that re-suspend fired 0 s
    into the thaw (`--on-active` deadlines stay pending across the sleep)
    and saw "no wifi interface" while the card was deliberately removed.
    (b) Its `wifi-recover` level-2 rescan brought the card back healthy,
    but the flat 5 s association wait was shorter than NetworkManager's
    5-15+ s bring-up, so it escalated to the level-3 ARPT root-port D3cold
    cycle on a chip rescued 5 s earlier - and that double power cycle
    wedged the firmware (assoc rejects status 16 + EAPOL timeouts, same
    signature as 9b; reboot was the only way out). (c) The post hook's
    attempt to schedule a watchdog for THIS resume failed ("unit already
    loaded" - transient units linger until GC), so nothing self-healed.
    Fixes: pre hook cancels pending watchdog timer+service at every suspend
    entry; post hook unloads leftovers before rescheduling (idempotent);
    the watchdog waits out the post-hook recovery before judging;
    `wifi-recover` waits up to 25 s for association after every level and
    prefers a driver rebind over the root-port power cycle while the card
    is on the bus.

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
| `hooks/macbook-sleep-hook` | /usr/local/sbin | pre: force deep, NVMe guard, wifi PCI remove (rebind alone wedges the chip), CS8409 codec idle (profile off + autosuspend 0), TBT removal, XHC1/ARPT/SPIT/LID0(if lid open) wake masks, SOCW(0). post: SOCW(1), TBT rescan, wifi rescan + bind + power_save off, wake restores, codec profile restore, touchbar mode re-send (idle_timeout -2 → saved) |
| `hooks/macbook-thunderbolt-remove-rescan` | /usr/local/sbin | TBT upstream-port removal before sleep + rescan/retries after (journal tag: thunderbolt-remove-rescan) |
| `hooks/macbook-wifi-watchdog` | /usr/local/sbin | +45 s after every resume: enforce 802.11 power_save off (NM re-enables it on the re-probed device), rebind brcmfmac if nothing associated, then wifi-recover ladder; waits out the post-hook recovery before judging (journal tag: macbook-sleep "watchdog:") |
| `systemd/90-mbp132-deep.conf` | /etc/systemd/sleep.conf.d | SuspendState=mem, MemorySleepMode=deep |
| `systemd/50-mbp132-s3.conf` | systemd-suspend.service.d | ExecStartPre/ExecStopPost = the hook |
| `systemd/61-mbp132-nvme-d3cold.rules` | /etc/udev/rules.d | NVMe d3cold_allowed=0 |
| `systemd/99-mbp132-usbc-runtime.rules` + `systemd/macbook-usbc-runtime.service` | udev/systemd | keep Alpine Ridge USB3 root hubs runtime-awake (USB-C hotplug detection) |
| `hooks/macbook-pcie-aspm-l1` + `systemd/macbook-pcie-aspm-l1.service` | /usr/local/sbin + systemd | enable PCIe ASPM L1 (LnkCtl bit 1) on validated links at boot, re-applied after every resume by the sleep hook: Apple firmware ships ASPM disabled and never grants Linux _OSC control (policy write = EPERM) even though both link ends advertise L1 (macOS enables it). Measured −2.2 W awake on battery (journal tag: macbook-aspm) |
| `wifi-recover` | /usr/local/sbin | Wi-Fi recovery ladder: brcmfmac rebind → PCI remove/rescan → ARPT root-port D3cold cycle, with up to 25 s association wait per level (NM needs 5-15+ s on a freshly probed device) and a rebind preferred over power cycling while the card is on the bus; manual `sudo wifi-recover [-y]`, also driven automatically by the watchdog |
| `test/mbp132-auto-test.sh` | — | unattended S3 test: RTC self-wake, wake-source capture, GPE deltas, T1/TBT/wifi verdicts → `logs/latest` |
| apple-ib-drv (external, `MBP_T1_DRVDIR`) | DKMS apple-ib-drv/0.1 | apple-ibridge + apple-touchbar + macbook_t1_socw |
| `cs8409-resume-fix/` | /usr/src/snd_hda_macbookpro-0.1 (patch_cirrus/) | CS8409 audio resume fix: re-runs Apple boot setup after S3 (port of Fedora patch 0002; param `resume_reinit`) |
| `systemd/tlp-20-usb.conf` | /etc/tlp.d/20-usb.conf | TLP: USB autosuspend denylist by USB id (1d6b:0003 root hubs) so Alpine Ridge USB-C hotplug stays working (PCI id in stock config matched nothing) |
| `systemd/tlp-40-battery.conf` | /etc/tlp.d/40-battery.conf | TLP: battery-mode CPU tuning — EPP `power`, turbo off, PCIe runtime PM (idle draw was ~3x macOS) |
| `systemd/50-mbp132-touchbar-idle.conf` | /etc/modprobe.d/50-mbp132-touchbar-idle.conf | apple_touchbar `idle_timeout=30`: strip display sleeps 30 s after last activity (T1 USB itself can never runtime-suspend — gnome-shell holds the input node open) |
| `apple-ib-t1-idle-off.patch` | /usr/src/apple-ib-drv-0.1 (apple-touchbar.c) | T1 driver fix: idle timeout now blanks the strip via MODE_SET (display ops are a no-op on T1, so the stock idle logic never actually turned it off); input restores the fn mode |
| `systemd/tlp-30-wifi.conf` | /etc/tlp.d/30-wifi.conf | TLP: disable 802.11 power save (BCM43602 PSM watchdog firmware hang); boot-time only — the NM conf below covers the resume re-probe |
| `systemd/networkmanager-wifi-powersave.conf` | /etc/NetworkManager/conf.d/macbook-wifi-powersave.conf | NetworkManager: wifi.powersave=1 — NM re-applies its setting at every wifi device init (i.e. every resume re-probe), after TLP already ran; without this, power save comes back on at each resume |
| `firmware/brcmfmac43602-pcie.txt` | /lib/firmware/brcm/ | Broadcom BCM43602 NVRAM (macaddr zeroed — the driver uses the real MAC anyway) |

## Power / battery (2026-11-06 audit)

Measured on battery with a GNOME session: **~11-15 W draw, CPU package only
~2.7 W of it**; package idled at PC3 (never PC6+); macOS idles this machine
at <5 W. The gap is not the CPU governor — it is a set of always-on devices
plus two ACPI GPE storms. What was found and done:

| Finding | Action |
|---|---|
| `/etc/tlp.conf:500` had a stale hand-edited `USB_DENYLIST="8086:15d4"`; TLP 1.10 reads tlp.conf AFTER tlp.d, so it silently overrode `20-usb.conf` on every TLP run → Alpine Ridge root hubs back to `auto` (the USB-C hotplug fix was defeated) | installer step 7/8 comments the line out; 20-usb.conf owns the denylist |
| Battery profile used stock TLP defaults (EPP `balance_power`, turbo on) | `tlp-40-battery.conf`: EPP `power`, `CPU_BOOST_ON_BAT=0`, `RUNTIME_PM_ON_BAT=auto` |
| Touch bar strip stayed lit forever: idle timeouts called `appletb_set_tb_disp()`, which is a **deliberate no-op on T1** ("no separate display-control interface") — the driver believed it blanked the strip. Input events were quiet (verified: no ghost-event stream), so it wasn't chatter keeping it awake; the T1 (iBridge `05ac:8600`) USB also never runtime-suspends (gnome-shell holds the input node open) | `apple-ib-t1-idle-off.patch`: idle timeout now sends `MODE_OFF` via the mode-set path (same command suspend uses); next input restores the fn mode. T1 USB suspend itself would need libinput ignoring the device (kills Fn-row keys) or SOCW experiments (known T1 freeze territory) — not attempted |
| `gpe07` storm, ~10-35/s on battery. gpe07 is the **EC (PNP0C09) GPE**; its queries carry lid (`_Q20`), AC-adapter (`_Q21`), battery (`_Q10`), sleep-button (`_Q5A`) events | NOT disabled — would break lid close/open and AC plug detection. Rate correlates with battery discharge (SMC telemetry). Cost is modest; wakeups show as `acpi_ec_event_processor`. **Measured the hard way (2026-11-06): `echo disable > gpe07` causes a ~2500/s SCI storm (level-triggered, stuck-asserted), and after a disable+resume cycle the EC path degrades — SMC reads take ~270 ms instead of ~5 ms, upowerd/gnome-shell chug, ~35% phantom PSI io pressure. Re-enabling stops the storm; full recovery needed a reboot. Never disable these two.** |
| `gpe17` storm, intermittent bursts ~75/s. gpe17 is **SPIT (apple-spi-topcase) GPE** = the keyboard/touchpad data interrupt (applespi installs a GPE handler) — same ghost-event hardware quirk as the known S3 SPIT instant-wake | NOT disabled — would kill keyboard+trackpad input |
| Apple S3X NVMe: **APST unsupported** (`get-feature 0x0c` = Invalid Field) — the `nvme_core.default_ps_max_latency_us` advice floating around is useless here (0 would *disable* APST anyway); drive stays 100% runtime-active | none possible; d3cold already forbidden (wake bug), D3hot runtime is enabled by default but the drive never idles long enough |
| BCM43602 wifi always active, 802.11 PSM off | deliberate (PSM firmware hang, see 30-wifi.conf) — ~0.5-1 W inherent cost |
| Every PCIe link ran with ASPM disabled. The earlier "TBT has no ASPM in LnkCap" reading was wrong — both ends of the NVMe/wifi/TBT links advertise L1; Apple firmware just never enables it and never grants Linux _OSC ASPM control (`policy` write = EPERM, `pcie_aspm.policy=powersave` is a no-op) | `macbook-pcie-aspm-l1` (boot + every resume): setpci LnkCtl L1 on 10 vendor:device ids. Measured: −1.4 W TBT chains, −0.6 W wifi link (NVMe link already L1 from firmware); busy-session draw 10.5 → 8.3 W |
| Both Alpine Ridge TBT controllers 100% runtime-active with `control=auto` (first audit, pre-ASPM-L1) | with L1 + runtime PM as shipped, the four empty hotplug bridges (`04:01/04:04`/`7a:01/7a:04`) do runtime-suspend; NHIs and the pinned xHCIs stay awake. `thunderbolt.xdomain=N` was A/B-tested (two clean back-to-back boots: 9.46 W without vs 9.64 W with — no measurable win, and bridge behavior identical) so it is NOT adopted; S3 sleep test passed while it was set, for the record. Letting the TBT xHCIs themselves runtime-suspend (root hubs unpinned) added only ~0.2 W in earlier testing — the pinned-hubs hotplug tradeoff stays. USB2 hotplug is unaffected either way (internal xHCI); USB3 path still untestable (no USB3 C-C cable) |
| GNOME auto-brightness on → iio-sensor-proxy polls 2 ALS → HID sensor device never powers down | left as-is (user feature); turn off auto-brightness to power-gate it |
| syncthing (~25 wakeups/s over 5 procs), 1Password, terminals | userspace; biggest wakeup source after this session itself |

Result after both passes (2026-11-06): **busy-session draw on battery 8.3 W**
(10.5 W before ASPM L1, 12.8 W after the first pass; see intro for the
starting range; macOS idles <5 W with everything closed). The NHIs behind
both TBT controllers still never runtime-suspend even with everything idle
(module params `xdomain`/`clx` are read-only 0444); `thunderbolt.xdomain=N`
was A/B-tested and showed no measurable draw change — not adopted.

### Session-3 deep dive: where the remaining watts sit (2026-11-06)

Clean-boot re-measurement with the fixes in place (awake, battery, GNOME,
interactive: ~11.3 W quiet / ~13.9 W active; the crush session itself is
~1.5-2 W of that). Decomposition of the rest:

- **Panel backlight** (`acpi_video0`): 15→38 (of 90) = +0.35 W, 38→60 =
  +1.9 W, 60→90 = +0.6 W. Full range ~2.8 W. Dropping one notch below 38
  is nearly free; 38→60 is the expensive step.
- **Keyboard backlight** (`spi::kbd_backlight`, via T1): 0→72/255 =
  **+0.6 W**. No auto-dim while awake, but it does turn off automatically
  when the screen blanks (GNOME/gsd), so it costs nothing in the blank
  state; `echo 0` into the sysfs file when unused while working.
- **Display pipeline floor**: eDP panel has no PSR (DPCD 1.1, debugfs
  `i915_edp_psr_status` = ENODEV) and display DC5/DC6 was entered 3 times
  total since boot — the display engine refreshes from memory every frame,
  always. Unfixable without a PSR-capable panel/link.
- **Package C-states never reach PC8+ — even with the screen blank.**
  Screen-on: PC2 7.5%, PC3 3.6%, PC6 7.2%, PC7 1.1%, PC8+ 0.0% (while
  cores individually hit C7/C8 and the GPU sat in RC6 at 300 MHz with
  0 IRQ/s). During a 20-min blank the picture improved (PC6 25.6%, GPU
  powered-on 26%→9%) but PC8/9/10 stayed 0.0% — so the deep package states
  are gated by the never-suspending TBT NHIs, the ~70/s EC/GPE traffic and
  the PSM-off wifi, *not* by the display (later verified: with
  `thunderbolt.xdomain=N` the NHIs still never suspend and PC8+ stays
  0.0%). The structural gap to macOS' <5 W idle has no remaining
  Linux-side lever found. Blank itself is still the single biggest awake
  lever: **13.5 W active → 5.4 W** blanked on battery.
- **Phantom iowait is EC latency, not storage**: ~35% PSI io pressure and
  20-30% `top` wa with *zero* block IO on every boot measured. The
  blocked tasks are EC/SPI work (`spi2`, `kec_query`, `upowerd`,
  `kworker i915_flip` briefly). Cosmetic for power, but explains odd
  load/pressure readings — don't chase it.
- **A long-lived boot accumulates GPU interrupt load that a reboot
  clears**: after ~24 h up + a sleep cycle, i915 fired 228/s with a fully
  static screen (680/s active) and powertop showed leaked DRM clients;
  after reboot the same static desktop is 0/s. If i915 dominates
  `/proc/interrupts` on a quiet screen, reboot.


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
- PCIe ASPM L1 is applied by setpci (`macbook-pcie-aspm-l1`) because firmware
  never grants Linux _OSC ASPM control. If a firmware/kernel update ever
  starts granting it (`policy` write stops returning EPERM), prefer native
  `pcie_aspm.policy=powersave` and drop the unit.
