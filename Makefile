# Makefile — build a Go-based uinit, build a u-root initramfs, and build an ISO + boot in QEMU
#
# Key idea:
#   - u-root provides /init (its init command) and runs our Go binary as "uinit".
#   - We install our Go init at bin/goos-init and set -uinitcmd=bin/goos-init.

BUILD      := build
ISODIR     := $(BUILD)/iso
VMLINUX    := $(BUILD)/vmlinuz
INITBIN    := $(BUILD)/goos-init
INITRAMFS  := $(BUILD)/initramfs.cpio
ISO        := $(BUILD)/goos.iso

# Pin u-root for deterministic builds
UROOT_VER  := v0.15.0

# u-root command packages to include in the initramfs.
UROOT_CMDS := \
  github.com/u-root/u-root/cmds/core/init \
  github.com/u-root/u-root/cmds/core/gosh \
  github.com/u-root/u-root/cmds/core/ip \
  github.com/u-root/u-root/cmds/core/dhclient \
  github.com/u-root/u-root/cmds/core/ls \
  github.com/u-root/u-root/cmds/core/cat \
  github.com/u-root/u-root/cmds/core/mkdir

.PHONY: all init kernel initramfs iso qemu clean

all: qemu

$(BUILD):
	mkdir -p $(BUILD)

# Build your Go "uinit" (runs after u-root init starts)
init: | $(BUILD)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(INITBIN) ./cmd/init

# Copy a host kernel for QEMU dev
kernel: | $(BUILD)
	cp -L /boot/vmlinuz-`uname -r` $(VMLINUX) 2>/dev/null || \
	(ls -1 /boot/vmlinuz-* 2>/dev/null | tail -n 1 | xargs -I{} cp -L {} $(VMLINUX))

# Build initramfs (u-root + our uinit). We force module mode so u-root uses your repo's go.mod/go.sum.
initramfs: init | $(BUILD)
	go install github.com/u-root/u-root@$(UROOT_VER)
	GO111MODULE=on u-root -build=bb -format=cpio -o $(INITRAMFS) \
	  -files "$(INITBIN):bin/goos-init" \
	  -uinitcmd="bin/goos-init" \
	  -defaultsh=gosh \
	  $(UROOT_CMDS)

# Build a bootable GRUB ISO (good for Proxmox upload)
iso: initramfs kernel
	mkdir -p $(ISODIR)/boot/grub
	cp -f $(VMLINUX) $(ISODIR)/boot/vmlinuz
	cp -f $(INITRAMFS) $(ISODIR)/boot/initramfs.cpio
	@if [ -f build/iso/boot/grub/grub.cfg ]; then \
		cp -f build/iso/boot/grub/grub.cfg $(ISODIR)/boot/grub/grub.cfg; \
	else \
		cat > $(ISODIR)/boot/grub/grub.cfg <<'EOF'; \
set timeout=0; \
set default=0; \
menuentry "goos (u-root + Go uinit)" { \
  linux /boot/vmlinuz console=ttyS0; \
  initrd /boot/initramfs.cpio; \
} \
EOF \
	fi
	grub-mkrescue -o $(ISO) $(ISODIR)

# Boot the ISO in QEMU (closest to Proxmox experience). Add virtio-rng to avoid entropy stalls.
qemu: iso
	@if [ -c /dev/kvm ]; then ACCEL="-enable-kvm -cpu host"; else ACCEL="-accel tcg"; fi; \
	qemu-system-x86_64 -m 1024 -nographic $$ACCEL \
	  -device virtio-rng-pci \
	  -cdrom $(ISO)

clean:
	rm -rf $(BUILD)

