#!/usr/bin/env bash
set -euo pipefail

PORT_ALLOW=${PORT_ALLOW:-4040}
PORT_BLOCK=${PORT_BLOCK:-8080}
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}

echo "===> FINAL TEST: eBPF TCP Dropper"
echo "Testing with processes in cgroup trying to connect to different ports"

# Create cgroup
sudo mkdir -p "$CGROUP_PATH"

# Start nginx
sudo systemctl start nginx 2>/dev/null || true
sleep 2

# Start dropper
sudo ./bin/dropper --cgroup "$CGROUP_PATH" --egress --port "$PORT_ALLOW" &
DROPPER_PID=$!
sleep 3

# Add nginx to cgroup
for pid in $(pgrep nginx); do
    echo "$pid" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null
done

echo "===> Test 1: Curl in cgroup to ALLOWED port (should work)"
if sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_ALLOW" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -s --max-time 5 http://127.0.0.1:$PORT_ALLOW/'" 2>&1; then
    echo "✅ SUCCESS: Curl in cgroup can connect to port $PORT_ALLOW"
else
    echo "❌ FAILED: Curl in cgroup cannot connect to port $PORT_ALLOW"
fi

echo "===> Test 2: Curl in cgroup to BLOCKED port (should fail)"
if ! sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_ALLOW" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -s --max-time 5 http://127.0.0.1:$PORT_BLOCK/'" 2>&1; then
    echo "✅ SUCCESS: Curl in cgroup is blocked from port $PORT_BLOCK"
else
    echo "❌ FAILED: Curl in cgroup can connect to port $PORT_BLOCK (should be blocked)"
fi

echo "===> Test 3: Curl OUTSIDE cgroup (should work on both ports)"
echo "Testing curl outside cgroup to port $PORT_ALLOW:"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "✅ SUCCESS" || echo "❌ FAILED"

echo "Testing curl outside cgroup to port $PORT_BLOCK:"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "✅ SUCCESS" || echo "❌ FAILED"

# Cleanup
sudo kill "$DROPPER_PID" 2>/dev/null || true 