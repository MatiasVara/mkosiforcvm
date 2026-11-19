# Fedora UKI image for KubeVirt TDX CVMs

Build a self-encrypting Confidential VM disk image using Fedora's pre-signed
Unified Kernel Image (UKI). The Fedora UKI is not modified. Two locally signed
EFI addons provide the CVM initrd and the dm-verity root hash for `/usr`.

On first boot, `systemd-repart` creates a LUKS2-encrypted root using a key
obtained from a Key Broker Service (KBS) after TDX attestation. Later boots
unlock the same root through the `libcryptsetup-token-kbs` plugin.

## Requirements

### Host tools

| Tool | Install | Purpose |
|------|---------|---------|
| mkosi >= v26 | `dnf install mkosi` | Builds the Fedora disk image |
| systemd-ukify | `dnf install systemd-ukify` | Builds and signs the addons |
| systemd-boot-unsigned | `dnf install systemd-boot-unsigned` | Provides `addonx64.efi.stub` |
| binutils | `dnf install binutils` | `objcopy` reads the kernel version |
| openssl | `dnf install openssl` | Generates the addon signing key |
| qemu-img | `dnf install qemu-img` | Converts raw to qcow2 |
| podman | `dnf install podman` | Builds the containerDisk |


### Custom binary

`systemd-repart` must support `EncryptAddToken=`. Fedora 262 does not. Build a
standalone binary from upstream systemd main (post-262) and place it at:

```text
mkosi.extra/usr/bin/systemd-repart
```

or set `REPART_BINARY` to its absolute path.

### Addon signing key

The two addons are signed locally. If both `addon.key` and `addon.crt` are
missing, the build runs `genkey.sh` and creates a development pair:

```text
addon.key  private signing key;
addon.crt  PEM certificate used by ukify
addon.cer  DER certificate for trust enrollment
```

### Runtime environment

- KubeVirt cluster with TDX-capable nodes
- KBS reachable from the guest network
- InitData containing the KBS URL and resource URI
- A provisioned key in the KBS for the root encryption

## How it works

### Build time

`build.sh uki` orchestrates the build:

1. **mkosi** builds a Fedora Rawhide disk with three partitions:

   | Partition | Type | Format | Purpose |
   |-----------|------|--------|---------|
   | ESP | `esp` | vfat | Fedora shim, Fedora UKI, and the two addons |
   | `/usr` | `usr` | ext4 | Immutable OS files and `/usr/root-copy` |
   | `/usr` verity | `usr-verity` | dm-verity hash | Verifies the `/usr` partition |

   `SplitArtifacts=uki,roothash` writes the UKI and `/usr` root hash next to
   the disk image.

2. **build.sh** reads the kernel version from the UKI `.uname` section and builds
   a temporary Rawhide root. `dracut --no-hostonly` creates the runtime initrd
   for that exact kernel.

3. **ukify** builds two addons:
   - `10-runtime.addon.efi` contains the initrd and
     `rd.neednet=1 ip=dhcp systemd.import_credentials=false`.
   - `20-usrhash.addon.efi` contains
     `usrhash=<hash> audit=0 rw`.

   Both addons are placed in `grubx64.EFI.extra.d/` next to the Fedora UKI on
   the ESP. The UKI filename comes from the Fedora shim path; it is not GRUB.

4. The raw image is converted to qcow2 without resizing

### First boot

1. Shim loads the Fedora-signed UKI. `systemd-stub` loads both addons.
2. The initrd mounts the verified read-only `/usr` and brings up the network.
3. `repart-kbs-helper` attests to KBS and retrieves the root key.
4. `systemd-repart` creates the LUKS2 root from the free space provided by the
   larger DataVolume/PVC, registers the `kbs` token, formats ext4, and copies
   `/usr/root-copy` into it.

### Later boots

1. The initrd mounts the verified `/usr` and brings up the network.
2. `systemd-cryptsetup` finds the LUKS2 `kbs` token.
3. The token plugin attests to KBS, retrieves the key, and unlocks root.
4. `systemd-repart` finds the existing layout and makes no changes.

### Key components

| File | Description |
|------|-------------|
| `mkosi.conf` | Image definition: Fedora Rawhide, packages, signed UKI |
| `mkosi.repart/*.conf` | Build-time ESP, `/usr`, and verity partitions |
| `mkosi.finalize` | Moves mutable root content to `/usr/root-copy` and relabels it |
| `mkosi.extra/usr/lib/repart.d/60-root.conf` | First-boot encrypted-root definition |
| `addon/mkosi.conf` | Temporary root used to build the runtime initrd |
| `addon/mkosi.extra/etc/dracut.conf.d/cvm-uki.conf` | Dracut modules, drivers, and KBS files |
| `addon/mkosi.extra/.../systemd-repart.service.d/kbs-key.conf` | Fetches the KBS key before root creation |
| `addon/mkosi.extra/.../systemd-cryptsetup@.service.d/kbs-network.conf` | Orders later KBS unlocks after networking |
| `build.sh` | Builds the disk, initrd, addons, and qcow2 |
| `genkey.sh` | Generates the development addon signing key |
| `Containerfile` | Packages the qcow2 as a KubeVirt containerDisk |

## How to generate an image

1. Ensure the [requirements](#requirements) are met, including the custom
   `systemd-repart` binary.

2. Run the build:

   ```bash
   ./build.sh uki
   ```

   Outputs in `variants/uki/`:

   - `fedora-rawhide-cvm-uki.raw`
   - `fedora-rawhide-cvm-uki.efi`
   - `fedora-rawhide-cvm-uki.roothash`
   - `10-runtime.addon.efi`
   - `20-usrhash.addon.efi`
   - `cvm-uki-image.qcow2`

3. Build and push the containerDisk:

   ```bash
   podman build -t quay.io/<user>/<repo>:<tag> \
       -f variants/uki/Containerfile variants/uki
   podman push quay.io/<user>/<repo>:<tag>
   ```

4. Deploy on KubeVirt with TDX enabled and an InitData that provides the KBS URL
   and resource URI. Import the container image into a DataVolume/PVC larger
   than the disk image (15Gi in the test manifests). The PVC provides the free
   space for first-boot root creation. A direct ephemeral containerDisk has no
   free space and cannot complete the first-boot root flow.
