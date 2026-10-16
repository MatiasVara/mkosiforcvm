# mkosiforcvm

Build self-encrypting Confidential VM (CVM) disk images using [mkosi](https://github.com/systemd/mkosi).
The resulting image encrypts its root partition on first boot using LUKS2 with a key
obtained via TDX attestation from a Key Broker Service (KBS). On subsequent boots,
the `libcryptsetup-token-kbs` plugin unlocks the partition automatically.

## Requirements

### Host tools

| Tool | Install | Purpose |
|------|---------|---------|
| mkosi >= v26 | `dnf install mkosi` | Builds the Fedora disk image |
| podman | `dnf install podman` | Builds the containerDisk for KubeVirt |
| qemu-img | `dnf install qemu-img` | Converts raw image to qcow2 |
| openssl | `dnf install openssl` | Used by mkosi during the build |

### Custom binaries

Two upstream binaries must be compiled and placed in `mkosi.extra/usr/bin/` before building:

**systemd-repart** (standalone, from upstream systemd main, post-262):

The `EncryptAddToken=` option is not yet in any systemd stable release. It was
[merged](https://github.com/systemd/systemd/pull/42089) on 2026-09-22 and will
ship in systemd 263.

```bash
git clone --depth=1 https://github.com/systemd/systemd.git && cd systemd
meson setup build -Drepart=enabled -Dblkid=enabled -Dfdisk=enabled \
  -Dopenssl=enabled -Dlibcryptsetup=enabled -Dmode=release \
  -Dstandalone-binaries=true
ninja -C build systemd-repart.standalone
cp build/systemd-repart.standalone ../mkosiforcvm/mkosi.extra/usr/bin/systemd-repart
```

**trustee-attester** (from upstream guest-components main):

The Fedora-packaged `trustee-guest-components` does not yet support
`kbs+provisioner://` resource URIs or the TDX attester. A custom build is required.

```bash
git clone --depth=1 https://github.com/confidential-containers/guest-components.git
cd guest-components
cargo build --release --bin trustee-attester \
  --features "bin,tdx-attester,background_check" --no-default-features \
  -p kbs_protocol
cp target/release/trustee-attester ../mkosiforcvm/mkosi.extra/usr/bin/trustee-attester
```

> **Note:** When Fedora Rawhide ships updated versions of these packages,
> the custom binaries will no longer be needed.

### Runtime environment

- A KubeVirt cluster with TDX-capable nodes
- A KBS instance accessible from the guest network
- A provisioned key in the KBS for the disk encryption

## How it works

The image goes through a two-boot process to achieve full root encryption:

### Build time

`build.sh` orchestrates the full pipeline:

1. **mkosi** builds a Fedora Rawhide disk image with three partitions:

   | Partition | Type | Format | Purpose |
   |-----------|------|--------|---------|
   | ESP | `esp` | vfat | EFI bootloader (shim + GRUB) |
   | Boot | `xbootldr` | xfs | Kernels, initrd, BLS entries |
   | Root | `linux-generic` | ext4 | Unencrypted root (label `fedora`), used only on first boot |

   The root partition intentionally uses `Type=linux-generic` (not `Type=root`) so
   that `systemd-gpt-auto-generator` ignores it once the encrypted partition exists.

2. **dracut** regenerates the initrd inside the image (via chroot), replacing mkosi's
   built-in initrd. This ensures the custom `trustee-attester` binary and
   `libcryptsetup-token-kbs.so` plugin are available in the initrd for LUKS unlock
   on second boot.

3. The raw image is converted to **qcow2** and packaged as a **containerDisk**
   (`FROM scratch` + `ADD qcow2 /disk/`) for KubeVirt deployment.

### First boot

1. The kernel boots with `root=LABEL=fedora`, mounting the unencrypted root.

2. **`systemd-repart`** runs with a drop-in (`kbs-key.conf`) that:
   - Calls `repart-kbs-helper` to obtain an encryption key from the KBS via TDX attestation
   - Creates a new LUKS2-encrypted `Type=root` partition in the free disk space
   - Copies the root filesystem into the encrypted partition
   - Registers a `kbs` token in the LUKS2 header (`EncryptAddToken=kbs`)

3. **`post-repart.service`** (oneshot, runs after `systemd-repart`):
   - Mounts the boot partition
   - Removes `root=LABEL=fedora` from BLS entries and `grubenv`
   - Reboots the VM

### Second boot (and all subsequent boots)

1. GRUB boots the kernel **without** `root=` in the command line.

2. **`systemd-gpt-auto-generator`** discovers the `Type=root` partition (the encrypted one)
   by its GPT type GUID.

3. **`systemd-cryptsetup`** finds the `kbs` token in the LUKS2 header and invokes
   `libcryptsetup-token-kbs.so`, which:
   - Calls `trustee-attester` to perform TDX attestation against the KBS
   - Retrieves the decryption key
   - Unlocks the LUKS partition

4. The system boots normally with the encrypted root mounted at `/`.

### Key components

| File | Description |
|------|-------------|
| `mkosi.conf` | mkosi image definition (Fedora Rawhide, packages, kernel cmdline) |
| `mkosi.repart/*.conf` | Build-time partition layout (ESP, boot, unencrypted root) |
| `mkosi.extra/usr/lib/repart.d/10-root.conf` | First-boot repart definition (encrypted root with `EncryptAddToken=kbs`) |
| `mkosi.extra/etc/systemd/system/systemd-repart.service.d/kbs-key.conf` | Drop-in that fetches the KBS key before repartitioning |
| `mkosi.extra/usr/bin/post-repart.sh` | Removes `root=` from bootloader and reboots after encryption |
| `mkosi.extra/etc/systemd/system/post-repart.service` | Systemd unit for `post-repart.sh` (runs once on first boot) |
| `mkosi.extra/usr/lib/systemd/system-preset/50-post-repart.preset` | Ensures `post-repart.service` is enabled by default |
| `mkosi.extra/etc/dracut.conf.d/cvm-selfencrypt.conf` | Dracut config to include CVM binaries and modules in the initrd |
| `mkosi.extra/boot/efi/EFI/fedora/grub.cfg` | Minimal GRUB config on the ESP (redirects to boot partition) |
| `mkosi.extra/boot/grub2/grub.cfg` | Full GRUB config on the boot partition (loads BLS entries) |
| `Dockerfile.containerdisk` | OCI image definition for KubeVirt containerDisk |

## How to generate an image

1. Ensure the [requirements](#requirements) are met (host tools + custom binaries in `mkosi.extra/usr/bin/`).

2. Run the build script:

   ```bash
   ./build.sh
   ```

   This will:
   - Build the disk image with mkosi
   - Regenerate the initrd with dracut (includes custom binaries)
   - Convert to qcow2
   - Build the containerDisk

3. Push to a container registry:

   ```bash
   podman login quay.io
   podman push quay.io/mvaralar/cvm-selfencrypt:latest
   ```

4. Deploy on KubeVirt with a `VirtualMachine` manifest that uses the containerDisk
   and has TDX enabled.

   > **Important:** The VM disk must be **non-persistent** (ephemeral). The containerDisk
   > is ephemeral by design — changes persist only within the pod lifecycle.
   > This ensures each VM instance performs its own first-boot encryption with a
   > unique key from the KBS. Do **not** back the disk with a PersistentVolumeClaim,
   > as that would persist the encrypted state and the first-boot flow would only
   > run once.
