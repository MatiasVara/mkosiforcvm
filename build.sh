#!/bin/bash
# Build the self-encrypting CVM image with mkosi and package it as a containerDisk.
#
# Prerequisites:
#   - mkosi >= v26 installed: dnf install mkosi
#   - podman installed: dnf install podman
#   - qemu-img installed: dnf install qemu-img
#   - Custom systemd-repart (standalone) with EncryptAddToken= support, built from
#     upstream systemd main (post-262). Place at mkosi.extra/usr/bin/systemd-repart.
#     Build: git clone --depth=1 https://github.com/systemd/systemd.git && cd systemd
#            meson setup build -Drepart=enabled -Dblkid=enabled -Dfdisk=enabled \
#              -Dopenssl=enabled -Dlibcryptsetup=enabled -Dmode=release \
#              -Dstandalone-binaries=true && ninja -C build systemd-repart.standalone
#   - Custom trustee-attester with TDX + kbs+provisioner:// URI support, built from
#     upstream guest-components main. Place at mkosi.extra/usr/bin/trustee-attester.
#     Build: git clone --depth=1 https://github.com/confidential-containers/guest-components.git
#            cd guest-components && cargo build --release --bin trustee-attester \
#              --features "bin,tdx-attester,background_check" --no-default-features \
#              -p kbs_protocol
#
# Usage:
#   ./build.sh
#
# Output:
#   - cvm-selfencrypt.raw   (GPT disk image)
#   - cvm-image.qcow2       (converted for VM use)
#   - Container image (for KubeVirt containerDisk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="quay.io"
IMAGE_REPO="mvaralar/cvm-selfencrypt"
IMAGE_TAG="latest"

# ── 1. Build the image with mkosi (needs root) ──
echo "=== Building CVM image with mkosi ==="
cd "$SCRIPT_DIR"
sudo mkosi --force build

echo ""
echo "=== mkosi build complete ==="

# ── 2. Fix ownership (mkosi runs as root) ──
RAW_IMAGE="$SCRIPT_DIR/cvm-selfencrypt.raw"
sudo chown "$(id -u):$(id -g)" "$SCRIPT_DIR"/cvm-selfencrypt.* "$SCRIPT_DIR"/cvm-image.qcow2 2>/dev/null || true

if [ ! -f "$RAW_IMAGE" ]; then
    echo "ERROR: $RAW_IMAGE not found. mkosi build may have failed."
    exit 1
fi

# ── 3. Regenerate initrd with dracut (offline, in chroot) ──
# mkosi's built-in initrd doesn't include our custom trustee-attester binary.
# We chroot into the image and regenerate the initrd with dracut, which picks up
# /etc/dracut.conf.d/cvm-selfencrypt.conf to include the correct binaries.
#
# TODO: When Fedora Rawhide updates trustee-guest-components to a version that
# supports kbs+provisioner:// resource URIs (upstream guest-components >= 0.18),
# the custom trustee-attester binary in mkosi.extra/usr/bin/ will no longer be
# needed. At that point, mkosi's built-in initrd (from InitrdPackages=) will
# include the correct binary, and this entire step 3 can be removed.
echo ""
echo "=== Regenerating initrd with dracut (offline) ==="

MNT=$(mktemp -d)
LOOP=$(sudo losetup --find --show --partscan "$RAW_IMAGE")
echo "  Loop device: $LOOP"

# Mount root partition (p3 = linux-generic, label=fedora)
sudo mount ${LOOP}p3 "$MNT"
# Mount boot partition (p2 = xbootldr, label=boot)
sudo mount ${LOOP}p2 "$MNT/boot"
# Bind-mount kernel interfaces for dracut
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /sys "$MNT/sys"

# Find the kernel version installed in the image
KVER=$(sudo ls "$MNT/lib/modules/" | head -1)
echo "  Kernel version: $KVER"

# Find the existing initrd path (mkosi puts it at ImageId/initrd, not ImageId/kver/initrd)
MKOSI_INITRD="$MNT/boot/cvm-selfencrypt/initrd"
if sudo test -f "$MKOSI_INITRD"; then
    INITRD_PATH="$MKOSI_INITRD"
else
    # Fallback: standard Fedora path
    INITRD_PATH="$MNT/boot/initramfs-${KVER}.img"
fi
# Convert to path relative to chroot
INITRD_REL=${INITRD_PATH#"$MNT"}
echo "  Initrd path: $INITRD_REL"

# Regenerate initrd inside chroot
sudo chroot "$MNT" dracut -f "$INITRD_REL" "$KVER" 2>&1 | tail -20
DRACUT_RC=${PIPESTATUS[0]}

if [ $DRACUT_RC -ne 0 ]; then
    echo "ERROR: dracut failed with exit code $DRACUT_RC"
else
    echo "  initrd regenerated successfully."
    # Verify custom binaries are included
    sudo chroot "$MNT" lsinitrd "$INITRD_REL" 2>/dev/null | grep -E "trustee-attester|token-kbs|repart-kbs" \
        && echo "  OK: CVM artifacts found in initrd" \
        || echo "  WARNING: CVM artifacts not found in initrd"
fi

# Unmount everything
sudo umount "$MNT/sys" 2>/dev/null || true
sudo umount "$MNT/proc" 2>/dev/null || true
sudo umount "$MNT/dev" 2>/dev/null || true
sudo umount "$MNT/boot"
sudo umount "$MNT"
sudo losetup -d "$LOOP"
rmdir "$MNT"

echo "=== initrd regeneration complete ==="

# ── 4. Convert to qcow2 ──
QCOW2_IMAGE="$SCRIPT_DIR/cvm-image.qcow2"
echo ""
echo "Converting to qcow2..."
qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$QCOW2_IMAGE"
echo "Created: $QCOW2_IMAGE"

# ── 5. Build containerDisk (rootless podman) ──
echo ""
echo "=== Building containerDisk ==="
podman build -t "$REGISTRY/$IMAGE_REPO:$IMAGE_TAG" -f Dockerfile.containerdisk "$SCRIPT_DIR"
echo "Container image built: $REGISTRY/$IMAGE_REPO:$IMAGE_TAG"

echo ""
echo "=== Done ==="
echo "  Disk image:  $QCOW2_IMAGE"
echo "  Container:   $REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
echo ""
echo "To push to registry:"
echo "  podman login $REGISTRY"
echo "  podman push $REGISTRY/$IMAGE_REPO:$IMAGE_TAG"
