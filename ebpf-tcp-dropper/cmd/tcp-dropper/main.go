package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"golang.org/x/sys/unix"
)

func main() {
	// default port is 4040 and default interface is eth0 for blocking
	port := flag.Uint("port", 4040, "TCP port to block")
	ifaceName := flag.String("interface", "eth0", "Network interface to attach to")
	xdpMode := flag.String("xdp-mode", "auto", "XDP mode: auto|native|generic|offload")
	flag.Parse()

	// Look up the network interface
	iface, err := net.InterfaceByName(*ifaceName)
	if err != nil {
		log.Fatalf("Failed to find interface %s: %v", *ifaceName, err)
	}

	// Ensure bpffs is mounted when using map pinning
	if err := ensureBPFFSMounted("/sys/fs/bpf"); err != nil {
		log.Fatalf("bpffs check failed: %v. Hint: sudo mount -t bpf bpf /sys/fs/bpf", err)
	}

	// Load pre-compiled programs into the kernel.
	objs := bpfObjects{}
	if err := loadBpfObjects(&objs, &ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{
			PinPath: "/sys/fs/bpf/",
		},
	}); err != nil {
		log.Fatalf("Failed to load BPF objects: %v", err)
	}
	defer objs.Close()

	// Store the port to block in the BPF map
	key := uint32(0)
	portValue := uint16(*port)
	if err := objs.PortToBlock.Put(key, portValue); err != nil {
		log.Fatalf("Failed to update port in BPF map: %v", err)
	}

	// Attach the program to the network interface
	var l link.Link
	switch *xdpMode {
	case "native":
		l, err = link.AttachXDP(link.XDPOptions{Program: objs.DropTcpPort, Interface: iface.Index, Flags: 0})
		if err != nil {
			log.Fatalf("Failed to attach XDP program (native): %v", err)
		}
	case "generic":
		l, err = link.AttachXDP(link.XDPOptions{Program: objs.DropTcpPort, Interface: iface.Index, Flags: link.XDPGenericMode})
		if err != nil {
			log.Fatalf("Failed to attach XDP program (generic): %v", err)
		}
	case "offload":
		l, err = link.AttachXDP(link.XDPOptions{Program: objs.DropTcpPort, Interface: iface.Index, Flags: link.XDPOffloadMode})
		if err != nil {
			log.Fatalf("Failed to attach XDP program (offload): %v", err)
		}
	case "auto":
		fallthrough
	default:
		// Try native/driver mode first, then fall back to generic if unsupported
		l, err = link.AttachXDP(link.XDPOptions{Program: objs.DropTcpPort, Interface: iface.Index, Flags: 0})
		if err != nil {
			log.Printf("Native XDP attach failed (%v), retrying with generic mode...", err)
			l, err = link.AttachXDP(link.XDPOptions{Program: objs.DropTcpPort, Interface: iface.Index, Flags: link.XDPGenericMode})
			if err != nil {
				log.Fatalf("Failed to attach XDP program (generic mode): %v", err)
			}
		}
	}
	defer l.Close()

	log.Printf("Successfully loaded and attached XDP program to %s (index %d)", iface.Name, iface.Index)
	log.Printf("Dropping all TCP traffic on port %d", *port)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	log.Println("Detaching program and exiting...")
}

// ensureBPFFSMounted checks that bpffs is mounted at the given path. if the path isn't a bpf fs , it return an error.
func ensureBPFFSMounted(path string) error {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return err
	}
	const BPF_FS_MAGIC int64 = 0xCAFE4A11
	if int64(st.Type) != BPF_FS_MAGIC {
		return fmt.Errorf("%s is not bpffs (type=0x%x)", path, st.Type)
	}
	return nil
}
