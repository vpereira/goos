# GOOS

Build targets:

```
make clean initramfs
make clean iso
make clean iso-docker
make qemu
make qemu-mac-bridge
```

`iso-docker` is the macOS path for building `build/goos.iso`.

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
make qemu-mac-bridge
```

## Proxmox

Before install:
- BIOS: SeaBIOS
- CD/DVD: attach `goos.iso`
- Disk: add target disk
- Network: VirtIO
- Serial port: add `serial0`

Use:

```
qm terminal <vmid>
```

The installer ISO boots via BIOS and runs on `ttyS0`.

After install:
- Remove the ISO
- Change BIOS to OVMF
- Add an EFI disk
- Boot from the installed disk

Example:

```
qm set <vmid> --delete ide2
qm set <vmid> --bios ovmf
qm set <vmid> --efidisk0 <storage>:1,efitype=4m,pre-enrolled-keys=0
qm set <vmid> --boot order=scsi0;net0
```
