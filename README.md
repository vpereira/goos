# GOOS build and run

This repo builds a u-root based initramfs, a GRUB ISO, and an EFI disk install.

## Build

Build initramfs only:
```
make clean initramfs
```

Build ISO (requires `grub-mkrescue`):
```
make clean initramfs iso
```

## Run (initramfs)

Boot kernel+initramfs directly:
```
make qemu
```

## Create a disk (recreate after rebuild)

Create a fresh disk before installing:
```
qemu-img create -f qcow2 build/goos-disk.qcow2 1G
```

After rebuilding the ISO/initramfs, delete and recreate the disk before reinstalling.

## Run ISO installer (BIOS)

```
sudo qemu-system-x86_64 -m 1024 -nographic -accel kvm \
  -drive file=build/goos.iso,if=virtio,format=raw,readonly=on \
  -drive file=build/goos-disk.qcow2,if=virtio,format=qcow2 \
  -device virtio-rng-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-serial-pci \
  -chardev socket,id=qga0,path=build/qga.sock,server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
```

## Boot installed disk (UEFI)

```
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd build/OVMF_VARS.fd

sudo qemu-system-x86_64 -m 1024 -nographic -accel kvm \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
  -drive id=disk0,file=build/goos-disk.qcow2,if=none,format=qcow2 \
  -device virtio-blk-pci,drive=disk0,bootindex=0 \
  -boot order=c \
  -device virtio-rng-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-serial-pci \
  -chardev socket,id=qga0,path=build/qga.sock,server=on,wait=off \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
```

If your OVMF files are in a different path, update the `-drive if=pflash` paths.
