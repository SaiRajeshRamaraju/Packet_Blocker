package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"strings"
	"net"
	"io/ioutil"
	"strconv"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	bpf "github.com/example/ebpf-tcp-dropper-application/bpf"
)

var (
	flagCgroup  = flag.String("cgroup", "", "Path to cgroup v2 (e.g., /sys/fs/cgroup/myapp)")
	flagIngress = flag.Bool("ingress", false, "Block ingress traffic")
	flagEgress  = flag.Bool("egress", false, "Block egress traffic")
	flagBoth    = flag.Bool("both", false, "Block both ingress and egress (default)")
	flagIface   = flag.String("iface", "", "Interface name to match (optional). If empty, apply to all interfaces.")
	flagPort    = flag.Int("port", 4040, "TCP port to block (default 4040). 0 disables port filter")
	flagPID     = flag.Int("pid", 0, "Target process ID to add to the cgroup (optional)")
	flagProc    = flag.String("proc", "", "Target process name to add to the cgroup (e.g., myprocess). If provided, the first matching PID will be added.")
)

func mustRoot() {
	if os.Geteuid() != 0 {
		log.Fatal("this program must be run as root")
	}
}

func findPidByName(name string) (int, error) {
    entries, err := ioutil.ReadDir("/proc")
    if err != nil {
        return 0, err
    }
    for _, e := range entries {
        if !e.IsDir() { continue }
        pid, err := strconv.Atoi(e.Name())
        if err != nil { continue }
        // Try /proc/PID/comm first
        commBytes, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm"))
        if err == nil {
            comm := strings.TrimSpace(string(commBytes))
            if comm == name { return pid, nil }
        }
        // Fallback to cmdline contains substring
        cmdlineBytes, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
        if err == nil {
            cmd := strings.ReplaceAll(string(cmdlineBytes), "\x00", " ")
            if strings.Contains(cmd, name) { return pid, nil }
        }
    }
    return 0, fmt.Errorf("no process found with name %q", name)
}

func addPidToCgroup(cgPath string, pid int) error {
    procs := filepath.Join(cgPath, "cgroup.procs")
    f, err := os.OpenFile(procs, os.O_WRONLY|os.O_APPEND, 0644)
    if err != nil { return err }
    defer f.Close()
    if _, err := fmt.Fprintf(f, "%d\n", pid); err != nil { return err }
    return nil
}

func checkCgroupV2() error {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	if !strings.Contains(string(data), " - cgroup2 ") {
		return errors.New("cgroup v2 not mounted; please mount cgroup2 on /sys/fs/cgroup")
	}
	return nil
}

// contains is kept for backward compatibility, but now simply wraps strings.Contains.
func contains(s, substr string) bool { return strings.Contains(s, substr) }

func main() {
	mustRoot()
	flag.Parse()

	if !*flagIngress && !*flagEgress && !*flagBoth {
		*flagBoth = true
	}
	ingress := *flagBoth || *flagIngress
	egress := *flagBoth || *flagEgress

	if *flagCgroup == "" {
		log.Fatal("--cgroup path is required")
	}
	cgPath, err := filepath.Abs(*flagCgroup)
	if err != nil {
		log.Fatalf("resolving cgroup path: %v", err)
	}
	if st, err := os.Stat(cgPath); err != nil || !st.IsDir() {
		log.Fatalf("cgroup path does not exist or not a directory: %s", cgPath)
	}
	if err := checkCgroupV2(); err != nil {
		log.Fatal(err)
	}

	// If a PID or a process name was provided, add it to the cgroup before attaching
	if *flagPID != 0 {
		if err := addPidToCgroup(cgPath, *flagPID); err != nil {
			log.Fatalf("adding pid %d to cgroup: %v", *flagPID, err)
		}
		fmt.Printf("Added PID %d to %s\n", *flagPID, cgPath)
	} else if *flagProc != "" {
		pid, err := findPidByName(*flagProc)
		if err != nil {
			log.Fatal(err)
		}
		if err := addPidToCgroup(cgPath, pid); err != nil {
			log.Fatalf("adding pid %d to cgroup: %v", pid, err)
		}
		fmt.Printf("Added process %q (pid %d) to %s\n", *flagProc, pid, cgPath)
	}

	// Load compiled eBPF objects (generated via bpf2go)
	var objs bpf.DropperObjects
	if err := bpf.LoadDropperObjects(&objs, nil); err != nil {
		log.Fatalf("loading eBPF objects: %v", err)
	}
	defer objs.Close()

	// Configure interface index in cfg_ifindex map: 0 => all interfaces
	var ifidx uint32 = 0
	if *flagIface != "" {
		iface, err := net.InterfaceByName(*flagIface)
		if err != nil {
			log.Fatalf("lookup iface %q: %v", *flagIface, err)
		}
		if iface.Index <= 0 {
			log.Fatalf("invalid ifindex for iface %q: %d", *flagIface, iface.Index)
		}
		ifidx = uint32(iface.Index)
	}
	if m := objs.CfgIfindex; m != nil {
		key := uint32(0)
		if err := m.Put(key, ifidx); err != nil {
			log.Fatalf("setting cfg_ifindex: %v", err)
		}
	}

	// Configure TCP port in cfg_port map: 0 => disabled
	if *flagPort < 0 || *flagPort > 65535 {
		log.Fatalf("invalid --port: %d", *flagPort)
	}
	if m := objs.CfgPort; m != nil {
		key := uint32(0)
		p := uint16(*flagPort)
		if err := m.Put(key, p); err != nil {
			log.Fatalf("setting cfg_port: %v", err)
		}
	}

	var links []link.Link
	cleanup := func() {
		for i := len(links) - 1; i >= 0; i-- {
			_ = links[i].Close()
		}
	}
	defer cleanup()

	if ingress {
		l, err := link.AttachCgroup(link.CgroupOptions{
			Path:    cgPath,
			Attach:  ebpf.AttachCGroupInetIngress,
			Program: objs.BlockIngress,
		})
		if err != nil {
			log.Fatalf("attach ingress: %v", err)
		}
		links = append(links, l)
		fmt.Printf("Attached ingress dropper to %s\n", cgPath)
	}

	if egress {
		l, err := link.AttachCgroup(link.CgroupOptions{
			Path:    cgPath,
			Attach:  ebpf.AttachCGroupInetEgress,
			Program: objs.BlockEgress,
		})
		if err != nil {
			log.Fatalf("attach egress: %v", err)
		}
		links = append(links, l)
		fmt.Printf("Attached egress dropper to %s\n", cgPath)
	}

	fmt.Println("Press Ctrl-C to detach and exit.")
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	fmt.Println("Detaching...")
}
