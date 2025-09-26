# eBPF cgroup-based packet dropper

This project drops all network packets (ingress and/or egress) for a specific application by placing it into a dedicated cgroup v2 and attaching eBPF CGROUP_SKB programs to that cgroup.

It uses:
- eBPF CGROUP_SKB programs defined in `src/ebpf_dropper.c`
- A Go loader using `cilium/ebpf` and `bpf2go` in `cmd/dropper/`

## Requirements
- Linux kernel with eBPF and cgroup v2 (unified hierarchy) enabled
- Root privileges to attach eBPF programs and manage cgroups
- Go 1.22+
- Clang/LLVM toolchain (for `bpf2go`) and matching kernel headers

Suggested packages:
- Arch/Manjaro:
  - `sudo pacman -S go clang llvm linux-headers`
- Ubuntu/Debian:
  - `sudo apt-get update`
  - `sudo apt-get install -y golang clang llvm make linux-headers-$(uname -r)`

## Quick Start

1) Ensure cgroup v2 is mounted:
```
mount | grep cgroup2 || sudo mount -t cgroup2 none /sys/fs/cgroup
```

2) Create a cgroup for your app (example: `myapp`):
```
sudo mkdir -p /sys/fs/cgroup/myapp
```

3) Start your application in that cgroup (examples):
- Run an interactive shell inside the cgroup and start your app from there:
```
# Add current shell to the cgroup
echo $$ | sudo tee /sys/fs/cgroup/myapp/cgroup.procs
# Now start your app in this shell
./your_app ...
```

- Or use the helper script to run a command in the cgroup:
```
./scripts/run_in_cgroup.sh /sys/fs/cgroup/myapp "curl https://example.com"
```

4) Build the Go loader (this generates and compiles the eBPF code):
```
# From repo root
go generate ./bpf
go build -o ./bin/dropper ./cmd/dropper
```

5) Attach the eBPF dropper to that cgroup:
```
sudo ./bin/dropper --cgroup /sys/fs/cgroup/myapp --both
```
The program will attach and block ingress and egress for any processes in `myapp`. Press Ctrl-C to detach and restore connectivity.

You can choose direction explicitly:
```
# Only block egress (outgoing)
sudo ./bin/dropper --cgroup /sys/fs/cgroup/myapp --egress

# Only block ingress (incoming)
sudo ./bin/dropper --cgroup /sys/fs/cgroup/myapp --ingress

# Restrict to a specific interface (optional). If omitted, applies to all interfaces.
sudo ./bin/dropper --cgroup /sys/fs/cgroup/myapp --both --iface eth1
```

5) Add/remove processes from the cgroup as needed:
```
# Add PID 12345 to the cgroup
echo 12345 | sudo tee /sys/fs/cgroup/myapp/cgroup.procs
```

## How it works
- `src/ebpf_dropper.c` defines two CGROUP_SKB programs: `block_ingress` for `cgroup/ingress` and `block_egress` for `cgroup/egress`. They consult:
  - `cfg_ifindex`: when set to 0 the program applies to every interface, otherwise it only drops packets whose `skb->ifindex` matches the configured interface.
  - `cfg_port`: holds the TCP port to block (host byte order). A value of 0 disables port-based blocking. Packets whose source or destination port equals this value are dropped.
- `cmd/dropper/main.go` loads the generated eBPF objects (via `bpf2go`) and attaches them to the given cgroup path on ingress and/or egress. It handles cleanup on SIGINT/SIGTERM.

Because filters are attached to the cgroup, the policy applies to any process placed in the cgroup, providing a reliable way to target a specific application without needing to match PIDs by packet metadata.

## Notes and Troubleshooting
- Ensure cgroup v2 is enabled (unified hierarchy). Many modern distributions have it by default. Check `/proc/self/mountinfo` for `cgroup2`.
- You must run the attach script as root.
- If you get clang/llvm errors, make sure the toolchain and kernel headers are present for your running kernel.
- To persist the cgroup directory across reboots or integrate with systemd units, consider creating a systemd slice and using its path as the cgroup.

## Repository Layout
- `src/ebpf_dropper.c` – eBPF CGROUP_SKB programs that drop packets.
- `scripts/run_in_cgroup.sh` – Helper to run any command inside a given cgroup v2 path.
- `bpf/dropper_gen.go` – `go generate` entrypoint which runs `bpf2go` to compile the eBPF C into Go bindings.
- `cmd/dropper/main.go` – Go loader that attaches the programs to a cgroup.

## One-command Quick Start (orchestration script)

You can use the convenience script `scripts/dropper.sh` to handle build, cgroup setup, and attaching in one go.

Make it executable once:
```
chmod +x scripts/dropper.sh
```

Examples:
```
# Build everything, create the cgroup if missing, and attach both ingress+egress
sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --both --create --build

# Auto-mount cgroup v2 if missing, attach only egress, and run a command inside the cgroup
sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --egress --run "curl https://example.com" --create --auto-mount

# Attach only ingress in the foreground (Ctrl-C to detach)
sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --ingress

# Limit attachment to a specific interface
sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --both --iface eth1
```

Flags:
- `--cgroup <path>`: Target cgroup v2 path (required)
- `--ingress` | `--egress` | `--both`: Which direction(s) to attach (default `--both`)
- `--run <cmd>`: Run a command inside the cgroup while attached
- `--iface <name>`: Interface name to match (optional). If omitted, applies to all interfaces.
- `--create`: Create the cgroup directory if missing
- `--auto-mount`: Mount cgroup2 on `/sys/fs/cgroup` if not already mounted
- `--build` | `--no-build`: Force rebuild or skip build

Notes:
- Script must be run as root (uses cgroups and eBPF attach).
- Internally calls `scripts/build.sh` and `scripts/run_in_cgroup.sh`.
