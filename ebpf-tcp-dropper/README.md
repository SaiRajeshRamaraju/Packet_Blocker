# eBPF TCP Port Dropper

This is a simple eBPF program that drops TCP packets on a specified port. It uses XDP (eXpress Data Path) for high-performance packet filtering.

## Prerequisites

- Linux kernel 4.18 or newer
- Go 1.21 or newer
- clang
- llvm
- libbpf development files
- Linux kernel headers

### Debian/Ubuntu

```bash
sudo apt update
sudo apt install -y build-essential clang llvm libelf-dev linux-headers-"$(uname -r)" golang
```

### Fedora

```bash
sudo dnf install -y clang llvm libbpf libbpf-devel kernel-headers golang make
```

### Arch Linux

```bash
sudo pacman -S --needed --noconfirm clang llvm libbpf go
sudo pacman -S --needed --noconfirm linux-headers  # if headers not already installed
```

## Project Structure

```
bin/            # Compiled binaries (e.g., bin/tcp-dropper)
bpf/            # eBPF C sources (kernel side)
cmd/
  tcp-dropper/  # Main CLI entrypoint and generated eBPF bindings
scripts/        # Helper scripts (build, etc.)
src/            # (Reserved) additional Go packages if/when needed
go.mod
go.sum
README.md
```

## Building

Preferred method is via the provided script which installs the `bpf2go` tool, generates eBPF bindings, and builds the binary:

```bash
./scripts/build.sh
```

If you prefer manual steps:

```bash
# Make sure Go's bin is in your PATH so bpf2go is available
export PATH="$(go env GOPATH)/bin:$PATH"

# Install the code generator
go install github.com/cilium/ebpf/cmd/bpf2go@latest

# Generate Go bindings for the CLI package
go generate ./cmd/tcp-dropper

# Build the Go binary (outputs to bin/)
go build -o ./bin/tcp-dropper ./cmd/tcp-dropper
```

## Usage

To drop TCP packets on port 4040 (default):

```bash
sudo ./bin/tcp-dropper -interface eth0 -port 4040
```

### Command Line Arguments

- `-port`: TCP port to block (default: 4040)
- `-interface`: Network interface to attach to (default: eth0)
- `-xdp-mode`: XDP attach mode: `auto` (default), `native`, `generic`, or `offload`

### Example: Blocking HTTP Traffic

To block HTTP traffic on port 80:

```bash
sudo ./bin/tcp-dropper -interface eth0 -port 80
```

## How It Works

The program consists of two main components:

1. **eBPF Program (`bpf/drop_tcp.bpf.c`)**: Runs in the kernel (XDP hook) and inspects each incoming packet. If the packet is a TCP packet with the target destination port, it drops the packet.

2. **Userspace Program (`main.go`)**: Uses the generated Go bindings from `bpf2go` (`bpf_bpf*.go`) to load the eBPF object into the kernel, configures it with the target port through a map, and attaches it to the specified network interface.

## Testing

To test the program:

1. Start the dropper on one terminal:
   ```bash
   sudo ./tcp-dropper -port 8080
   ```

2. In another terminal, try to connect to the blocked port:
   ```bash
   nc -zv localhost 8080
   ```
   This should fail with a connection refused or timeout error.

## Cleaning Up

To stop the program, press `Ctrl+C` in the terminal where it's running. This will detach the eBPF program from the network interface.

## Troubleshooting

- **C source files not allowed when not using cgo or SWIG**: Ensure there are no `.c` files in the repository root. The BPF C file lives only in `bpf/drop_tcp.bpf.c`. Generated files appear as `bpf_bpf*.go` and `bpf_bpf*.o` in the root.

- **`missing package, are you running via go generate?`**: Run `go generate ./...` from the repository root, or simply use `./build.sh` which does this for you.

- **`no required module provides package github.com/cilium/ebpf/cmd/bpf2go`**: Install the tool with `go install github.com/cilium/ebpf/cmd/bpf2go@latest` and ensure `$(go env GOPATH)/bin` is on your `PATH`.

- **Kernel headers not found**: Install kernel headers for your distro (see above distro-specific instructions). On Arch: `sudo pacman -S linux-headers`. On Ubuntu/Debian: `sudo apt install linux-headers-"$(uname -r)"`. On Fedora: `sudo dnf install kernel-headers`.

- **Permission errors when loading XDP**: You must run the binary with `sudo` or sufficient capabilities (e.g., `CAP_BPF`, `CAP_NET_ADMIN`). The README examples use `sudo`.

- **bpffs not mounted at `/sys/fs/bpf`**: The program pins maps under `/sys/fs/bpf/` and verifies bpffs is mounted. Mount it with:

  ```bash
  sudo mount -t bpf bpf /sys/fs/bpf
  ```

- **Native XDP not supported on interface**: Use generic mode explicitly:

  ```bash
  sudo ./bin/tcp-dropper -interface eth0 -port 4040 -xdp-mode generic
  ```
  In `auto` mode, the program attempts native first and falls back to generic automatically.
