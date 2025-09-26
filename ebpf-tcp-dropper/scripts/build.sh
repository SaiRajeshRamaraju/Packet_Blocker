#!/usr/bin/env bash

set -euo pipefail

# Always run from the repository root, regardless of where this script is invoked
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Install dependencies
if ! command -v clang &> /dev/null || ! command -v go &> /dev/null; then
    echo "Installing dependencies..."
    sudo pacman -S --needed --noconfirm --noscriptlet clang llvm libbpf go
fi

# Build the project
echo "Building eBPF TCP dropper..."

export GO111MODULE=on
go mod tidy

# Generate BPF code
echo "Generating BPF code..."
# Ensure bpf2go is available in PATH
go install github.com/cilium/ebpf/cmd/bpf2go@latest
export PATH="$(go env GOPATH)/bin:$PATH"
# Clean previously generated artifacts in cmd package
rm -f "${REPO_ROOT}/cmd/tcp-dropper/bpf_bpf"*.go "${REPO_ROOT}/cmd/tcp-dropper/bpf_bpf"*.o || true
# Run go:generate only for the cmd package which contains the generator
go generate ./cmd/tcp-dropper

# Build the Go binary
echo "Building Go binary..."
mkdir -p "${REPO_ROOT}/bin"
go build -o "${REPO_ROOT}/bin/tcp-dropper" ./cmd/tcp-dropper

echo ""
echo "Build successful! Run with: sudo ${REPO_ROOT}/bin/tcp-dropper -port <port> -interface <interface>"
echo "Example: sudo ${REPO_ROOT}/bin/tcp-dropper -port 4040 -interface eth0"
