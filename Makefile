# Makefile — build a Go-based uinit, build a u-root initramfs, and build an ISO + boot in QEMU
#
# Key idea:
#   - u-root provides /init (its init command) and runs our Go binary as "uinit".
#   - We install our Go init at bin/goos-init and set -uinitcmd=bin/goos-init.

BUILD      := build
ISODIR     := $(BUILD)/iso
VMLINUX    := $(BUILD)/vmlinuz
INITBIN    := $(BUILD)/goos-init
INSTALLBIN := $(BUILD)/goos-installer
INITRAMFS  := $(BUILD)/initramfs.cpio
INITRAMFS_ARCH := $(BUILD)/initramfs-arch.img
INITRAMFS_MERGED := $(BUILD)/initramfs-merged.cpio
KVER       ?= $(shell uname -r)
E1000_ZST  := /usr/lib/modules/$(KVER)/kernel/drivers/net/ethernet/intel/e1000/e1000.ko.zst
E1000_KO   := $(BUILD)/e1000.ko
VIRTIO_NET_ZST := /usr/lib/modules/$(KVER)/kernel/drivers/net/virtio_net.ko.zst
VIRTIO_NET_KO  := $(BUILD)/virtio_net.ko
NET_FAILOVER_ZST := /usr/lib/modules/$(KVER)/kernel/drivers/net/net_failover.ko.zst
NET_FAILOVER_KO  := $(BUILD)/net_failover.ko
FAILOVER_ZST := /usr/lib/modules/$(KVER)/kernel/net/core/failover.ko.zst
FAILOVER_KO  := $(BUILD)/failover.ko
ATA_PIIX_ZST := /usr/lib/modules/$(KVER)/kernel/drivers/ata/ata_piix.ko.zst
ATA_PIIX_KO  := $(BUILD)/ata_piix.ko
CDROM_ZST := /usr/lib/modules/$(KVER)/kernel/drivers/cdrom/cdrom.ko.zst
CDROM_KO  := $(BUILD)/cdrom.ko
SR_MOD_ZST := /usr/lib/modules/$(KVER)/kernel/drivers/scsi/sr_mod.ko.zst
SR_MOD_KO  := $(BUILD)/sr_mod.ko
ISOFS_ZST := /usr/lib/modules/$(KVER)/kernel/fs/isofs/isofs.ko.zst
ISOFS_KO  := $(BUILD)/isofs.ko
GOPATH    := $(shell go env GOPATH)
KRAGENT_PKG := github.com/bradfitz/qemu-guest-kragent
KRAGENT_BIN := $(BUILD)/qemu-guest-kragent
KRAGENT_REQUIRED ?= 1
AUTH_KEYS ?= assets/ssh/authorized_keys
SSH_HOST_KEY := $(BUILD)/ssh_host_rsa_key
SSH_AUTH_KEYS := $(BUILD)/authorized_keys
EFI_BOOT_BIN := $(BUILD)/systemd-bootx64.efi
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
  github.com/u-root/u-root/cmds/core/hostname \
  github.com/u-root/u-root/cmds/core/id \
  github.com/u-root/u-root/cmds/core/sshd \
  github.com/u-root/u-root/cmds/core/ps

.PHONY: all init kernel kernel-arch kernel-docker efi-bootloader kragent-docker initramfs initramfs-arch iso qemu qemu-mac clean

all: qemu

$(BUILD):
	mkdir -p $(BUILD)

# Build your Go "uinit" (runs after u-root init starts)
init: | $(BUILD)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(INITBIN) ./cmd/init
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(INSTALLBIN) ./cmd/installer

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

# Fetch systemd-bootx64.efi using Docker for portable builds.
efi-bootloader: | $(BUILD)
	@if ! command -v docker >/dev/null 2>&1; then \
	  echo "ERROR: docker not found; cannot fetch systemd-bootx64.efi"; \
	  exit 1; \
	fi; \
	docker run --rm -v $(abspath $(BUILD)):/out archlinux:latest sh -c '\
	  set -e; \
	  pacman-key --init >/dev/null 2>&1; \
	  pacman-key --populate archlinux >/dev/null 2>&1; \
	  pacman -Sy --noconfirm systemd >/dev/null 2>&1; \
	  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /out/systemd-bootx64.efi'

# macOS/Docker: extract x86_64 kernel from Ubuntu Docker image
kernel-docker: | $(BUILD)
	@set -e; \
	if [ -r "$(VMLINUX)" ]; then \
	  echo "Using existing kernel: $(VMLINUX)"; \
	  exit 0; \
	fi; \
	echo "Extracting x86_64 kernel from Ubuntu..."; \
	docker rm -f goos-kernel-tmp 2>/dev/null || true; \
	docker run --platform linux/amd64 --name goos-kernel-tmp ubuntu:24.04 sh -c \
	  "apt-get update && apt-get install -y --no-install-recommends linux-image-generic >/dev/null 2>&1 && cp /boot/vmlinuz-* /vmlinuz"; \
	docker cp goos-kernel-tmp:/vmlinuz $(VMLINUX); \
	docker rm goos-kernel-tmp >/dev/null; \
	echo "Kernel extracted to $(VMLINUX)"


# Build initramfs (u-root + our uinit). We force module mode so u-root uses your repo's go.mod/go.sum.
initramfs: init Makefile | $(BUILD)
	go install github.com/u-root/u-root@$(UROOT_VER)
	@set -e; \
	FILES_ARGS=""; \
	if command -v ssh-keygen >/dev/null 2>&1; then \
	  if [ ! -r "$(SSH_HOST_KEY)" ]; then \
	    ssh-keygen -t rsa -b 2048 -N "" -f "$(SSH_HOST_KEY)" >/dev/null; \
	  fi; \
	fi; \
	if [ -r "$(AUTH_KEYS)" ]; then \
	  cp -f "$(AUTH_KEYS)" "$(SSH_AUTH_KEYS)"; \
	else \
	  : > "$(SSH_AUTH_KEYS)"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(E1000_ZST)" ]; then \
	  zstd -d -c "$(E1000_ZST)" > "$(E1000_KO)"; \
	  FILES_ARGS="-files $(E1000_KO):lib/modules/$(KVER)/kernel/drivers/net/ethernet/intel/e1000/e1000.ko"; \
	else \
	  echo "WARN: e1000 module not found or zstd missing; skipping e1000.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(FAILOVER_ZST)" ]; then \
	  zstd -d -c "$(FAILOVER_ZST)" > "$(FAILOVER_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(FAILOVER_KO):lib/modules/$(KVER)/kernel/net/core/failover.ko"; \
	else \
	  echo "WARN: failover module not found or zstd missing; skipping failover.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(VIRTIO_NET_ZST)" ]; then \
	  zstd -d -c "$(VIRTIO_NET_ZST)" > "$(VIRTIO_NET_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(VIRTIO_NET_KO):lib/modules/$(KVER)/kernel/drivers/net/virtio_net.ko"; \
	else \
	  echo "WARN: virtio_net module not found or zstd missing; skipping virtio_net.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(NET_FAILOVER_ZST)" ]; then \
	  zstd -d -c "$(NET_FAILOVER_ZST)" > "$(NET_FAILOVER_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(NET_FAILOVER_KO):lib/modules/$(KVER)/kernel/drivers/net/net_failover.ko"; \
	else \
	  echo "WARN: net_failover module not found or zstd missing; skipping net_failover.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(ATA_PIIX_ZST)" ]; then \
	  zstd -d -c "$(ATA_PIIX_ZST)" > "$(ATA_PIIX_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(ATA_PIIX_KO):lib/modules/$(KVER)/kernel/drivers/ata/ata_piix.ko"; \
	else \
	  echo "WARN: ata_piix module not found or zstd missing; skipping ata_piix.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(CDROM_ZST)" ]; then \
	  zstd -d -c "$(CDROM_ZST)" > "$(CDROM_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(CDROM_KO):lib/modules/$(KVER)/kernel/drivers/cdrom/cdrom.ko"; \
	else \
	  echo "WARN: cdrom module not found or zstd missing; skipping cdrom.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(SR_MOD_ZST)" ]; then \
	  zstd -d -c "$(SR_MOD_ZST)" > "$(SR_MOD_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(SR_MOD_KO):lib/modules/$(KVER)/kernel/drivers/scsi/sr_mod.ko"; \
	else \
	  echo "WARN: sr_mod module not found or zstd missing; skipping sr_mod.ko"; \
	fi; \
	if command -v zstd >/dev/null 2>&1 && [ -r "$(ISOFS_ZST)" ]; then \
	  zstd -d -c "$(ISOFS_ZST)" > "$(ISOFS_KO)"; \
	  FILES_ARGS="$$FILES_ARGS -files $(ISOFS_KO):lib/modules/$(KVER)/kernel/fs/isofs/isofs.ko"; \
	else \
	  echo "WARN: isofs module not found or zstd missing; skipping isofs.ko"; \
	fi; \
	if [ ! -r "$(EFI_BOOT_BIN)" ] && command -v docker >/dev/null 2>&1; then \
	  $(MAKE) efi-bootloader; \
	fi; \
	if [ ! -x "$(KRAGENT_BIN)" ]; then \
	  if [ "$(KRAGENT_REQUIRED)" = "1" ]; then \
	    $(MAKE) kragent-docker; \
	  else \
	    echo "INFO: qemu-guest-kragent disabled (KRAGENT_REQUIRED=0)"; \
	  fi; \
	fi; \
	if [ -x "$(KRAGENT_BIN)" ]; then \
	  FILES_ARGS="$$FILES_ARGS -files $(KRAGENT_BIN):bbin/qemu-guest-kragent"; \
	elif [ "$(KRAGENT_REQUIRED)" = "1" ]; then \
	  echo "ERROR: qemu-guest-kragent missing; build failed"; \
	  exit 1; \
	fi; \
	if [ -r "$(SSH_HOST_KEY)" ]; then \
	  FILES_ARGS="$$FILES_ARGS -files $(SSH_HOST_KEY):id_rsa"; \
	fi; \
	if [ -r "$(SSH_AUTH_KEYS)" ]; then \
	  FILES_ARGS="$$FILES_ARGS -files $(SSH_AUTH_KEYS):authorized_keys"; \
	fi; \
	if [ -r "$(EFI_BOOT_BIN)" ]; then \
	  FILES_ARGS="$$FILES_ARGS -files $(EFI_BOOT_BIN):systemd-bootx64.efi"; \
	else \
	  echo "WARN: systemd-bootx64.efi not found; installer EFI path will fail"; \
	fi; \
	GOOS=linux GOARCH=amd64 GO111MODULE=on u-root -build=bb -format=cpio -o $(INITRAMFS) \
	  -files "$(INITBIN):bbin/goos-init" \
	  -files "$(INSTALLBIN):bbin/goos-installer" \
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
	  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	  -device virtio-serial-pci \
	  -chardev socket,id=qga0,path=$(BUILD)/qga.sock,server=on,wait=off \
	  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
	  -kernel $(VMLINUX) \
	  -initrd $$INITRD \
	  -append "console=ttyS0 goos.shell=1"

# macOS: boot with Docker-sourced kernel and TCG acceleration
qemu-mac: kernel-docker initramfs
	gzip -kf $(INITRAMFS)
	qemu-system-x86_64 -m 1024 -nographic -accel tcg \
	  -device virtio-rng-pci \
	  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	  -kernel $(VMLINUX) \
	  -initrd $(INITRAMFS).gz \
	  -append "console=ttyS0 goos.shell=1"

clean:
	rm -rf $(BUILD)
# Build qemu-guest-kragent inside Docker for portability.
kragent-docker: | $(BUILD)
	@if ! command -v docker >/dev/null 2>&1; then \
	  echo "ERROR: docker not found; cannot build qemu-guest-kragent"; \
	  exit 1; \
	fi; \
	docker run --rm -v $(abspath $(BUILD)):/out -w /src golang:1.22 sh -c '\
	  GOBIN=/out go install $(KRAGENT_PKG)@latest'
