#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <cgroup_path> <command> [args...]" >&2
  exit 1
fi

CGROUP_PATH=$1
shift

if [[ ! -d "$CGROUP_PATH" ]]; then
  echo "cgroup path does not exist: $CGROUP_PATH" >&2
  exit 1
fi

# Add current shell to the cgroup and exec the command
# This ensures all children inherit the cgroup membership
if [[ $EUID -ne 0 ]]; then
  echo "This script requires root to write to cgroup.procs" >&2
  exit 1
fi

echo $$ >"$CGROUP_PATH/cgroup.procs"
exec "$@"
