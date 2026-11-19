#!/bin/bash
# Build the Fedora UKI-based CVM image and its two signed EFI addons.
#
# Prerequisites:
#   - ukify (systemd-ukify), objcopy (binutils)
#   - systemd-boot-unsigned (provides addonx64.efi.stub)
#   - custom standalone systemd-repart with EncryptAddToken=kbs support,
#     or set REPART_BINARY=/absolute/path/systemd-repart
#   - addon.key and addon.crt: created once by variants/uki/genkey.sh. They are
#     generated automatically only when both files are missing.
#
# Usage:
#   ./build.sh uki
#
# Environment overrides:
#   REPART_BINARY   custom systemd-repart binary
#   ADDON_STUB      addonx64.efi.stub path
#
# Outputs:
#   fedora-rawhide-cvm-uki.raw        GPT disk image
#   fedora-rawhide-cvm-uki.efi        split Fedora UKI
#   fedora-rawhide-cvm-uki.roothash   /usr verity roothash
#   cvm-uki-image.qcow2               VM disk

set -euo pipefail

# ── 1. Resolve paths and build settings ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

IMAGE_ID="fedora-rawhide-cvm-uki"
RAW_IMAGE="$SCRIPT_DIR/$IMAGE_ID.raw"
FEDORA_UKI="$SCRIPT_DIR/$IMAGE_ID.efi"
USR_HASH_FILE="$SCRIPT_DIR/$IMAGE_ID.roothash"
RUNTIME_INITRD="$SCRIPT_DIR/artifacts/runtime-addon.initrd"
RUNTIME_ROOT="$SCRIPT_DIR/artifacts/runtime-addon-root"
RUNTIME_ADDON="$SCRIPT_DIR/10-runtime.addon.efi"
USRHASH_ADDON="$SCRIPT_DIR/20-usrhash.addon.efi"
QCOW2_IMAGE="$SCRIPT_DIR/cvm-uki-image.qcow2"
REPART_BINARY="${REPART_BINARY:-$REPO_DIR/mkosi.extra/usr/bin/systemd-repart}"
REPART_DEFINITION="$SCRIPT_DIR/mkosi.extra/usr/lib/repart.d/60-root.conf"
ADDON_STUB="${ADDON_STUB:-/usr/lib/systemd/boot/efi/addonx64.efi.stub}"
KEY="$SCRIPT_DIR/addon.key"
CERT="$SCRIPT_DIR/addon.crt"
RUNTIME_CMDLINE='rd.neednet=1 ip=dhcp systemd.import_credentials=false'
USRHASH_CMDLINE_EXTRA='audit=0 rw'

# ── 2. Check inputs and prepare files copied into the image ──
echo "=== mkosiforcvm variant: uki ==="
echo "Runtime command line: $RUNTIME_CMDLINE"

# Generate a development pair only when both files are absent
if [[ ! -f "$KEY" && ! -f "$CERT" ]]; then
    echo "No addon signing material found; generating a development key." >&2
    "$SCRIPT_DIR/genkey.sh"
fi

[[ -f "$ADDON_STUB" ]] || {
    echo "systemd addon stub not found: $ADDON_STUB" >&2
    echo "Install systemd-boot-unsigned or set ADDON_STUB=/absolute/path/addonx64.efi.stub" >&2
    exit 1
}
[[ -x "$REPART_BINARY" ]] || {
    echo "Custom systemd-repart not found or not executable: $REPART_BINARY" >&2
    exit 1
}

mkdir -p "$SCRIPT_DIR/artifacts" "$SCRIPT_DIR/addon/mkosi.extra/usr/bin"

# Dracut includes this custom binary in the runtime addon initrd, where
# systemd-repart runs before switching to the encrypted root.
install -m 0755 "$REPART_BINARY" "$SCRIPT_DIR/addon/mkosi.extra/usr/bin/systemd-repart"

cd "$SCRIPT_DIR"

# ── 3. Build the disk, Fedora UKI, and /usr dm-verity hash ──
echo "=== Building disk with Fedora's pre-signed UKI ==="
sudo mkosi --force build
sudo chown "$(id -u):$(id -g)" "$SCRIPT_DIR"/"$IMAGE_ID".* 2>/dev/null || true

[[ -f "$RAW_IMAGE" ]] || {
    echo "Raw disk was not produced: $RAW_IMAGE" >&2
    exit 1
}
[[ -f "$FEDORA_UKI" ]] || {
    echo "Split Fedora UKI was not produced: $FEDORA_UKI" >&2
    exit 1
}
[[ -s "$USR_HASH_FILE" ]] || {
    echo "Split /usr verity hash was not produced: $USR_HASH_FILE" >&2
    exit 1
}

USR_HASH="$(tr -d '[:space:]' < "$USR_HASH_FILE")"
printf '%s\n' "$USR_HASH"

# ── 4. Read the exact kernel version embedded in the Fedora UKI ──
# Extract the kernel version from the Fedora UKI. The runtime addon must build
# for this exact version so its kernel modules match the UKI.
inspect_dir="$(mktemp -d)"
cleanup_inspect() {
    rm -rf -- "$inspect_dir"
}
trap cleanup_inspect EXIT

# objcopy can rewrite its input PE; work on a disposable copy.
cp --reflink=auto "$FEDORA_UKI" "$inspect_dir/uki.efi"

# .uname contains the kernel release string used by the UKI.
objcopy --dump-section ".uname=$inspect_dir/uname" "$inspect_dir/uki.efi"

# Strip NUL padding and line endings from the PE section.
KVER="$(tr -d '\000\r\n' < "$inspect_dir/uname")"

# Fail if the section was missing or empty.
[[ -n "$KVER" ]] || {
    echo "Could not extract .uname from Fedora UKI" >&2
    exit 1
}

# Show the selected kernel in the build log.
printf '%s\n' "$KVER"
cleanup_inspect
trap - EXIT

# ── 5. Build the early-boot runtime initrd ──
echo "=== Building dracut/NetworkManager runtime addon initrd ==="
sudo mkosi --directory "$SCRIPT_DIR/addon" --force build

[[ -d "$RUNTIME_ROOT" ]] || {
    echo "Runtime addon build root was not produced: $RUNTIME_ROOT" >&2
    exit 1
}

# Keep one repart definition in the verified-/usr source tree. Copy
# it into the generated addon root so dracut embeds those exact same bytes in
# the runtime initrd used for first-boot root creation.
sudo install -D -m 0644 "$REPART_DEFINITION" "$RUNTIME_ROOT/usr/lib/repart.d/60-root.conf"

[[ -d "$RUNTIME_ROOT/usr/lib/modules/$KVER" ]] || {
    echo "Runtime addon has no kernel modules for Fedora UKI kernel $KVER" >&2
    exit 1
}

# Always release bind mounts if dracut or another command fails.
cleanup_addon_mounts() {
    local name
    for name in sys proc dev; do
        sudo umount "$RUNTIME_ROOT/$name" 2>/dev/null || true
    done
}
trap cleanup_addon_mounts EXIT

for source in /dev /proc /sys; do
    target="$RUNTIME_ROOT$source"
    sudo mount --bind "$source" "$target"
done

sudo rm -f "$RUNTIME_ROOT/runtime-addon.initrd"
sudo chroot "$RUNTIME_ROOT" dracut --force --no-hostonly /runtime-addon.initrd "$KVER"
sudo install -m 0644 "$RUNTIME_ROOT/runtime-addon.initrd" "$RUNTIME_INITRD"

cleanup_addon_mounts
trap - EXIT

sudo chown "$(id -u):$(id -g)" "$RUNTIME_INITRD"
[[ -s "$RUNTIME_INITRD" ]] || {
    echo "Runtime addon initrd was not produced: $RUNTIME_INITRD" >&2
    exit 1
}

# ── 6. Build and sign the two systemd-stub EFI addons ──
echo "=== Building and signing companion addons ==="
rm -f "$RUNTIME_ADDON" "$USRHASH_ADDON"

# Carries the additional initrd and early-network/credential command line.
ukify build \
    --stub="$ADDON_STUB" \
    --initrd="$RUNTIME_INITRD" \
    --cmdline="$RUNTIME_CMDLINE" \
    --uname="$KVER" \
    --secureboot-private-key="$KEY" \
    --secureboot-certificate="$CERT" \
    --output="$RUNTIME_ADDON"

# Carries the trusted /usr dm-verity root hash and root mount options.
ukify build \
    --stub="$ADDON_STUB" \
    --cmdline="usrhash=$USR_HASH $USRHASH_CMDLINE_EXTRA" \
    --uname="$KVER" \
    --secureboot-private-key="$KEY" \
    --secureboot-certificate="$CERT" \
    --output="$USRHASH_ADDON"

# ── 7. Install the addons beside the matching Fedora UKI on the ESP ──
echo "=== Injecting signed addons next to the Fedora UKI ==="
mount_dir="$(mktemp -d)"
loopdev=""
mounted=0
# Always unmount the ESP and detach the loop device if this stage fails.
cleanup_disk() {
    if (( mounted )); then
        sudo umount "$mount_dir" 2>/dev/null || true
    fi
    if [[ -n "$loopdev" ]]; then
        sudo losetup --detach "$loopdev" 2>/dev/null || true
    fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup_disk EXIT

loopdev="$(sudo losetup --find --show --partscan "$RAW_IMAGE")"
sudo udevadm settle

# This layout contains one vfat filesystem: the EFI System Partition.
esp="$(
    while IFS= read -r partition; do
        if [[ "$(sudo blkid -p -s TYPE -o value "$partition" 2>/dev/null || true)" == "vfat" ]]; then
            printf '%s\n' "$partition"
            break
        fi
    done < <(lsblk -nrpo PATH,TYPE "$loopdev" | awk '$2 == "part" { print $1 }')
)"

[[ -n "$esp" ]] || {
    lsblk -o PATH,TYPE,FSTYPE,PARTLABEL,PARTTYPE "$loopdev" >&2 || true
    echo "Could not locate the EFI System Partition in $RAW_IMAGE" >&2
    exit 1
}

sudo mount "$esp" "$mount_dir"
mounted=1

# Locate the byte-identical Fedora UKI without relying on its ESP filename.
uki_hash="$(sha256sum "$FEDORA_UKI" | awk '{print $1}')"
uki_on_esp=""
while IFS= read -r -d '' candidate; do
    if [[ "$(sudo sha256sum "$candidate" | awk '{print $1}')" == "$uki_hash" ]]; then
        uki_on_esp="$candidate"
        break
    fi
done < <(sudo find "$mount_dir" -type f -iname '*.efi' -print0)

[[ -n "$uki_on_esp" ]] || {
    echo "The Fedora UKI split artifact was not found byte-identically on the ESP" >&2
    exit 1
}

addon_dir="${uki_on_esp}.extra.d"
sudo mkdir -p "$addon_dir"
sudo install -m 0644 "$RUNTIME_ADDON" "$addon_dir/10-runtime.addon.efi"
sudo install -m 0644 "$USRHASH_ADDON" "$addon_dir/20-usrhash.addon.efi"
sync

sudo find "$mount_dir" -type f -printf '%P  %s bytes\n' | sort

sudo umount "$mount_dir"
mounted=0
sudo losetup --detach "$loopdev"
loopdev=""
rmdir "$mount_dir"
trap - EXIT

# ── 8. Convert the completed disk to the KubeVirt qcow2 image ──
echo "=== Converting the VM disk ==="
qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$QCOW2_IMAGE"
qemu-img info "$QCOW2_IMAGE"

# ── 9. Print outputs and containerDisk commands ──
echo
echo "Fedora prebuilt-UKI addon build complete:"
echo "  Fedora UKI:      $FEDORA_UKI"
echo "  Runtime addon:   $RUNTIME_ADDON"
echo "  usrhash addon:   $USRHASH_ADDON"
echo "  /usr hash:       $USR_HASH_FILE"
echo "  Raw disk:        $RAW_IMAGE"
echo "  VM qcow2:  $QCOW2_IMAGE"
echo "  Addon cert:      $SCRIPT_DIR/addon.cer"
echo
echo "To build and push:"
echo "  podman build -t <registry>/<repo>:<tag> \\"
echo "      -f $SCRIPT_DIR/Containerfile $SCRIPT_DIR"
echo "  podman push <registry>/<repo>:<tag>"
