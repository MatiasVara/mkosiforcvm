#!/bin/bash
# Runs once after systemd-repart creates the encrypted root partition.
# Removes root= from GRUB so the next boot uses systemd-gpt-auto-generator
# for automatic partition discovery, then reboots.
#
# Token registration is handled by the patched systemd-repart (EncryptAddToken=kbs).
# Initrd is already built with dracut at image build time (see build.sh).

set -euo pipefail

log() {
    echo "post-repart: $*"
    echo "post-repart: $*" > /dev/console 2>/dev/null || true
}

if ! grep -q 'root=UUID=\|root=LABEL=' /proc/cmdline; then
    log "root= not in cmdline — already configured. Nothing to do."
    exit 0
fi

log "Removing root= from GRUB config for auto-discovery..."
BOOT_PART=$(blkid -t LABEL="boot" -o device 2>/dev/null || true)
if [ -z "$BOOT_PART" ]; then
    BOOT_PART=$(blkid -t TYPE="xfs" -o device 2>/dev/null | head -1)
fi
if [ -z "$BOOT_PART" ]; then
    log "ERROR: Cannot find boot partition"
    exit 1
fi
mkdir -p /tmp/bootmnt
mount "$BOOT_PART" /tmp/bootmnt
sed -i 's|root=UUID=[^ ]*||g; s|root=LABEL=[^ ]*||g' /tmp/bootmnt/loader/entries/*.conf 2>/dev/null || true
sed -i 's|root=UUID=[^ ]*||g; s|root=LABEL=[^ ]*||g' /tmp/bootmnt/grub2/grubenv 2>/dev/null || true
umount /tmp/bootmnt

log "=== Post-repart configuration complete. Rebooting... ==="
reboot
