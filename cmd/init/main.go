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

	ensureAuthorizedKeys()
	startGuestAgent()
	startSSHD()

	// Bring up loopback + first NIC.
	_ = run("ip", "link", "set", "lo", "up")

	iface := firstNonLoopbackIface()
	if iface == "" {
		kver := kernelRelease()
		if kver != "" {
			failover := fmt.Sprintf("/lib/modules/%s/kernel/net/core/failover.ko", kver)
			if _, err := os.Stat(failover); err == nil {
				if err := run("insmod", failover); err != nil {
					log("goos: insmod failover failed: " + err.Error())
				}
			}
			netFailover := fmt.Sprintf("/lib/modules/%s/kernel/drivers/net/net_failover.ko", kver)
			if _, err := os.Stat(netFailover); err == nil {
				if err := run("insmod", netFailover); err != nil {
					log("goos: insmod net_failover failed: " + err.Error())
				}
			}
			virtio := fmt.Sprintf("/lib/modules/%s/kernel/drivers/net/virtio_net.ko", kver)
			if _, err := os.Stat(virtio); err == nil {
				if err := run("insmod", virtio); err != nil {
					log("goos: insmod virtio_net failed: " + err.Error())
				}
			} else {
				log("goos: virtio_net module not found")
			}
			e1000 := fmt.Sprintf("/lib/modules/%s/kernel/drivers/net/ethernet/intel/e1000/e1000.ko", kver)
			if _, err := os.Stat(e1000); err == nil {
				if err := run("insmod", e1000); err != nil {
					log("goos: insmod e1000 failed: " + err.Error())
				}
			}
		}
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

func kernelRelease() string {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func startGuestAgent() {
	if _, err := exec.LookPath("qemu-guest-kragent"); err != nil {
		return
	}
	cmd := exec.Command("qemu-guest-kragent")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Start()
}

func startSSHD() {
	if _, err := exec.LookPath("sshd"); err != nil {
		return
	}
	cmd := exec.Command("sshd", "-ip", "0.0.0.0", "-port", "2222", "-privatekey", "/id_rsa", "-keys", "/authorized_keys")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Start()
}

func ensureAuthorizedKeys() {
	if _, err := os.Stat("/authorized_keys"); err == nil {
		return
	}
	_ = os.WriteFile("/authorized_keys", []byte{}, 0o600)
}

func log(s string) {
	fmt.Fprintln(os.Stderr, s)
	// Also try kernel message buffer if present.
	_ = os.WriteFile(filepath.Join("/dev", "kmsg"), []byte(s+"\n"), 0o644)
}
