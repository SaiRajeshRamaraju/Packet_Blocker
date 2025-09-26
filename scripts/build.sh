#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build.sh [options]

Build both droppers (XDP port blocker and cgroup application blocker).

Options:
  --port-only    Build only the XDP TCP port dropper
  --app-only     Build only the cgroup-based application dropper
  --verbose      Print every command that gets executed
  -h, --help     Show this help text

Examples:
  scripts/build.sh                 # build both binaries
  scripts/build.sh --port-only     # build only ./ebpf-tcp-dropper/bin/tcp-dropper
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_DIR="$ROOT_DIR/ebpf-tcp-dropper"
APP_DIR="$ROOT_DIR/ebpf-tcp-dropper-application"
BUILD_PORT=1
BUILD_APP=1
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port-only)
      BUILD_APP=0
      ;;
    --app-only)
      BUILD_PORT=0
      ;;
    --verbose)
      VERBOSE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $BUILD_PORT -eq 0 && $BUILD_APP -eq 0 ]]; then
  echo "Nothing to build: choose --port-only or --app-only (or neither for both)" >&2
  exit 1
fi

command -v go >/dev/null 2>&1 || { echo "Go toolchain not found in PATH" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "clang is required to compile eBPF programs" >&2; exit 1; }

if [[ $VERBOSE -eq 1 ]]; then
  set -x
fi

build_port() {
  pushd "$PORT_DIR" >/dev/null
  mkdir -p bin
  go generate ./cmd/tcp-dropper
  go build -o ./bin/tcp-dropper ./cmd/tcp-dropper
  popd >/dev/null
  echo "[ok] built tcp-dropper -> $PORT_DIR/bin/tcp-dropper"
}

build_app() {
  pushd "$APP_DIR" >/dev/null
  mkdir -p bin
  go generate ./bpf
  go build -o ./bin/dropper ./cmd/dropper
  popd >/dev/null
  echo "[ok] built dropper -> $APP_DIR/bin/dropper"
}

if [[ $BUILD_PORT -eq 1 ]]; then
  echo "[build] XDP TCP port dropper"
  build_port
fi

if [[ $BUILD_APP -eq 1 ]]; then
  echo "[build] Cgroup application dropper"
  build_app
fi

if [[ $VERBOSE -eq 1 ]]; then
  set +x
fi

cat <<'DONE'

Build complete. Binaries:
  - ebpf-tcp-dropper/bin/tcp-dropper
  - ebpf-tcp-dropper-application/bin/dropper
DONE
