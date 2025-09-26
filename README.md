# packet-blocker

`packet-blocker` groups two small eBPF projects that showcase different ways to
block network traffic directly in the Linux kernel using Go loaders:

- **Port-based dropper (`ebpf-tcp-dropper/`)** – XDP program that drops all TCP
  packets matching a given destination port on a specific interface.
- **Application dropper (`ebpf-tcp-dropper-application/`)** – CGROUP_SKB
  programs that block ingress/egress traffic for every process placed inside a
  target cgroup v2 path, with optional per-interface and per-port filtering.

Both projects rely on `cilium/ebpf` + `bpf2go` to keep the kernel and user space
code cleanly separated.

---

## Repository layout

```
README.md
go.work                 # Shared Go workspace (references both modules)
scripts/
  build.sh              # Builds one or both droppers
ebpf-tcp-dropper/       # XDP TCP port blocker
ebpf-tcp-dropper-application/  # Cgroup-based app blocker
```

Each subdirectory is a standalone Go module with its own README, scripts and
`bin/` output folder. Use the workspace file to work on both simultaneously.

---

## Requirements

- Linux kernel 4.18+ with eBPF + cgroup v2 (for the application dropper)
- Go 1.22+
- Clang/LLVM and matching kernel headers
- Root privileges (`CAP_BPF`, `CAP_NET_ADMIN`) when attaching programs

Install prerequisites on Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y build-essential clang llvm libelf-dev linux-headers-$(uname -r) golang
```

Ensure `bpffs` is mounted (needed when pinning maps):

```bash
sudo mount -t bpf bpf /sys/fs/bpf || true
```

For cgroup-based tests also make sure cgroup v2 is mounted on `/sys/fs/cgroup`.

---

## Quick start

1. Build everything from the repo root:

   ```bash
   scripts/build.sh            # builds both droppers
   scripts/build.sh --port-only  # only XDP port dropper
   scripts/build.sh --app-only   # only cgroup dropper
   ```

   The script checks for `go` and `clang`, runs `go generate` for each module
   and writes the binaries to:
   - `ebpf-tcp-dropper/bin/tcp-dropper`
   - `ebpf-tcp-dropper-application/bin/dropper`

2. Follow the module-specific README for detailed flags, scripts and testing.

If you prefer to work inside a Go workspace, run commands such as `go test` or
`go build` from the repo root; `go.work` already points to both modules.

---

## Usage overview

### 1. Block a TCP port with XDP

```bash
sudo ebpf-tcp-dropper/bin/tcp-dropper \
  -interface eth0 \
  -port 8080 \
  -xdp-mode auto
```

- Attaches an XDP program to the selected NIC.
- Drops every TCP packet whose destination port equals `-port`.
- Supports `auto`, `native`, `generic`, or `offload` attach modes.

### 2. Block an application via cgroups

```bash
# Prepare a cgroup
sudo mkdir -p /sys/fs/cgroup/myapp
echo $$ | sudo tee /sys/fs/cgroup/myapp/cgroup.procs

# Attach ingress + egress filters (drops packets hitting the configured port)
sudo ebpf-tcp-dropper-application/bin/dropper \
  --cgroup /sys/fs/cgroup/myapp \
  --both \
  --iface eth0        # optional: restrict to a single interface
```

Useful flags:
- `--ingress` / `--egress` / `--both`
- `--iface <name>` to scope to a single interface (`0` means any interface)
- `--port <tcp port>` to block that port bidirectionally (`0` disables the port filter)
- `--pid` or `--proc` to auto-enroll a process into the cgroup before attaching

Helper scripts inside `ebpf-tcp-dropper-application/scripts/` can orchestrate
building, mounting cgroup v2, and running commands inside the cgroup.

---

## Development notes

- `go.work` lets you `go test ./...` across both modules without replacing
  module paths.
- Integration tests under `ebpf-tcp-dropper-application/cmd/dropper` require
  root and a machine with cgroup v2 enabled; they are skipped otherwise.
- eBPF programs are generated via `bpf2go` (`go generate`). Re-run if you touch
  the C sources inside each module's `bpf/` or `src/` directory.
- Always run the binaries as root (or with the required capabilities) to attach
  to network interfaces or cgroups.

---

## License

MIT
# packet-blocker

`packet-blocker` is a lightweight toolkit that demonstrates two approaches to blocking network traffic using **eBPF** and **Go**:

- **Port-based blocking (XDP)** → Drop all TCP packets on a specified port.  
- **Application-based blocking (cgroups)** → Drop all packets (ingress/egress) for a given application by placing it into a dedicated cgroup.  

This repo combines both projects into one, showcasing different ways to enforce traffic policies directly in the Linux kernel with minimal overhead.

---

## Features
- High-performance packet dropping using **XDP** at the NIC driver level.  
- Per-application blocking using **cgroup v2 + CGROUP_SKB hooks**.  
- Go-based loaders using [`cilium/ebpf`](https://github.com/cilium/ebpf) and `bpf2go`.  
- Clean separation of kernel-space (C) and user-space (Go) code.  

---

## Requirements
- Linux kernel **4.18+** (XDP support) and **cgroup v2 enabled**.  
- Go **1.21+**  
- Clang/LLVM toolchain and kernel headers  
- Root privileges (`CAP_BPF`, `CAP_NET_ADMIN`)  

Install prerequisites (example for Ubuntu/Debian):  
```bash
sudo apt update
sudo apt install -y build-essential clang llvm libelf-dev linux-headers-$(uname -r) golang
```

---

## Repository Layout
```
bpf/             # eBPF C source programs
cmd/
  port-dropper/  # CLI for port-based blocking (XDP)
  app-dropper/   # CLI for application-based blocking (cgroups)
scripts/         # Helper scripts (build, cgroup runner, etc.)
bin/             # Compiled binaries
```

---

## Building
Build both tools:
```bash
./scripts/build.sh
```

Or build separately:  
```bash
# Port-based dropper
go generate ./cmd/port-dropper
go build -o ./bin/port-dropper ./cmd/port-dropper

# App-based dropper
go generate ./cmd/app-dropper
go build -o ./bin/app-dropper ./cmd/app-dropper
```

---

## Usage

### 1. Block a TCP Port
Drop all TCP packets on port 8080:
```bash
sudo ./bin/port-dropper -interface eth0 -port 8080
```

### 2. Block an Application
Create a cgroup and block all traffic for processes inside it:
```bash
sudo mkdir -p /sys/fs/cgroup/myapp
echo $$ | sudo tee /sys/fs/cgroup/myapp/cgroup.procs

sudo ./bin/app-dropper --cgroup /sys/fs/cgroup/myapp --both
```

Options:  
- `--ingress` → block only incoming  
- `--egress` → block only outgoing  
- `--both` → block both directions (default)  

---

## How It Works
- **Port-based dropper (XDP):** Attaches an eBPF program at the NIC driver’s XDP hook to inspect packets and drop those matching a target TCP port.  
- **App-based dropper (cgroups):** Attaches eBPF programs (`cgroup/ingress` and `cgroup/egress`) to a cgroup, ensuring all traffic from processes inside is dropped.  

---

## Notes
- Must be run as root.  
- Ensure `bpffs` is mounted at `/sys/fs/bpf` if required.  
- For persistent setups, integrate with systemd slices or orchestration scripts.  

---

## License
MIT  
