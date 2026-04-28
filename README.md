# GOOS

Tasks:

```
task clean
task init
task iso
task iso-docker
task qemu
task qemu-mac
task qemu-mac-bridge
```

`task`
Shows the public tasks.

`task clean`
Removes `build/`.

`task init`
Builds `cmd/init` and `cmd/installer` into `build/`.

`task iso`
Builds a Linux-hosted ISO. Calls the internal initramfs and kernel tasks, then writes `build/goos.iso`.

`task iso-docker`
Builds the hybrid BIOS+UEFI ISO with Docker. This is the macOS path and writes `build/goos.iso`.

`task qemu`
Builds what it needs for a Linux local boot and runs the image in QEMU.

`task qemu-mac`
Builds what it needs for a macOS local boot and runs the image in QEMU with user networking.

`task qemu-mac-bridge`
Builds what it needs for a macOS local boot and runs the image in QEMU through `socket_vmnet`.

## macOS

Start `socket_vmnet` first:

```
sudo /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet \
  --vmnet-mode=bridged \
  --vmnet-interface=$IFACE \
  /var/run/socket_vmnet
```

Then run:

```
task qemu-mac-bridge
```

## Proxmox

Before install:
- BIOS: OVMF or SeaBIOS
- CD/DVD: attach `goos.iso`
- Disk: add target disk
- Network: VirtIO
- Serial port: add `serial0`
- If using OVMF: add an EFI disk

Use:

```
qm terminal <vmid>
```

The installer runs on `ttyS0`.

After install:
- Remove the ISO
- Keep OVMF for the installed disk
- Boot from the installed disk

Example:

```
qm set <vmid> --delete ide2
qm set <vmid> --efidisk0 <storage>:1,efitype=4m,pre-enrolled-keys=0
qm set <vmid> --boot order=scsi0;net0
```
