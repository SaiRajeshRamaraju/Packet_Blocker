#!/usr/bin/env bash
set -euo pipefail

# CONFIG
PORT_ALLOW=${PORT_ALLOW:-4040}
PORT_BLOCK=${PORT_BLOCK:-8080}
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}

echo "===> Simple eBPF TCP Dropper Test"
echo "Port ALLOW: $PORT_ALLOW"
echo "Port BLOCK: $PORT_BLOCK"

# Create cgroup
sudo mkdir -p "$CGROUP_PATH"

echo "===> Step 1: Start nginx"
# Stop any existing nginx
sudo systemctl stop nginx 2>/dev/null || true

# Create simple nginx config
sudo tee /etc/nginx/nginx.conf.custom > /dev/null << EOF
user http;
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;
    
    server {
        listen $PORT_ALLOW;
        server_name localhost;
        location / {
            return 200 "Hello from nginx on port $PORT_ALLOW!\\n";
            add_header Content-Type text/plain;
        }
    }
    
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
echo "Starting nginx..."
sudo systemctl start nginx
sleep 2

# Check if nginx is running
if ! systemctl is-active --quiet nginx; then
    echo "ERROR: Nginx failed to start"
    exit 1
fi

echo "Nginx started successfully"

echo "===> Step 2: Check nginx processes"
ps aux | grep nginx | grep -v grep

echo "===> Step 3: Test baseline (without dropper)"
echo "Testing port $PORT_ALLOW:"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK:"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS" || echo "FAILED"

echo "===> Step 4: Start eBPF dropper"
sudo ./bin/dropper --cgroup "$CGROUP_PATH" --egress --port "$PORT_ALLOW" &
DROPPER_PID=$!
sleep 3

echo "===> Step 5: Add nginx to cgroup"
for pid in $(pgrep nginx); do
    echo "Adding PID $pid to cgroup"
    echo "$pid" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null
done

echo "===> Step 6: Test with dropper"
echo "Testing port $PORT_ALLOW (should work):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_ALLOW/" && echo "SUCCESS" || echo "FAILED"

echo "Testing port $PORT_BLOCK (should be blocked):"
curl -s --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" && echo "SUCCESS (UNEXPECTED)" || echo "FAILED (EXPECTED)"

echo "===> Step 7: Test with curl in cgroup"
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

# Cleanup
echo "===> Cleaning up..."
sudo kill "$DROPPER_PID" 2>/dev/null || true
sudo systemctl stop nginx 2>/dev/null || true
if [ -f /etc/nginx/nginx.conf.backup ]; then
    sudo cp /etc/nginx/nginx.conf.backup /etc/nginx/nginx.conf
fi 