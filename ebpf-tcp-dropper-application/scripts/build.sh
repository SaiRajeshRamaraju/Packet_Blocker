#!/usr/bin/env bash
set -euo pipefail

# Build script for eBPF cgroup dropper (Go + bpf2go)
# - Generates Go bindings from eBPF C sources via bpf2go
# - Builds the Go loader binary into ./bin/dropper
# - Optional: Orchestrates attach/run via scripts/dropper.sh when requested

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BIN_DIR="$ROOT_DIR/bin"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [build-options] [attach-options]

Build options:
  --clean                Remove built artifacts (bin/, generated bpf files) and exit
  --verbose              Enable verbose build output
  -h, --help             Show this help

Attach options (optional; if provided, will attach after build using scripts/dropper.sh):
  --cgroup <path>        Target cgroup v2 path (required to attach)
  --ingress              Attach only ingress program
  --egress               Attach only egress program
  --both                 Attach both (default if none of ingress/egress specified)
  --run <cmd>            Run a command inside the cgroup while attached
  --create               Create the cgroup directory if missing
  --auto-mount           Auto-mount cgroup2 on /sys/fs/cgroup if not mounted
  --iface <name>         Interface name to match (optional). If omitted, apply to all interfaces
  --port <num>           TCP port to block (default 4040; 0 disables port filter)
  --pid <pid>            Add this PID to the cgroup before attaching (mutually exclusive with --proc)
  --proc <name>          Find first PID by process name and add it to the cgroup (mutually exclusive with --pid)

Examples:
  $(basename "$0")
  $(basename "$0") --verbose
  $(basename "$0") --clean
  # Build and then attach both directions to a cgroup
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --both --create
  # Build, attach egress only, auto-mount cgroup v2, and run a test command
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --egress --auto-mount --create --run "curl https://example.com"
  # Build and attach to drop TCP :443 for a specific process name
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --both --port 443 --proc curl --create
USAGE
}

ROOT_DIR_SCRIPT="$ROOT_DIR/scripts/dropper.sh"

CLEAN=0
VERBOSE=0

# Orchestration defaults
CGROUP_PATH=""
DIR_MODE=""   # ingress|egress|both|""
RUN_CMD=""
IFACE_NAME=""
PORT_NUM=""
PID_VAL=""
PROC_NAME=""
CREATE=0
AUTO_MOUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    # build options
    --clean) CLEAN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    # attach options
    --cgroup) CGROUP_PATH=${2:-}; shift 2 ;;
    --ingress) DIR_MODE="ingress"; shift ;;
    --egress) DIR_MODE="egress"; shift ;;
    --both) DIR_MODE="both"; shift ;;
    --run) RUN_CMD=${2:-}; shift 2 ;;
    --iface) IFACE_NAME=${2:-}; shift 2 ;;
    --port) PORT_NUM=${2:-}; shift 2 ;;
    --pid) PID_VAL=${2:-}; shift 2 ;;
    --proc) PROC_NAME=${2:-}; shift 2 ;;
    --create) CREATE=1; shift ;;
    --auto-mount) AUTO_MOUNT=1; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# Validate mutually exclusive options
if [[ -n "$PID_VAL" && -n "$PROC_NAME" ]]; then
  echo "--pid and --proc are mutually exclusive; specify only one" >&2
  exit 1
fi

if [[ $CLEAN -eq 1 ]]; then
  echo "[clean] removing bin/ and generated bpf artifacts"
  rm -rf "$BIN_DIR"
  # Remove bpf2go-generated files (Dropper_*.go and compiled objects)
  find "$ROOT_DIR/bpf" -maxdepth 1 \
    -type f \( -name 'Dropper_*' -o -name '*.o' -o -name '*.skel.h' \) -print -delete || true
  exit 0
fi

# Checks
command -v go >/dev/null 2>&1 || { echo "Go toolchain not found (install Go 1.22+)" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "clang not found (required for bpf2go)" >&2; exit 1; }

mkdir -p "$BIN_DIR"

pushd "$ROOT_DIR" >/dev/null

# Generate eBPF bindings with bpf2go
if [[ $VERBOSE -eq 1 ]]; then
  echo "[generate] running: go generate ./bpf"
fi
GOFLAGS="" go generate ./bpf

# Build the Go loader
if [[ $VERBOSE -eq 1 ]]; then
  echo "[build] running: go build -o ./bin/dropper ./cmd/dropper"
fi
GOFLAGS="" go build -o ./bin/dropper ./cmd/dropper

popd >/dev/null

echo "[ok] built ./bin/dropper"

# If attach options were provided, chain to scripts/dropper.sh to attach/run
if [[ -n "$CGROUP_PATH" || -n "$DIR_MODE" || -n "$RUN_CMD" || $CREATE -eq 1 || $AUTO_MOUNT -eq 1 ]]; then
  if [[ ! -x "$ROOT_DIR_SCRIPT" ]]; then
    echo "dropper orchestration script not found or not executable: $ROOT_DIR_SCRIPT" >&2
    exit 1
  fi

  # Determine direction flag to pass
  attach_flag="--both"
  case "$DIR_MODE" in
    ingress) attach_flag="--ingress" ;;
    egress) attach_flag="--egress" ;;
    both) attach_flag="--both" ;;
    "") attach_flag="--both" ;;
    *) echo "invalid direction: $DIR_MODE" >&2; exit 1 ;;
  esac

  # Build command
  cmd=("$ROOT_DIR_SCRIPT" --no-build --cgroup "$CGROUP_PATH" "$attach_flag")
  [[ -n "$IFACE_NAME" ]] && cmd+=(--iface "$IFACE_NAME")
  [[ -n "$PORT_NUM" ]] && cmd+=(--port "$PORT_NUM")
  [[ -n "$PID_VAL" ]] && cmd+=(--pid "$PID_VAL")
  [[ -n "$PROC_NAME" ]] && cmd+=(--proc "$PROC_NAME")
  [[ $CREATE -eq 1 ]] && cmd+=(--create)
  [[ $AUTO_MOUNT -eq 1 ]] && cmd+=(--auto-mount)
  if [[ -n "$RUN_CMD" ]]; then
    cmd+=(--run "$RUN_CMD")
  fi

  echo "[attach] chaining to: ${cmd[*]}"
  exec "${cmd[@]}"
fi
