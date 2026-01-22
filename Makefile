BUILD := build
VMLINUX := $(BUILD)/vmlinuz
INITBIN := $(BUILD)/init
INITRAMFS := $(BUILD)/initramfs.cpio
ISO := $(BUILD)/goos.iso
ISODIR := $(BUILD)/iso

UROOT_CMDS := \
  github.com/u-root/u-root/cmds/core/gosh \
  github.com/u-root/u-root/cmds/core/ip \
  github.com/u-root/u-root/cmds/core/ls \
  github.com/u-root/u-root/cmds/core/cat \
  github.com/u-root/u-root/cmds/core/mkdir \
  github.com/u-root/u-root/cmds/core/dhclient

.PHONY: all clean qemu kernel init initramfs iso

all: iso

$(BUILD):
	mkdir -p $(BUILD)

init: | $(BUILD)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(INITBIN) ./cmd/init

kernel: | $(BUILD)
	cp -L /boot/vmlinuz-`uname -r` $(VMLINUX) 2>/dev/null || \
	(ls -1 /boot/vmlinuz-* 2>/dev/null | tail -n 1 | xargs -I{} cp -L {} $(VMLINUX))

initramfs: init | $(BUILD)
	go install github.com/u-root/u-root@latest
	# Put our PID1 at /init inside the initramfs using -files (see u-root docs). :contentReference[oaicite:2]{index=2}
	u-root -build=bb -format=cpio -o $(INITRAMFS) \
	  -files "$(INITBIN):/init" \
	  $(UROOT_CMDS)

iso: initramfs kernel
	mkdir -p $(ISODIR)/boot/grub
	cp -f $(VMLINUX) $(ISODIR)/boot/vmlinuz
	cp -f $(INITRAMFS) $(ISODIR)/boot/initramfs.cpio
	cp -f build/iso/boot/grub/grub.cfg $(ISODIR)/boot/grub/grub.cfg
	grub-mkrescue -o $(ISO) $(ISODIR)

qemu: iso
	@if [ -c /dev/kvm ]; then ACCEL="-enable-kvm -cpu host"; else ACCEL="-accel tcg"; fi; \
	qemu-system-x86_64 -m 1024 -nographic $$ACCEL \
	  -cdrom $(ISO)

clean:
	rm -rf $(BUILD)

