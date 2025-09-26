#!/usr/bin/env bash
set -euo pipefail

# CONFIG - Complete test
PORT_ALLOW=${PORT_ALLOW:-4040}
PORT_BLOCK=${PORT_BLOCK:-8080}
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}

echo "===> COMPLETE eBPF TCP Dropper Test"
echo "Port ALLOW: $PORT_ALLOW"
echo "Port BLOCK: $PORT_BLOCK"
echo "Cgroup: $CGROUP_PATH"

# Create cgroup
sudo mkdir -p "$CGROUP_PATH"

echo "===> Step 1: Start nginx with our configuration"
# Stop any existing nginx
sudo systemctl stop nginx 2>/dev/null || true

# Create nginx configuration
sudo tee /etc/nginx/nginx.conf.custom > /dev/null << EOF
user http;
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;
    
    # Server for allowed port
    server {
        listen $PORT_ALLOW;
        server_name localhost;
        
        location / {
            return 200 "Hello from nginx on port $PORT_ALLOW!\\n";
            add_header Content-Type text/plain;
        }
    }
    
    # Server for blocked port
    server {
        listen $PORT_BLOCK;
        server_name localhost;
        
        location / {
            return 200 "Hello from nginx on port $PORT_BLOCK!\\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF

# Backup and use our config
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null || true
sudo cp /etc/nginx/nginx.conf.custom /etc/nginx/nginx.conf

# Start nginx
sudo systemctl start nginx
sleep 2

echo "===> Step 2: Check nginx processes"
echo "All nginx processes:"
ps aux | grep nginx | grep -v grep

echo "===> Step 3: Test baseline (without dropper)"
echo "Testing port $PORT_ALLOW (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS" || echo "FAILED"

echo "===> Step 4: Start eBPF dropper"
sudo ./bin/dropper --cgroup "$CGROUP_PATH" --egress --port "$PORT_ALLOW" &
DROPPER_PID=$!
sleep 3

echo "===> Step 5: Add nginx processes to cgroup"
echo "Adding all nginx processes to cgroup:"
for pid in $(pgrep nginx); do
    echo "Adding PID $pid to cgroup"
    echo "$pid" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null
done

echo "===> Step 6: Check cgroup contents"
echo "Processes in cgroup:"
sudo cat "$CGROUP_PATH/cgroup.procs"

echo "===> Step 7: Test with dropper active"
echo "Testing port $PORT_ALLOW (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK (should be blocked):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS (UNEXPECTED)" || echo "FAILED (EXPECTED)"

echo "===> Step 8: Test with curl in cgroup"
echo "Testing curl in cgroup (should be blocked on port $PORT_BLOCK):"
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

echo "===> Step 9: Check eBPF program status"
echo "Checking if eBPF program is loaded:"
sudo bpftool prog show | grep -i cgroup || echo "No cgroup programs found"

echo "===> Step 10: Check dropper status"
echo "Dropper PID: $DROPPER_PID"
ps aux | grep dropper | grep -v grep

# Cleanup
echo "===> Cleaning up..."
sudo kill "$DROPPER_PID" 2>/dev/null || true
sudo systemctl stop nginx 2>/dev/null || true
if [ -f /etc/nginx/nginx.conf.backup ]; then
    sudo cp /etc/nginx/nginx.conf.backup /etc/nginx/nginx.conf
fi 