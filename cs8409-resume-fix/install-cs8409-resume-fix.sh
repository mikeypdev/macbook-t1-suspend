#!/usr/bin/bash
# Install the CS8409 audio resume fix for MacBookPro13,2 (T1).
#
# Problem: after S3 (deep) resume the speakers stay silent. S3 removes power
# from the CS8409 codec and its CS42L83 speaker amps; the stock davidjo
# snd_hda_macbookpro driver only replays the HDA register cache on resume
# (.suspend is a no-op), it never re-runs the Apple boot setup (codec reset +
# amp/I2S programming).
#
# Fix: port of patch 0002 from github.com/rcarmo/fedora-silverblue-macbook
# (packaging/patches/0002-cs8409-apple-probe-op-and-resume-reinit.patch):
#   - PM notifier marks "system sleep started"; the first codec resume after
#     wake re-runs cs_8409_boot_setup() once and resets play/capture init.
#     Module param resume_reinit=0 disables (default on).
#   - cs_8409_apple_ops gains .probe = cs8409_probe (second probe after
#     controller rebind used to WARN and fail -EINVAL).
# Validated upstream on identical hardware: "Speakers: Works, also after S3".
#
# A REBOOT is required to load the patched module. Do NOT live rebind the HDA
# controller in a boot that has already slept: S3 resets the codec subsystem
# ID and built-in audio is lost until reboot (Fedora KNOWN-ISSUES #13).
#
# Usage: sudo ./install-cs8409-resume-fix.sh
set -euo pipefail
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TREE=/usr/src/snd_hda_macbookpro-0.1
K=$(uname -r)

[[ $EUID == 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
[[ -d $TREE ]] || { echo "ERROR: $TREE missing (DKMS package not installed)" >&2; exit 1; }
case $(cat /sys/class/dmi/id/product_name 2>/dev/null) in
    MacBookPro13,*|MacBookPro14,*) : ;;
    *) echo "WARNING: unexpected model $(cat /sys/class/dmi/id/product_name)" >&2 ;;
esac

echo "==> 1/3 Install patched cirrus_apple.h into DKMS tree"
if [[ ! -f $TREE/patch_cirrus/cirrus_apple.h.bak-resumefix ]]; then
    cp -a "$TREE/patch_cirrus/cirrus_apple.h" "$TREE/patch_cirrus/cirrus_apple.h.bak-resumefix"
    echo "    backup: cirrus_apple.h.bak-resumefix"
fi
install -m 644 "$SRC/cirrus_apple.h" "$TREE/patch_cirrus/cirrus_apple.h"
grep -q resume_reinit "$TREE/patch_cirrus/cirrus_apple.h"

echo "==> 2/3 DKMS rebuild + install (signs the module)"
if ! dkms remove snd_hda_macbookpro/0.1 --all; then
    echo "    (dkms remove: nothing to remove, continuing)"
fi
dkms install snd_hda_macbookpro/0.1 -k "$K"

echo "==> 3/3 Verify installed module"
installed=$(modinfo -n snd-hda-codec-cs8409)
echo "    module: $installed"
modinfo snd-hda-codec-cs8409 | grep -E '^(vermagic|srcversion)|^parm:.*resume_reinit' | sed 's/^/    /'
modinfo snd-hda-codec-cs8409 | grep -q 'parm:.*resume_reinit' \
    || { echo "ERROR: installed module lacks resume_reinit" >&2; exit 1; }

echo
echo "DONE. Reboot to load the patched module, then:"
echo "  1. check param: cat /sys/module/snd_hda_codec_cs8409/parameters/resume_reinit  # want Y"
echo "  2. suspend + resume (power button), then play sound - speakers should work now"
echo "  NEVER: unbind/rebind 00:1f.3 or reload snd_hda_codec_cs8409 in a boot that has slept."
