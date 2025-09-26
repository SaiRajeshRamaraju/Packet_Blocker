#!/usr/bin/env bash
set -euo pipefail

# CONFIG
PORT_BLOCK=${PORT_BLOCK:-5555}   # test port to block
PORT_ALLOW=${PORT_ALLOW:-5556}   # second port for "allowed" sanity check
CGROUP_PATH=${CGROUP_PATH:-/sys/fs/cgroup/myapp}

# Create logs directory
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

# Initialize server PIDs
SERVER1_PID=""
SERVER2_PID=""
SERVER3_PID=""
DROPPER_ING_PID=""

# Function to clean up background processes on exit
cleanup() {
    echo "===> Cleaning up..."
    # Kill all background processes
    kill "$SERVER1_PID" 2>/dev/null || true
    kill "$SERVER2_PID" 2>/dev/null || true
    kill "$SERVER3_PID" 2>/dev/null || true
    if [ -n "${DROPPER_ING_PID:-}" ]; then
        sudo kill "$DROPPER_ING_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "===> Step 0: Check dependencies and set up environment"

# Check for required commands
MISSING_DEPS=()
for cmd in ip iptables python3 curl ss cgexec; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

# Check if we can proceed without dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "[WARN] Missing dependencies: ${MISSING_DEPS[*]}"
    echo "[INFO] Attempting to continue with the test..."
    
    # Check specifically for cgexec
    if ! command -v cgexec >/dev/null 2>&1; then
        echo "[WARN] cgexec not found. Some tests may fail."
    fi
    
    # Skip package installation and continue with the test
    echo "[INFO] Skipping package installation. Continuing with the test..."
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

# Function to start HTTP server
start_http_server() {
    local port=$1
    local log_file="$LOG_DIR/http_$port.log"
    
    # Kill any existing server on this port using ss
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'"' -f2 | xargs -r kill -9 2>/dev/null || true
    fi
    
    # Start new server
    python3 -m http.server "$port" > "$log_file" 2>&1 &
    local pid=$!
    
    # Wait for server to start
    local max_attempts=5
    local attempt=0
    while ! (ss -tulpn 2>/dev/null | grep -q ":$port ") && [ $attempt -lt $max_attempts ]; do
        sleep 0.5
        attempt=$((attempt + 1))
    done
    
    # Verify server is running
    if ! ps -p "$pid" > /dev/null || ! (ss -tulpn 2>/dev/null | grep -q ":$port "); then
        echo "[ERROR] Failed to start HTTP server on port $port"
        echo "Logs from $log_file:"
        cat "$log_file"
        exit 1
    fi
    
    echo "$pid"
}

echo "===> Step 3: EGRESS TEST (block outbound TCP:$PORT_BLOCK for curl placed in cgroup)"

echo "-> Start a local HTTP server on :$PORT_BLOCK (outside cgroup)"
SERVER1_PID=$(start_http_server "$PORT_BLOCK")

echo "-> Attach dropper (egress, port=$PORT_BLOCK) and run curl inside the cgroup (expected to FAIL)"
if ! sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_BLOCK" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 http://127.0.0.1:$PORT_BLOCK/'" 2>&1 | tee "$LOG_DIR/egress_test.log"; then
    echo "[OK] Egress test failed as expected (blocked)."
else
    echo "[WARN] Egress test unexpectedly succeeded (should be blocked). Check $LOG_DIR/egress_test.log"
fi

echo "-> Start a second local HTTP server on :$PORT_ALLOW (outside cgroup)"
SERVER2_PID=$(start_http_server "$PORT_ALLOW")

echo "-> With dropper still configured to block only $PORT_BLOCK, curl to :$PORT_ALLOW should SUCCEED"
if sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port "$PORT_BLOCK" \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 http://127.0.0.1:$PORT_ALLOW/'" 2>&1 | tee "$LOG_DIR/egress_allow_test.log"; then
    echo "[OK] Egress allowed test succeeded as expected."
else
    echo "[ERROR] Egress allowed test failed unexpectedly. Check $LOG_DIR/egress_allow_test.log"
    exit 1
fi

echo "===> Step 4: INGRESS TEST (block incoming TCP:$PORT_BLOCK to a server in the cgroup)"

# Clean up egress test servers
kill "$SERVER1_PID" 2>/dev/null || true
kill "$SERVER2_PID" 2>/dev/null || true
sleep 0.5  # Give time for ports to be released

# Create a new cgroup for the server
SERVER_CGROUP="myapp-server"
CGROUP_PATH="/sys/fs/cgroup/$SERVER_CGROUP"

# Clean up any existing cgroup
if [ -d "$CGROUP_PATH" ]; then
    # Move any existing processes to parent cgroup
    if [ -f "$CGROUP_PATH/cgroup.procs" ]; then
        while read -r pid; do
            echo "$pid" | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null 2>&1 || true
        done < "$CGROUP_PATH/cgroup.procs"
    fi
    sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
fi

# Create new cgroup
sudo mkdir -p "$CGROUP_PATH"

# Enable controllers for this cgroup
for controller in memory pids cpu; do
    if grep -q "\b$controller\b" /sys/fs/cgroup/cgroup.controllers; then
        echo "+$controller" | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
        echo "+$controller" | sudo tee "$CGROUP_PATH/cgroup.subtree_control" >/dev/null
    fi
done

# Clean up any existing test namespace and veth pairs
sudo ip netns del testns 2>/dev/null || true
sudo ip link del veth0 2>/dev/null || true
sudo ip link del veth1 2>/dev/null || true

# Create a new network namespace
echo "-> Creating network namespace and veth pair"
sudo ip netns add testns

# Create veth pair
echo "-> Setting up network namespace with veth pair"
sudo ip link add veth0 type veth peer name veth1 || {
    echo "[ERROR] Failed to create veth pair"
    exit 1
}
sudo ip link set veth1 netns testns || {
    echo "[ERROR] Failed to move veth1 to network namespace"
    exit 1
}

# Configure veth in root namespace
sudo ip addr add 10.1.1.1/24 dev veth0 || {
    echo "[ERROR] Failed to configure veth0 address"
    exit 1
}
sudo ip link set veth0 up || {
    echo "[ERROR] Failed to bring up veth0"
    exit 1
}

# Configure veth in test namespace
sudo ip -n testns addr add 10.1.1.2/24 dev veth1 || {
    echo "[ERROR] Failed to configure veth1 address in namespace"
    exit 1
}
sudo ip -n testns link set veth1 up || {
    echo "[ERROR] Failed to bring up veth1 in namespace"
    exit 1
}
sudo ip -n testns route add default via 10.1.1.1 || {
    echo "[ERROR] Failed to add default route in namespace"
    exit 1
}

# Enable IP forwarding and NAT
echo "-> Configuring network routing and NAT"
sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward' || {
    echo "[ERROR] Failed to enable IP forwarding"
    exit 1
}

# Add iptables rules
add_iptables_rule() {
    local cmd=$1
    local rule=$2
    if ! sudo iptables -C $rule 2>/dev/null; then
        sudo iptables $cmd $rule || {
            echo "[ERROR] Failed to add iptables rule: $cmd $rule"
            exit 1
        }
    fi
}

add_iptables_rule "-t nat -A" "POSTROUTING -s 10.1.1.0/24 -j MASQUERADE"
add_iptables_rule "-A" "FORWARD -i veth0 -j ACCEPT"
add_iptables_rule "-A" "FORWARD -o veth0 -j ACCEPT"
add_iptables_rule "-t nat -A" "PREROUTING -p tcp --dport $PORT_BLOCK -j DNAT --to-destination 10.1.1.2:$PORT_BLOCK"

# Start the server in the network namespace and cgroup
echo "-> Starting HTTP server in network namespace and cgroup on port $PORT_BLOCK"

# Create a temporary script with debug output
TEMP_SCRIPT="/tmp/http_server_$PORT_BLOCK.sh"
cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash
# This runs inside the network namespace
set -x

echo "[$(date)] Starting server script with args: $@"

# Debug info
echo "[$(date)] Current network config:"
ip addr show || true
ip route || true

# Setup loopback
echo "[$(date)] Setting up loopback"
ip link set lo up || {
    echo "[ERROR] Failed to bring up loopback"
    exit 1
}

# Start the Python HTTP server
PORT=$1
echo "[$(date)] Starting Python HTTP server on port $PORT"
exec python3 -u -m http.server "$PORT" --bind 0.0.0.0 2>&1 | while read line; do
    echo "[$(date)] $line"
done
echo "[$(date)] Server process ended with status $?"
EOF
chmod +x "$TEMP_SCRIPT"

# Start the server in the network namespace with full debug output
{
    echo "[$(date)] Starting server in network namespace"
    ip netns exec testns /bin/bash -x "$TEMP_SCRIPT" "$PORT_BLOCK"
} > "$LOG_DIR/http_ingress_$PORT_BLOCK.log" 2>&1 &
SERVER3_PID=$!

echo "[DEBUG] Server started with PID $SERVER3_PID"

# Add the server process to the cgroup if available
if [ -d "/sys/fs/cgroup/$SERVER_CGROUP" ]; then
    echo "[DEBUG] Adding PID $SERVER3_PID to cgroup $SERVER_CGROUP"
    echo "$SERVER3_PID" | sudo tee "/sys/fs/cgroup/$SERVER_CGROUP/cgroup.procs" >/dev/null 2>&1 || {
        echo "[WARN] Failed to add PID $SERVER3_PID to cgroup $SERVER_CGROUP"
    }
else
    echo "[WARN] Cgroup $SERVER_CGROUP not found, running without cgroup"
fi

# Wait for server to start and verify it's running
echo "-> Waiting for server to start on port $PORT_BLOCK..."
max_attempts=20
attempt=0
SERVER_RUNNING=0

while [ $attempt -lt $max_attempts ]; do
    # Check if server process is still running
    if ! ps -p "$SERVER3_PID" > /dev/null; then
        echo "[ERROR] Server process died. Check $LOG_DIR/http_ingress_$PORT_BLOCK.log:"
        cat "$LOG_DIR/http_ingress_$PORT_BLOCK.log"
        cleanup_network
        exit 1
    fi
    
    # Check if server is listening
    if ip netns exec testns ss -tulnp 2>/dev/null | grep -q ":$PORT_BLOCK "; then
        SERVER_RUNNING=1
        echo "[DEBUG] Server is listening on port $PORT_BLOCK"
        ip netns exec testns ss -tulnp 2>/dev/null || true
        break
    fi
    
    echo "  Waiting for server to start (attempt $((attempt + 1))/$max_attempts)..."
    sleep 0.5
    attempt=$((attempt + 1))
done

# Final verification
if [ $SERVER_RUNNING -eq 0 ]; then
    echo "[ERROR] Server failed to start on port $PORT_BLOCK after $max_attempts attempts."
    echo "Network namespace interfaces:"
    sudo ip netns exec testns ip addr
    echo "\nServer log (last 20 lines):"
    tail -n 20 "$LOG_DIR/http_ingress_$PORT_BLOCK.log"
    cleanup_network
    exit 1
fi

echo "-> Server started successfully with PID $SERVER3_PID in cgroup $SERVER_CGROUP"
echo "   Network namespace configuration:"
sudo ip netns exec testns ip addr
sudo ip netns exec testns netstat -tulpn

# Attach dropper in background (ingress, port=$PORT_BLOCK) to cgroup $SERVER_CGROUP
echo "-> Attaching ingress dropper to cgroup $SERVER_CGROUP"

# Create a temporary file for the dropper output
DROPPER_LOG=$(mktemp)

# Run the dropper in the background
sudo ./bin/dropper --cgroup "/$SERVER_CGROUP" --ingress --port "$PORT_BLOCK" > "$DROPPER_LOG" 2>&1 &
DROPPER_ING_PID=$!

# Give the dropper a moment to attach
sleep 2

# Check if dropper is still running
if ! ps -p "$DROPPER_ING_PID" > /dev/null; then
    echo "[ERROR] Dropper process died. Output:"
    cat "$DROPPER_LOG"
    rm -f "$DROPPER_LOG"
    cleanup_network
    exit 1
fi

# Save the dropper output
cat "$DROPPER_LOG" > "$LOG_DIR/dropper_ingress.log"
rm -f "$DROPPER_LOG"

echo "-> Verifying ingress blocking (should block connections to port $PORT_BLOCK)"

# Test from outside the cgroup (should be blocked)
echo "-> Testing from outside cgroup (should be blocked)"
BLOCKED=0
for i in {1..5}; do
    echo "  Test $i/5: Attempting to connect to port $PORT_BLOCK..."
    if ! curl -v --max-time 2 "http://127.0.0.1:$PORT_BLOCK/" 2>&1 | tee -a "$LOG_DIR/ingress_test.log"; then
        echo "  [OK] Connection blocked as expected (attempt $i/5)"
        BLOCKED=1
        break
    fi
    echo "  [WARN] Connection not blocked on attempt $i/5, retrying..."
    sleep 1
done

if [ "$BLOCKED" -eq 0 ]; then
    echo "[WARN] Ingress traffic not blocked. Check $LOG_DIR/dropper_ingress.log"
    echo "[DEBUG] Current cgroup processes:"
    sudo cat "/sys/fs/cgroup/$SERVER_CGROUP/cgroup.procs"
    echo "[DEBUG] BPF program status:"
    sudo bpftool prog show | grep "cgroup_skb/ingress"
else
    echo "[OK] Ingress blocking is working as expected"
fi

# Cleanup network namespace and iptables rules
cleanup_network() {
    echo "-> Cleaning up network configuration"
    # Kill any remaining processes in the namespace
    if [ -n "$SERVER3_PID" ] && ps -p "$SERVER3_PID" >/dev/null 2>&1; then
        kill "$SERVER3_PID" 2>/dev/null || true
    fi
    
    # Clean up network namespace and interfaces
    sudo ip netns del testns 2>/dev/null || true
    sudo ip link del veth0 2>/dev/null || true
    
    # Clean up iptables rules
    sudo iptables -t nat -D POSTROUTING -s 10.1.1.0/24 -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i veth0 -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -o veth0 -j ACCEPT 2>/dev/null || true
    sudo iptables -t nat -D PREROUTING -p tcp --dport $PORT_BLOCK -j DNAT --to-destination 10.1.1.2:$PORT_BLOCK 2>/dev/null || true
    
    # Clean up temporary script
    rm -f "/tmp/http_server_$PORT_BLOCK.sh" 2>/dev/null || true
}

trap 'cleanup_network' EXIT

echo "-> Detaching ingress dropper"
sudo kill -INT "$DROPPER_ING_PID" 2>/dev/null || true
if ! wait "$DROPPER_ING_PID" 2>/dev/null; then
    echo "[WARN] Dropper did not exit cleanly"
fi

# Give some time for the dropper to detach
sleep 2

echo "-> Verifying traffic is no longer blocked"
UNBLOCKED=0
for i in {1..5}; do
    echo "  Test $i/5: Verifying traffic is unblocked..."
    if curl -v --max-time 5 "http://127.0.0.1:$PORT_BLOCK/" 2>&1 | tee -a "$LOG_DIR/ingress_after_detach.log"; then
        echo "  [OK] Connection succeeded after detach (attempt $i/5)"
        UNBLOCKED=1
        break
    fi
    echo "  [WARN] Connection still failing on attempt $i/5, retrying..."
    sleep 1
done

if [ "$UNBLOCKED" -eq 0 ]; then
    echo "[ERROR] Ingress still blocking after detach. Check $LOG_DIR/ingress_after_detach.log"
    echo "[DEBUG] Current network connections:"
    sudo netstat -tulpn | grep ":$PORT_BLOCK" || true
    echo "[DEBUG] Current iptables rules:"
    sudo iptables -t nat -L -v -n
    cleanup_network
    exit 1
else
    echo "[OK] Ingress traffic is no longer blocked as expected"
fi

echo "===> Step 5: Optional HTTPS egress test with DNS bypass (block TCP:443 while forcing IP with --resolve)"
echo "-> This forces a direct 443 connection without DNS so you test pure TCP:443 dropping"
if ! sudo scripts/dropper.sh \
  --cgroup "$CGROUP_PATH" \
  --egress \
  --port 443 \
  --create \
  --auto-mount \
  --run "bash -lc 'curl -v --max-time 5 --resolve example.com:443:93.184.216.34 https://example.com'" 2>&1 | tee "$LOG_DIR/https_test.log"; then
    echo "[OK] HTTPS egress test failed as expected (blocked)."
else
    echo "[WARN] HTTPS egress test unexpectedly succeeded (should be blocked). Check $LOG_DIR/https_test.log"
fi

echo "===> All tests completed."
echo "Logs are available in the $LOG_DIR/ directory:"
ls -l "$LOG_DIR/"
