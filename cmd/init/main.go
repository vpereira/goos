package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

func main() {
	// PID 1 should never exit.
	defer func() {
		for {
			time.Sleep(10 * time.Second)
		}
	}()

	// Minimal environment.
	_ = os.Setenv("PATH", "/bbin:/bin:/usr/bin:/sbin:/usr/sbin")
	_ = os.Setenv("HOME", "/")

	log("goos: init starting")

	// Mount basics (ignore errors if already mounted by kernel).
	mount("proc", "/proc", "proc", 0, "")
	mount("sysfs", "/sys", "sysfs", 0, "")
	mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")

	// Bring up loopback + first NIC.
	_ = run("ip", "link", "set", "lo", "up")

	iface := firstNonLoopbackIface()
	if iface == "" {
		// Try loading common NIC modules for QEMU before re-scanning.
		tryLoadNetModules([]string{"e1000", "virtio_net", "rtl8139", "e1000e"})
		iface = firstNonLoopbackIface()
	}
	if iface == "" {
		log("goos: no non-loopback interface found")
	} else {
		_ = run("ip", "link", "set", iface, "up")

		// Try DHCP via u-root dhclient if present.
		if _, err := exec.LookPath("dhclient"); err == nil {
			log("goos: attempting DHCP on " + iface)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()

			// u-root dhclient supports flags like -ipv4 / -ipv6=false (per u-root docs/examples). :contentReference[oaicite:1]{index=1}
			_ = runCtx(ctx, "dhclient", "-ipv4", "-ipv6=false", iface)
		} else {
			log("goos: dhclient not found in PATH")
		}

		// Show addresses for debugging.
		_ = run("ip", "addr", "show", iface)
	}

	// CI marker.
	fmt.Println("READY")

	b, _ := os.ReadFile("/proc/cmdline")
	if strings.Contains(string(b), "goos.shell=0") {
		log("goos: shell disabled via cmdline; idling")
		return
	}

	if _, err := exec.LookPath("gosh"); err == nil {
		log("goos: starting gosh (Ctrl+A X to exit QEMU -nographic)")
		_ = syscall.Exec(mustLookPath("gosh"), []string{"gosh"}, os.Environ())
	}

	log("goos: gosh not found; idling")
}

func mount(source, target, fstype string, flags uintptr, data string) {
	_ = os.MkdirAll(target, 0o755)
	_ = syscall.Mount(source, target, fstype, flags, data)
}

func run(name string, args ...string) error {
	return runCtx(context.Background(), name, args...)
}

func runCtx(ctx context.Context, name string, args ...string) error {
	p, err := exec.LookPath(name)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, p, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func mustLookPath(name string) string {
	p, err := exec.LookPath(name)
	if err != nil {
		return name
	}
	return p
}

func firstNonLoopbackIface() string {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return ""
	}
	var ifaces []string
	for _, e := range entries {
		n := e.Name()
		if n == "lo" {
			continue
		}
		// Skip weird entries just in case.
		if strings.Contains(n, "/") || strings.Contains(n, "..") {
			continue
		}
		ifaces = append(ifaces, n)
	}
	sort.Strings(ifaces)
	if len(ifaces) == 0 {
		return ""
	}
	return ifaces[0]
}

func tryLoadNetModules(mods []string) {
	if _, err := exec.LookPath("modprobe"); err != nil {
		log("goos: modprobe not found in PATH")
		return
	}
	for _, m := range mods {
		_ = run("modprobe", m)
	}
}

func log(s string) {
	fmt.Fprintln(os.Stderr, s)
	// Also try kernel message buffer if present.
	_ = os.WriteFile(filepath.Join("/dev", "kmsg"), []byte(s+"\n"), 0o644)
}
