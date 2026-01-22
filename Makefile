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
INITRAMFS_ARCH := $(BUILD)/initramfs-arch.img
INITRAMFS_MERGED := $(BUILD)/initramfs-merged.cpio
KVER       ?= $(shell uname -r)
E1000_ZST  := /usr/lib/modules/$(KVER)/kernel/drivers/net/ethernet/intel/e1000/e1000.ko.zst
E1000_KO   := $(BUILD)/e1000.ko
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
  github.com/u-root/u-root/cmds/core/true \
  github.com/u-root/u-root/cmds/core/mkdir \
  github.com/u-root/u-root/cmds/core/ping \
  github.com/u-root/u-root/cmds/core/dmesg \
  github.com/u-root/u-root/cmds/core/insmod \
  github.com/u-root/u-root/cmds/exp/modprobe

.PHONY: all init kernel kernel-arch initramfs initramfs-arch iso qemu clean

all: qemu

$(BUILD):
	mkdir -p $(BUILD)

# Build your Go "uinit" (runs after u-root init starts)
init: | $(BUILD)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(INITBIN) ./cmd/init

# Copy a host kernel for QEMU dev
# tried to cover almost all dists there
kernel: | $(BUILD)
	@set -e; \
	if [ -r "$(VMLINUX)" ]; then \
	  echo "Using existing kernel: $(VMLINUX)"; \
	  exit 0; \
	fi; \
	for k in \
	  /boot/vmlinuz-`uname -r` \
	  /boot/vmlinuz-linux \
	  /boot/vmlinuz-linux-lts \
	  /boot/vmlinuz \
	  ; do \
	    if [ -r "$$k" ]; then \
	      echo "Using kernel: $$k"; \
	      cp -L "$$k" "$(VMLINUX)"; \
	      exit 0; \
	    fi; \
	  done; \
	k=$$(ls -1 /usr/lib/modules/*/vmlinuz 2>/dev/null | sort | tail -n 1); \
	if [ -n "$$k" ] && [ -r "$$k" ]; then \
	  echo "Using kernel: $$k"; \
	  cp -L "$$k" "$(VMLINUX)"; \
	  exit 0; \
	fi; \
	k=$$(ls -1 /boot/vmlinuz* 2>/dev/null | head -n 1); \
	if [ -n "$$k" ] && [ -r "$$k" ]; then \
	  echo "Using kernel: $$k"; \
	  cp -L "$$k" "$(VMLINUX)"; \
	  exit 0; \
	fi; \
	echo "ERROR: Could not find readable kernel image under /boot or /usr/lib/modules"; \
	exit 1

# Arch Linux helper: install the stock kernel and copy it into build/.
kernel-arch: | $(BUILD)
	sudo pacman -S --needed --noconfirm linux
	@set -e; \
	K=""; \
	if [ -r /boot/vmlinuz-linux ]; then \
	  K=/boot/vmlinuz-linux; \
	else \
	  K=$$(ls -1 /usr/lib/modules/*/vmlinuz 2>/dev/null | sort | tail -n 1); \
	fi; \
	if [ -z "$$K" ] || [ ! -r "$$K" ]; then \
	  echo "ERROR: Could not find Arch kernel image in /boot/vmlinuz-linux or /usr/lib/modules/*/vmlinuz"; \
	  exit 1; \
	fi; \
	echo "Using kernel: $$K"; \
	sudo cp -L "$$K" $(VMLINUX)


# Build initramfs (u-root + our uinit). We force module mode so u-root uses your repo's go.mod/go.sum.
initramfs: init Makefile | $(BUILD)
	go install github.com/u-root/u-root@$(UROOT_VER)
	@set -e; \
	FILES_ARGS=""; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(E1000_ZST)" ]; then \
	  zstd -d -c "$(E1000_ZST)" > "$(E1000_KO)"; \
	  FILES_ARGS="-files $(E1000_KO):/lib/modules/$(KVER)/kernel/drivers/net/ethernet/intel/e1000/e1000.ko"; \
	else \
	  echo "WARN: e1000 module not found or zstd missing; skipping e1000.ko"; \
	fi; \
	GO111MODULE=on u-root -build=bb -format=cpio -o $(INITRAMFS) \
	  -files "$(INITBIN):bbin/goos-init" \
	  $$FILES_ARGS \
	  -uinitcmd="/bbin/goos-init" \
	  -defaultsh=gosh \
	  $(UROOT_CMDS)

# Build an Arch initramfs with kernel modules and merge it with u-root.
initramfs-arch: initramfs | $(BUILD)
	sudo mkinitcpio -c $(abspath mkinitcpio-goos.conf) -g $(INITRAMFS_ARCH)
	sudo chmod a+r $(INITRAMFS_ARCH)
	cat $(INITRAMFS_ARCH) $(INITRAMFS) > $(INITRAMFS_MERGED)

# Build a bootable GRUB ISO (good for Proxmox upload)
iso: initramfs kernel
	mkdir -p $(ISODIR)/boot/grub
	cp -f $(VMLINUX) $(ISODIR)/boot/vmlinuz
	cp -f $(INITRAMFS) $(ISODIR)/boot/initramfs.cpio
	cp -f assets/grub/grub.cfg $(ISODIR)/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO) $(ISODIR)


# Boot the kernel+initramfs in QEMU. Add virtio-rng to avoid entropy stalls.
qemu: kernel-arch initramfs
	@if [ -c /dev/kvm ]; then ACCEL="-enable-kvm -cpu host"; else ACCEL="-accel tcg"; fi; \
	INITRD="$(INITRAMFS)"; \
	if [ -r "$(INITRAMFS_MERGED)" ]; then INITRD="$(INITRAMFS_MERGED)"; fi; \
	qemu-system-x86_64 -m 1024 -nographic $$ACCEL \
	  -device virtio-rng-pci \
	  -netdev user,id=n0 -device e1000,netdev=n0 \
	  -kernel $(VMLINUX) \
	  -initrd $$INITRD \
	  -append "console=ttyS0 goos.shell=1"

clean:
	rm -rf $(BUILD)
