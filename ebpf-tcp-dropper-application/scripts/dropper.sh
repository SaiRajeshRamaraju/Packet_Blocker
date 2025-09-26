#!/usr/bin/env bash
set -euo pipefail

# Orchestrates build, cgroup setup, attach, and optional command execution.
# Requires root for cgroup and eBPF attach operations.
#
# Usage examples:
#   sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --both --create --build
#   sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --egress --run "curl https://example.com" --create --auto-mount
#   sudo scripts/dropper.sh --cgroup /sys/fs/cgroup/myapp --ingress
#
# Flags:
#   --cgroup <path>     Target cgroup v2 path (required)
#   --ingress           Attach only ingress program
#   --egress            Attach only egress program
#   --both              Attach both (default if none of the above specified)
#   --run <cmd>         Run a command inside the cgroup while the dropper is attached
#   --iface <name>      Interface name to match (optional). If omitted, apply to all interfaces
#   --port <num>        TCP port to block (default 4040; 0 disables port filter)
#   --pid <pid>         Add this PID to the cgroup before attaching
#   --proc <name>       Find first PID by process name and add it to the cgroup before attaching
#   --create            Create the cgroup directory if missing
#   --auto-mount        Auto-mount cgroup2 on /sys/fs/cgroup if not mounted
#   --build             Force rebuild (go generate + go build)
#   --no-build          Skip build even if bin/dropper is missing (not recommended)
#   -h|--help           Show help

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BIN_DIR="$ROOT_DIR/bin"
DROPPER_BIN="$BIN_DIR/dropper"

usage() {
  cat <<USAGE
Usage: $(basename "$0") --cgroup <path> [--ingress|--egress|--both] [--run <cmd>] [--create] [--auto-mount] [--build|--no-build]

Examples:
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --both --create --build
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --egress --run "curl https://example.com" --create --auto-mount
  sudo $(basename "$0") --cgroup /sys/fs/cgroup/myapp --ingress
USAGE
}

CGROUP_PATH=""
DIR_MODE="both" # ingress|egress|both
RUN_CMD=""
IFACE_NAME=""
PORT_OPT=()
PID_OPT=()
PROC_OPT=()
CREATE=0
AUTO_MOUNT=0
FORCE_BUILD=0
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cgroup) CGROUP_PATH=${2:-}; shift 2 ;;
    --ingress) DIR_MODE="ingress"; shift ;;
    --egress) DIR_MODE="egress"; shift ;;
    --both) DIR_MODE="both"; shift ;;
    --run) RUN_CMD=${2:-}; shift 2 ;;
    --iface) IFACE_NAME=${2:-}; shift 2 ;;
    --port) PORT_OPT=(--port "${2:-}"); shift 2 ;;
    --pid) PID_OPT=(--pid "${2:-}"); shift 2 ;;
    --proc) PROC_OPT=(--proc "${2:-}"); shift 2 ;;
    --create) CREATE=1; shift ;;
    --auto-mount) AUTO_MOUNT=1; shift ;;
    --build) FORCE_BUILD=1; shift ;;
    --no-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$CGROUP_PATH" ]]; then
  echo "--cgroup path is required" >&2
  usage
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (required for cgroup + eBPF attach)" >&2
  exit 1
fi

# Ensure cgroup v2 is mounted
if ! grep -q " - cgroup2 " /proc/self/mountinfo; then
  if [[ $AUTO_MOUNT -eq 1 ]]; then
    echo "[info] cgroup v2 not mounted; mounting on /sys/fs/cgroup"
    mount -t cgroup2 none /sys/fs/cgroup
  else
    echo "cgroup v2 not mounted; re-run with --auto-mount or mount manually (mount -t cgroup2 none /sys/fs/cgroup)" >&2
    exit 1
  fi
fi

# Create cgroup if requested
if [[ ! -d "$CGROUP_PATH" ]]; then
  if [[ $CREATE -eq 1 ]]; then
    echo "[info] creating cgroup: $CGROUP_PATH"
    mkdir -p "$CGROUP_PATH"
  else
    echo "cgroup path does not exist: $CGROUP_PATH (use --create to create it)" >&2
    exit 1
  fi
fi

# Build if needed
need_build=0
if [[ ! -x "$DROPPER_BIN" ]]; then
  need_build=1
fi
if [[ $FORCE_BUILD -eq 1 ]]; then
  need_build=1
fi
if [[ $SKIP_BUILD -eq 1 ]]; then
  need_build=0
fi

if [[ $need_build -eq 1 ]]; then
  if [[ $SKIP_BUILD -eq 1 ]]; then
    echo "[warn] --no-build specified but dropper binary missing; continuing may fail" >&2
  else
    echo "[build] running scripts/build.sh"
    "$ROOT_DIR/scripts/build.sh"
  fi
fi

if [[ ! -x "$DROPPER_BIN" ]]; then
  echo "dropper binary not found at $DROPPER_BIN (build failed or skipped)" >&2
  exit 1
fi

# Determine flag for direction
attach_flag="--both"
case "$DIR_MODE" in
  ingress) attach_flag="--ingress" ;;
  egress) attach_flag="--egress" ;;
  both) attach_flag="--both" ;;
  *) echo "invalid direction: $DIR_MODE" >&2; exit 1 ;;

esac

# When a run command is provided, we attach in background, run the command in the cgroup, then detach.
if [[ -n "$RUN_CMD" ]]; then
  echo "[attach] $DROPPER_BIN --cgroup $CGROUP_PATH $attach_flag${IFACE_NAME:+ --iface $IFACE_NAME} ${PORT_OPT[*]} ${PID_OPT[*]} ${PROC_OPT[*]}"
  if [[ -n "$IFACE_NAME" ]]; then
    "$DROPPER_BIN" --cgroup "$CGROUP_PATH" "$attach_flag" --iface "$IFACE_NAME" ${PORT_OPT[@]} ${PID_OPT[@]} ${PROC_OPT[@]} &
  else
    "$DROPPER_BIN" --cgroup "$CGROUP_PATH" "$attach_flag" ${PORT_OPT[@]} ${PID_OPT[@]} ${PROC_OPT[@]} &
  fi
  DROPPER_PID=$!

  cleanup() {
    if kill -0 "$DROPPER_PID" 2>/dev/null; then
      echo "[cleanup] detaching dropper (sending SIGINT)"
      kill -INT "$DROPPER_PID" || true
      wait "$DROPPER_PID" || true
    fi
  }
  trap cleanup EXIT INT TERM

  echo "[run] executing inside cgroup: $RUN_CMD"
  # Use helper to place this process in the cgroup and exec the command
  "$ROOT_DIR/scripts/run_in_cgroup.sh" "$CGROUP_PATH" bash -lc "$RUN_CMD"
  # After the command exits, trap will clean up the dropper
else
  # No command to run; execute dropper in foreground (Ctrl-C to detach)
  echo "[attach] executing dropper in foreground; press Ctrl-C to detach"
  if [[ -n "$IFACE_NAME" ]]; then
    exec "$DROPPER_BIN" --cgroup "$CGROUP_PATH" "$attach_flag" --iface "$IFACE_NAME" ${PORT_OPT[@]} ${PID_OPT[@]} ${PROC_OPT[@]}
  else
    exec "$DROPPER_BIN" --cgroup "$CGROUP_PATH" "$attach_flag" ${PORT_OPT[@]} ${PID_OPT[@]} ${PROC_OPT[@]}
  fi
fi
