#!/usr/bin/env bash
set -euo pipefail

# CONFIG - Debug test
PORT_ALLOW=${PORT_ALLOW:-4040}
PORT_BLOCK=${PORT_BLOCK:-8080}
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}

echo "===> DEBUG: eBPF TCP Dropper Test"
echo "Port ALLOW: $PORT_ALLOW"
echo "Port BLOCK: $PORT_BLOCK"
echo "Cgroup: $CGROUP_PATH"

# Create cgroup
sudo mkdir -p "$CGROUP_PATH"

echo "===> Step 1: Check nginx processes"
echo "All nginx processes:"
ps aux | grep nginx | grep -v grep

echo "===> Step 2: Start dropper and add ALL nginx processes to cgroup"
sudo ./bin/dropper --cgroup "$CGROUP_PATH" --egress --port "$PORT_ALLOW" &
DROPPER_PID=$!
sleep 3

# Add ALL nginx processes to cgroup
echo "Adding all nginx processes to cgroup:"
for pid in $(pgrep nginx); do
    echo "Adding PID $pid to cgroup"
    echo "$pid" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null
done

echo "===> Step 3: Check cgroup contents"
echo "Processes in cgroup:"
sudo cat "$CGROUP_PATH/cgroup.procs"

echo "===> Step 4: Test traffic blocking"
echo "Testing port $PORT_ALLOW (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK (should be blocked):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS (UNEXPECTED)" || echo "FAILED (EXPECTED)"

echo "===> Step 5: Check eBPF program status"
echo "Checking if eBPF program is loaded:"
sudo bpftool prog show | grep -i cgroup || echo "No cgroup programs found"

echo "===> Step 6: Test with a simple process"
echo "Testing with a simple curl process in cgroup:"
if ! sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_ALLOW" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 http://127.0.0.1:$PORT_BLOCK/'" 2>&1; then
    echo "Curl in cgroup was blocked as expected"
else
    echo "Curl in cgroup was NOT blocked (unexpected)"
fi

echo "===> Step 7: Check if dropper is actually running"
echo "Dropper PID: $DROPPER_PID"
ps aux | grep dropper | grep -v grep

echo "===> Step 8: Test with a different approach - restart nginx in cgroup"
echo "Stopping nginx..."
sudo systemctl stop nginx

echo "Starting nginx in cgroup..."
# Start nginx directly in the cgroup
sudo scripts/run_in_cgroup.sh "$CGROUP_PATH" nginx -g "daemon off;" &
NGINX_IN_CGROUP_PID=$!
sleep 2

echo "Testing with nginx started in cgroup:"
echo "Testing port $PORT_ALLOW (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK (should be blocked):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS (UNEXPECTED)" || echo "FAILED (EXPECTED)"

# Cleanup
sudo kill "$DROPPER_PID" 2>/dev/null || true
sudo kill "$NGINX_IN_CGROUP_PID" 2>/dev/null || true 