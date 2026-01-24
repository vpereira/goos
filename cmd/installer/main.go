package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	diskfs "github.com/diskfs/go-diskfs"
	diskpkg "github.com/diskfs/go-diskfs/disk"
	"github.com/diskfs/go-diskfs/filesystem"
	"github.com/diskfs/go-diskfs/partition/gpt"
	"golang.org/x/term"
)

var version = "dev"

type diskInfo struct {
	name  string
	size  string
	model string
}

func main() {
	_ = os.Setenv("PATH", "/bbin:/bin:/usr/bin:/sbin:/usr/sbin")
	mountBasics()
	reader := bufio.NewReader(os.Stdin)
	disks := detectDisks()

	printHeader()

	fmt.Println("### 1) Choose installation disk")
	fmt.Println()
	fmt.Println("Detected disks:")
	fmt.Println()
	for i, d := range disks {
		fmt.Printf("%d. `%s` — `%s` — `%s`\n", i+1, d.name, d.size, d.model)
	}
	fmt.Println()

	diskIndex := promptIndex(reader, "Select disk to erase and install to", len(disks), 1)
	fmt.Println()
	fmt.Println("> WARNING: All data on the selected disk will be permanently deleted.")
	if !promptYesNo(reader, "Proceed with erase?", false) {
		fmt.Println()
		fmt.Println("Installation cancelled.")
		return
	}

	fmt.Println()
	fmt.Println("---")
	fmt.Println()
	fmt.Println("### 2) Network configuration")
	fmt.Println()
	fmt.Println("Choose network mode:")
	fmt.Println()
	fmt.Println("1. DHCP (recommended)")
	fmt.Println("2. Static IPv4")
	fmt.Println()
	netChoice := promptIndex(reader, "Select [1-2]", 2, 1)
	networkMode := "dhcp"
	staticIPv4 := ""
	staticGW := ""
	staticDNS := ""
	if netChoice == 2 {
		networkMode = "static"
		fmt.Println()
		staticIPv4 = promptLine(reader, "IPv4 address (CIDR), e.g. 192.168.1.50/24")
		staticGW = promptLine(reader, "Gateway, e.g. 192.168.1.1")
		staticDNS = promptLine(reader, "DNS servers (comma-separated), e.g. 1.1.1.1,8.8.8.8")
	}

	fmt.Println()
	fmt.Println("---")
	fmt.Println()
	fmt.Println("### 3) Remote access")
	fmt.Println()
	fmt.Println("Enable SSH server?")
	fmt.Println()
	fmt.Println("1. No (default)")
	fmt.Println("2. Yes")
	fmt.Println()
	sshChoice := promptIndex(reader, "Select [1-2]", 2, 1)
	sshEnabled := sshChoice == 2
	sshKey := ""
	if sshEnabled {
		fmt.Println()
		fmt.Println("Authorized SSH key (optional)")
		fmt.Println("Paste a single public key line (or leave empty to skip):")
		sshKey = promptRaw(reader, "")
	}

	fmt.Println()
	fmt.Println("---")
	fmt.Println()
	fmt.Println("### 4) Console access")
	fmt.Println()
	fmt.Println("Set root password for console login:")
	fmt.Println()
	rootPass := promptPassword(reader)
	fmt.Println()
	fmt.Println("(Leave empty to disable password login and require SSH key / console-only access.)")

	fmt.Println()
	fmt.Println("---")
	fmt.Println()
	fmt.Println("### 5) Node role")
	fmt.Println()
	fmt.Println("Choose role:")
	fmt.Println()
	fmt.Println("1. None (configure later)")
	fmt.Println("2. Worker")
	fmt.Println("3. Master")
	fmt.Println()
	roleChoice := promptIndex(reader, "Select [1-3]", 3, 1)
	role := "none"
	masterURL := ""
	joinToken := ""
	switch roleChoice {
	case 2:
		role = "worker"
	case 3:
		role = "master"
	}
	if roleChoice != 1 {
		fmt.Println()
		masterURL = promptLine(reader, "Master URL (e.g. https://master.local:8443)")
		joinToken = promptLine(reader, "Join token")
	}

	fmt.Println()
	fmt.Println("---")
	fmt.Println()
	fmt.Println("### 6) Summary")
	fmt.Println()
	fmt.Printf("Install target: `%s`\n", disks[diskIndex-1].name)
	fmt.Printf("Network: `%s`\n", networkMode)
	fmt.Printf("SSH: `%s`\n", boolLabel(sshEnabled))
	fmt.Printf("Role: `%s`\n", role)
	fmt.Println()

	if !promptYesNo(reader, "Proceed with installation?", false) {
		fmt.Println()
		fmt.Println("Installation cancelled.")
		return
	}

	cfg := installerConfig{
		Disk:        disks[diskIndex-1].name,
		Network:     networkMode,
		StaticIPv4:  staticIPv4,
		StaticGW:    staticGW,
		StaticDNS:   staticDNS,
		SSHEnabled:  sshEnabled,
		SSHKey:      sshKey,
		RootPass:    rootPass,
		Role:        role,
		MasterURL:   masterURL,
		JoinToken:   joinToken,
	}

	fmt.Println()
	fmt.Println("Installing…")
	fmt.Println()
	fmt.Println("* Partitioning disk…")
	fmt.Println("* Formatting ext4… (skipped)")
	fmt.Println("* Writing boot files…")
	fmt.Println("* Writing configuration…")

	if err := installUEFI(cfg); err != nil {
		fmt.Println()
		fmt.Printf("ERROR: %v\n", err)
		waitForever()
	}

	fmt.Println()
	fmt.Println("✅ Installation complete.")
	fmt.Println()
	fmt.Println("Remove ISO and press Enter to reboot.")
	_, _ = reader.ReadString('\n')
	if err := syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART); err != nil {
		fmt.Println("Reboot failed; drop to console.")
	}
	waitForever()
}

func printHeader() {
	fmt.Println("GOOS Installer (Proxmox VM)")
	fmt.Printf("Version: `%s`\n", version)
	fmt.Println("This installer will ERASE a disk and install GOOS.")
	fmt.Println()
	fmt.Println("---")
	fmt.Println()
}

func detectDisks() []diskInfo {
	entries, err := os.ReadDir("/sys/block")
	if err != nil {
		return nil
	}
	var disks []diskInfo
	for _, e := range entries {
		name := e.Name()
		if skipDisk(name) {
			continue
		}
		size := readSize(name)
		model := readModel(name)
		disks = append(disks, diskInfo{name: name, size: size, model: model})
	}
	if len(disks) == 0 {
		disks = append(disks, diskInfo{name: "unknown", size: "0", model: "unknown"})
	}
	return disks
}

func skipDisk(name string) bool {
	for _, prefix := range []string{"loop", "ram", "sr", "fd"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func readSize(name string) string {
	b, err := os.ReadFile(filepath.Join("/sys/block", name, "size"))
	if err != nil {
		return "unknown"
	}
	sec, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return "unknown"
	}
	bytes := sec * 512
	gib := float64(bytes) / (1024 * 1024 * 1024)
	if gib >= 1 {
		return fmt.Sprintf("%.1fG", gib)
	}
	mb := float64(bytes) / (1024 * 1024)
	return fmt.Sprintf("%.0fM", mb)
}

func readModel(name string) string {
	modelPath := filepath.Join("/sys/block", name, "device", "model")
	b, err := os.ReadFile(modelPath)
	if err == nil {
		m := strings.TrimSpace(string(b))
		if m != "" {
			return m
		}
	}
	return "unknown"
}

func promptIndex(r *bufio.Reader, label string, max, def int) int {
	for {
		fmt.Printf("%s [%d-%d] (default: %d): ", label, 1, max, def)
		line, _ := r.ReadString('\n')
		line = strings.TrimSpace(line)
		if line == "" {
			return def
		}
		n, err := strconv.Atoi(line)
		if err == nil && n >= 1 && n <= max {
			return n
		}
		fmt.Println("Invalid selection.")
	}
}

func promptLine(r *bufio.Reader, label string) string {
	fmt.Printf("%s: ", label)
	line, _ := r.ReadString('\n')
	return strings.TrimSpace(line)
}

func promptRaw(r *bufio.Reader, label string) string {
	if label != "" {
		fmt.Printf("%s: ", label)
	}
	line, _ := r.ReadString('\n')
	return strings.TrimSpace(line)
}

func promptYesNo(r *bufio.Reader, label string, def bool) bool {
	defLabel := "no"
	if def {
		defLabel = "yes"
	}
	for {
		fmt.Printf("%s [y/N] (default: %s): ", label, defLabel)
		line, _ := r.ReadString('\n')
		line = strings.TrimSpace(strings.ToLower(line))
		if line == "" {
			return def
		}
		if line == "y" || line == "yes" {
			return true
		}
		if line == "n" || line == "no" {
			return false
		}
		fmt.Println("Please answer yes or no.")
	}
}

func boolLabel(v bool) string {
	if v {
		return "enabled"
	}
	return "disabled"
}

func promptPassword(r *bufio.Reader) string {
	for {
		fmt.Print("New password: ")
		pass, err := readPassword(r)
		if err != nil {
			fmt.Println("Failed to read password.")
			continue
		}
		fmt.Print("Confirm password: ")
		confirm, err := readPassword(r)
		if err != nil {
			fmt.Println("Failed to read password.")
			continue
		}
		if pass == confirm {
			return pass
		}
		fmt.Println("Passwords do not match. Try again.")
	}
}

func readPassword(r *bufio.Reader) (string, error) {
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		b, err := term.ReadPassword(fd)
		fmt.Println()
		return strings.TrimSpace(string(b)), err
	}
	line, err := r.ReadString('\n')
	return strings.TrimSpace(line), err
}

type installerConfig struct {
	Disk       string
	Network    string
	StaticIPv4 string
	StaticGW   string
	StaticDNS  string
	SSHEnabled bool
	SSHKey     string
	RootPass   string
	Role       string
	MasterURL  string
	JoinToken  string
}

func installUEFI(cfg installerConfig) error {
	diskPath := filepath.Join("/dev", cfg.Disk)
	disk, err := diskfs.Open(
		diskPath,
		diskfs.WithOpenMode(diskfs.ReadWrite),
	)
	if err != nil {
		return fmt.Errorf("open disk: %w", err)
	}
	defer disk.Backend.Close()

	sectorSize := uint64(disk.LogicalBlocksize)
	if sectorSize == 0 {
		sectorSize = 512
	}
	physSize := int64(disk.PhysicalBlocksize)
	if physSize == 0 {
		physSize = int64(sectorSize)
	}
	start := uint64(2048)
	totalSectors := uint64(disk.Size) / sectorSize
	espStart := start
	espEnd := totalSectors - 2048
	if espEnd <= espStart {
		return fmt.Errorf("disk too small for EFI install")
	}
	fmt.Printf("DEBUG: disk size=%d bytes logical=%d physical=%d\n", disk.Size, sectorSize, physSize)
	fmt.Printf("DEBUG: GPT esp start=%d end=%d total=%d\n", espStart, espEnd, totalSectors)

	table := &gpt.Table{
		LogicalSectorSize:  int(sectorSize),
		PhysicalSectorSize: int(physSize),
		ProtectiveMBR:      true,
		Partitions: []*gpt.Partition{
			{
				Start: espStart,
				End:   espEnd,
				Type:  gpt.EFISystemPartition,
				Name:  "EFI System",
			},
		},
	}
	if err := disk.Partition(table); err != nil {
		return fmt.Errorf("partition disk: %w", err)
	}
	if _, err := disk.GetPartitionTable(); err != nil {
		return fmt.Errorf("verify GPT: %w", err)
	}

	espFS, err := disk.CreateFilesystem(diskpkg.FilesystemSpec{
		Partition:   1,
		FSType:      filesystem.TypeFat32,
		VolumeLabel: "EFI",
	})
	if err != nil {
		return fmt.Errorf("format EFI partition: %w", err)
	}

	if err := copyBootFiles(espFS); err != nil {
		return err
	}
	if err := writeConfigToFS(espFS, cfg); err != nil {
		return err
	}
	_ = espFS.Close()
	syscall.Sync()

	if err := verifyESP(diskPath); err != nil {
		return err
	}

	return nil
}

func copyBootFiles(esp filesystem.FileSystem) error {
	if err := mountISO(); err != nil {
		return err
	}
	efi, err := os.ReadFile("/systemd-bootx64.efi")
	if err != nil {
		return fmt.Errorf("read systemd-bootx64.efi: %w", err)
	}
	kernel, err := os.ReadFile("/mnt/iso/boot/vmlinuz")
	if err != nil {
		return fmt.Errorf("read vmlinuz: %w", err)
	}
	initrd, err := os.ReadFile("/mnt/iso/boot/initramfs.cpio")
	if err != nil {
		return fmt.Errorf("read initramfs.cpio: %w", err)
	}

	if err := mkdirAll(esp, "/EFI/BOOT"); err != nil {
		return err
	}
	if err := writeFile(esp, "/EFI/BOOT/BOOTX64.EFI", efi); err != nil {
		return err
	}
	if err := writeFile(esp, "/vmlinuz", kernel); err != nil {
		return err
	}
	if err := writeFile(esp, "/initramfs.cpio", initrd); err != nil {
		return err
	}
	if err := mkdirAll(esp, "/loader/entries"); err != nil {
		return err
	}

	loaderConf := "default goos\n" +
		"timeout 0\n" +
		"editor no\n"
	entryConf := "title GOOS\n" +
		"linux /vmlinuz\n" +
		"initrd /initramfs.cpio\n" +
		"options console=ttyS0 goos.shell=1\n"

	if err := writeFile(esp, "/loader/loader.conf", []byte(loaderConf)); err != nil {
		return err
	}
	if err := writeFile(esp, "/loader/entries/goos.conf", []byte(entryConf)); err != nil {
		return err
	}
	return nil
}

func verifyESP(diskPath string) error {
	disk, err := diskfs.Open(
		diskPath,
		diskfs.WithOpenMode(diskfs.ReadOnly),
	)
	if err != nil {
		return fmt.Errorf("verify ESP: open disk: %w", err)
	}
	defer disk.Backend.Close()
	if _, err := disk.GetPartitionTable(); err != nil {
		return fmt.Errorf("verify ESP: read partition table: %w", err)
	}
	fs, err := disk.GetFilesystem(1)
	if err != nil {
		return fmt.Errorf("verify ESP: read filesystem: %w", err)
	}
	f, err := fs.OpenFile("/EFI/BOOT/BOOTX64.EFI", os.O_RDONLY)
	if err != nil {
		return fmt.Errorf("verify ESP: missing BOOTX64.EFI: %w", err)
	}
	_ = f.Close()
	return nil
}

func mountISO() error {
	loadISOModules()
	_ = os.MkdirAll("/mnt/iso", 0o755)
	debugBlockDevices()
	if isReadonlyBlock("vda") {
		if err := tryMountISO("/dev/vda"); err == nil {
			return nil
		}
	}
	if dev, ok := findReadonlyBlock(); ok {
		if err := tryMountISO(dev); err == nil {
			return nil
		}
	}
	for _, dev := range []string{"/dev/sr0", "/dev/sr1", "/dev/cdrom", "/dev/dvd", "/dev/hdc"} {
		if _, err := os.Stat(dev); err == nil {
			if err := tryMountISO(dev); err == nil {
				return nil
			}
		}
	}
	return fmt.Errorf("no ISO device found")
}

func findReadonlyBlock() (string, bool) {
	entries, err := os.ReadDir("/sys/block")
	if err != nil {
		return "", false
	}
	for _, e := range entries {
		name := e.Name()
		roPath := filepath.Join("/sys/block", name, "ro")
		b, err := os.ReadFile(roPath)
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(b)) == "1" {
			dev := filepath.Join("/dev", name)
			if _, err := os.Stat(dev); err == nil {
				return dev, true
			}
		}
	}
	return "", false
}

func isReadonlyBlock(name string) bool {
	roPath := filepath.Join("/sys/block", name, "ro")
	b, err := os.ReadFile(roPath)
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(b)) == "1"
}

func tryMountISO(dev string) error {
	if err := syscall.Mount(dev, "/mnt/iso", "iso9660", syscall.MS_RDONLY, ""); err == nil {
		return nil
	} else {
		fmt.Printf("DEBUG: mount iso9660 on %s failed: %v\n", dev, err)
	}
	if err := syscall.Mount(dev, "/mnt/iso", "udf", syscall.MS_RDONLY, ""); err == nil {
		return nil
	} else {
		fmt.Printf("DEBUG: mount udf on %s failed: %v\n", dev, err)
	}
	return fmt.Errorf("mount failed")
}

func debugBlockDevices() {
	entries, err := os.ReadDir("/sys/block")
	if err != nil {
		fmt.Println("WARN: cannot read /sys/block:", err)
		return
	}
	for _, e := range entries {
		name := e.Name()
		roPath := filepath.Join("/sys/block", name, "ro")
		roVal := "?"
		if b, err := os.ReadFile(roPath); err == nil {
			roVal = strings.TrimSpace(string(b))
		}
		devPath := filepath.Join("/dev", name)
		if _, err := os.Stat(devPath); err == nil {
			fmt.Printf("DEBUG: block %s ro=%s dev=%s\n", name, roVal, devPath)
		} else {
			fmt.Printf("DEBUG: block %s ro=%s dev=missing\n", name, roVal)
		}
	}
}

func loadISOModules() {
	kver := kernelRelease()
	if kver == "" {
		return
	}
	for _, mod := range []string{
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/scsi/scsi_mod.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/scsi/sd_mod.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/scsi/virtio_scsi.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/ata/ata_piix.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/cdrom/cdrom.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/drivers/scsi/sr_mod.ko", kver),
		fmt.Sprintf("/lib/modules/%s/kernel/fs/isofs/isofs.ko", kver),
	} {
		if _, err := os.Stat(mod); err == nil {
			_ = runCmd("insmod", mod)
		}
	}
	time.Sleep(200 * time.Millisecond)
}

func kernelRelease() string {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func mountBasics() {
	_ = os.MkdirAll("/proc", 0o755)
	_ = os.MkdirAll("/sys", 0o755)
	_ = os.MkdirAll("/dev", 0o755)
	_ = syscall.Mount("proc", "/proc", "proc", 0, "")
	_ = syscall.Mount("sysfs", "/sys", "sysfs", 0, "")
	_ = syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")
}

func runCmd(name string, args ...string) error {
	p, err := exec.LookPath(name)
	if err != nil {
		return err
	}
	cmd := exec.Command(p, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func mkdirAll(fs filesystem.FileSystem, dir string) error {
	parts := strings.Split(strings.TrimPrefix(dir, "/"), "/")
	cur := ""
	for _, p := range parts {
		if p == "" {
			continue
		}
		cur = cur + "/" + p
		_ = fs.Mkdir(cur)
	}
	return nil
}

func writeFile(fs filesystem.FileSystem, path string, data []byte) error {
	f, err := fs.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_TRUNC)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, bytes.NewReader(data))
	return err
}

func writeConfigToFS(fs filesystem.FileSystem, cfg installerConfig) error {
	if err := mkdirAll(fs, "/etc"); err != nil {
		// EFI partition doesn't need /etc; store at root instead.
		return writeFile(fs, "/goos-installer.conf", []byte(configText(cfg)))
	}
	return writeFile(fs, "/etc/goos-installer.conf", []byte(configText(cfg)))
}

func configText(cfg installerConfig) string {
	var b strings.Builder
	fmt.Fprintf(&b, "disk=%s\n", cfg.Disk)
	fmt.Fprintf(&b, "network=%s\n", cfg.Network)
	fmt.Fprintf(&b, "static_ipv4=%s\n", cfg.StaticIPv4)
	fmt.Fprintf(&b, "static_gw=%s\n", cfg.StaticGW)
	fmt.Fprintf(&b, "static_dns=%s\n", cfg.StaticDNS)
	fmt.Fprintf(&b, "ssh_enabled=%t\n", cfg.SSHEnabled)
	fmt.Fprintf(&b, "ssh_key=%s\n", cfg.SSHKey)
	fmt.Fprintf(&b, "root_password=%s\n", cfg.RootPass)
	fmt.Fprintf(&b, "role=%s\n", cfg.Role)
	fmt.Fprintf(&b, "master_url=%s\n", cfg.MasterURL)
	fmt.Fprintf(&b, "join_token=%s\n", cfg.JoinToken)
	return b.String()
}

func waitForever() {
	for {
		time.Sleep(10 * time.Second)
	}
}
