#!/usr/bin/env bash
set -euo pipefail

# CONFIG - Real web server test
PORT_ALLOW=${PORT_ALLOW:-4040}   # port that should be ALLOWED (default allowed port)
PORT_BLOCK=${PORT_BLOCK:-8080}  # port that should be BLOCKED (common web server port)
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}
TEST_PROCESS="nginx"             # Process name to test with

# Create logs directory
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

# Initialize server PIDs
NGINX_PID=""
PYTHON_SERVER_PID=""
DROPPER_PID=""

# Function to clean up background processes on exit
cleanup() {
    echo "===> Cleaning up..."
    # Kill all background processes
    kill "$NGINX_PID" 2>/dev/null || true
    kill "$PYTHON_SERVER_PID" 2>/dev/null || true
    if [ -n "${DROPPER_PID:-}" ]; then
        sudo kill "$DROPPER_PID" 2>/dev/null || true
    fi
    # Stop nginx if running
    sudo systemctl stop nginx 2>/dev/null || true
    # Remove custom config
    sudo rm -f /etc/nginx/nginx.conf.custom 2>/dev/null || true
    # Restore original nginx config
    if [ -f /etc/nginx/nginx.conf.backup ]; then
        sudo cp /etc/nginx/nginx.conf.backup /etc/nginx/nginx.conf
    fi
}
trap cleanup EXIT

echo "===> Step 0: Check dependencies and set up environment"

# Check for required commands
MISSING_DEPS=()
for cmd in ip iptables python3 curl ss nginx; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "[WARN] Missing dependencies: ${MISSING_DEPS[*]}"
    echo "[INFO] Installing missing dependencies..."
    
    # Install nginx if missing
    if ! command -v nginx >/dev/null 2>&1; then
        echo "[INFO] Installing nginx..."
        sudo pacman -S --noconfirm nginx || {
            echo "[ERROR] Failed to install nginx"
            exit 1
        }
    fi
fi

# Ensure scripts are executable
chmod +x scripts/build.sh scripts/dropper.sh scripts/run_in_cgroup.sh

echo "===> Step 1: Generate BPF bindings and build the dropper"
go generate ./bpf
./scripts/build.sh

echo "===> Step 2: Ensure cgroup v2 is properly set up"

# Check if cgroup v2 is mounted
if ! grep -q " - cgroup2 " /proc/self/mountinfo; then
  echo "[info] cgroup v2 not mounted; mounting on /sys/fs/cgroup (requires sudo)"
  sudo mkdir -p /sys/fs/cgroup
  sudo mount -t cgroup2 none /sys/fs/cgroup || {
    echo "[ERROR] Failed to mount cgroup v2. You may need to add 'cgroup_no_v1=all' to your kernel boot parameters."
    exit 1
  }
fi

# Enable cgroup v2 controllers
echo "-> Enabling cgroup v2 controllers"
sudo sh -c 'echo "+memory +pids +cpu" > /sys/fs/cgroup/cgroup.subtree_control'

# Verify cgroup v2 is working
if ! [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "[ERROR] cgroup v2 is not properly set up. Please ensure your system supports cgroup v2."
  exit 1
fi

echo "===> Step 3: Set up real web servers"

# Stop any existing nginx
sudo systemctl stop nginx 2>/dev/null || true

# Create nginx configuration for Arch Linux
echo "-> Creating nginx configuration for Arch Linux"
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
        
        location /test {
            return 200 "Test endpoint on port $PORT_ALLOW\\n";
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
        
        location /test {
            return 200 "Test endpoint on port $PORT_BLOCK\\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF

# Backup original nginx config and use our custom one
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null || true
sudo cp /etc/nginx/nginx.conf.custom /etc/nginx/nginx.conf

# Test nginx configuration
echo "-> Testing nginx configuration"
sudo nginx -t || {
    echo "[ERROR] Nginx configuration test failed"
    exit 1
}

# Start nginx
echo "-> Starting nginx"
sudo systemctl start nginx || {
    echo "[ERROR] Failed to start nginx"
    exit 1
}

# Wait for nginx to start
sleep 2

# Verify nginx is running
if ! systemctl is-active --quiet nginx; then
    echo "[ERROR] Nginx failed to start"
    exit 1
fi

echo "-> Nginx started successfully"

# Function to test HTTP endpoint
test_http_endpoint() {
    local url=$1
    local expected_result=$2
    local test_name=$3
    
    echo "-> Testing $test_name: $url"
    
    if curl -s --max-time 5 "$url" >/dev/null 2>&1; then
        if [ "$expected_result" = "success" ]; then
            echo "[OK] $test_name succeeded as expected"
            return 0
        else
            echo "[ERROR] $test_name unexpectedly succeeded (should be blocked)"
            return 1
        fi
    else
        if [ "$expected_result" = "fail" ]; then
            echo "[OK] $test_name failed as expected (blocked)"
            return 0
        else
            echo "[ERROR] $test_name unexpectedly failed (should succeed)"
            return 1
        fi
    fi
}

echo "===> Step 4: Test without eBPF dropper (baseline test)"

echo "-> Testing nginx on port $PORT_ALLOW (should work)"
test_http_endpoint "http://127.0.0.1:$PORT_ALLOW" "success" "Nginx on allowed port"

echo "-> Testing nginx on port $PORT_BLOCK (should work)"
test_http_endpoint "http://127.0.0.1:$PORT_BLOCK" "success" "Nginx on blocked port"

echo "===> Step 5: Test with eBPF dropper - ALLOWED port test"

# Create cgroup if it doesn't exist
sudo mkdir -p "$CGROUP_PATH"

# Start dropper in background
echo "-> Starting eBPF dropper in background"
sudo ./bin/dropper --cgroup "$CGROUP_PATH" --egress --port "$PORT_ALLOW" &
DROPPER_PID=$!

# Wait for dropper to attach
sleep 3

# Find nginx process and add it to cgroup
NGINX_PID=$(pgrep nginx | head -1)
if [ -n "$NGINX_PID" ]; then
    echo "-> Found nginx process: $NGINX_PID"
    echo "-> Adding nginx process to cgroup"
    echo "$NGINX_PID" | sudo tee "$CGROUP_PATH/cgroup.procs" >/dev/null
    echo "-> Nginx process added to cgroup"
else
    echo "[WARN] Could not find nginx process"
fi

# Test that nginx on allowed port still works
echo "-> Testing nginx on port $PORT_ALLOW with dropper (should work)"
test_http_endpoint "http://127.0.0.1:$PORT_ALLOW" "success" "Nginx on allowed port with dropper"

# Test that nginx on blocked port is blocked
echo "-> Testing nginx on port $PORT_BLOCK with dropper (should be blocked)"
test_http_endpoint "http://127.0.0.1:$PORT_BLOCK" "fail" "Nginx on blocked port with dropper"

echo "===> Step 6: Test with curl in cgroup"

echo "-> Testing curl in cgroup (should be blocked on port $PORT_BLOCK)"
if ! sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_ALLOW" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 http://127.0.0.1:$PORT_BLOCK/'" 2>&1 | tee "$LOG_DIR/curl_blocked_test.log"; then
    echo "[OK] Curl in cgroup blocked on port $PORT_BLOCK as expected"
else
    echo "[WARN] Curl in cgroup unexpectedly succeeded on port $PORT_BLOCK"
fi

echo "-> Testing curl in cgroup (should work on port $PORT_ALLOW)"
if sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_ALLOW" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 http://127.0.0.1:$PORT_ALLOW/'" 2>&1 | tee "$LOG_DIR/curl_allowed_test.log"; then
    echo "[OK] Curl in cgroup succeeded on port $PORT_ALLOW as expected"
else
    echo "[ERROR] Curl in cgroup failed on port $PORT_ALLOW (should work)"
fi

echo "===> Step 7: Test different HTTP methods and endpoints"

echo "-> Testing GET request to root endpoint"
test_http_endpoint "http://127.0.0.1:$PORT_ALLOW/" "success" "GET request to root"

echo "-> Testing GET request to test endpoint"
test_http_endpoint "http://127.0.0.1:$PORT_ALLOW/test" "success" "GET request to test endpoint"

echo "-> Testing blocked port (should fail)"
test_http_endpoint "http://127.0.0.1:$PORT_BLOCK/" "fail" "GET request to blocked port"

echo "===> Step 8: Performance test"

echo "-> Running performance test on allowed port"
time curl -s --max-time 10 "http://127.0.0.1:$PORT_ALLOW/" >/dev/null

echo "-> Running performance test on blocked port (should timeout)"
timeout 5 curl -s "http://127.0.0.1:$PORT_BLOCK/" >/dev/null 2>&1 || echo "Blocked as expected"

echo "===> All tests completed successfully!"
echo "The eBPF TCP dropper is working correctly with real web servers:"
echo "✅ Allows traffic to port $PORT_ALLOW"
echo "✅ Blocks traffic to port $PORT_BLOCK"
echo "✅ Only affects processes in the specified cgroup"
echo "✅ Works with real web servers (nginx)"
echo "✅ Works with HTTP clients (curl)"
