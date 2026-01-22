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
  github.com/u-root/u-root/cmds/core/mkdir \
  github.com/u-root/u-root/cmds/core/ping

.PHONY: all init kernel initramfs iso qemu clean

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
	# Try common distro locations / names
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
	# Fallback: any vmlinuz* file
	k=$$(ls -1 /boot/vmlinuz* 2>/dev/null | head -n 1); \
	if [ -n "$$k" ] && [ -r "$$k" ]; then \
	  echo "Using kernel: $$k"; \
	  cp -L "$$k" "$(VMLINUX)"; \
	  exit 0; \
	fi; \
	echo "ERROR: Could not find readable kernel image under /boot (looked for vmlinuz-*, vmlinuz-linux, vmlinuz-linux-lts)"; \
	exit 1


# Build initramfs (u-root + our uinit). We force module mode so u-root uses your repo's go.mod/go.sum.
initramfs: init | $(BUILD)
	go install github.com/u-root/u-root@$(UROOT_VER)
	GO111MODULE=on u-root -build=bb -format=cpio -o $(INITRAMFS) \
	  -files "$(INITBIN):bbin/goos-init" \
	  -uinitcmd="/bbin/goos-init" \
	  -defaultsh=gosh \
	  $(UROOT_CMDS)

# Build a bootable GRUB ISO (good for Proxmox upload)
iso: initramfs kernel
	mkdir -p $(ISODIR)/boot/grub
	cp -f $(VMLINUX) $(ISODIR)/boot/vmlinuz
	cp -f $(INITRAMFS) $(ISODIR)/boot/initramfs.cpio
	cp -f assets/grub/grub.cfg $(ISODIR)/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO) $(ISODIR)


# Boot the ISO in QEMU (closest to Proxmox experience). Add virtio-rng to avoid entropy stalls.
qemu: iso
	@if [ -c /dev/kvm ]; then ACCEL="-enable-kvm -cpu host"; else ACCEL="-accel tcg"; fi; \
	qemu-system-x86_64 -m 1024 -nographic $$ACCEL \
	  -device virtio-rng-pci \
	  -cdrom $(ISO)

clean:
	rm -rf $(BUILD)

