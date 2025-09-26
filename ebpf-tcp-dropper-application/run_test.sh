#!/bin/bash

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to start a simple HTTP server on a given port
start_server() {
    local port=$1
    echo "Starting HTTP server on port $port..."
    python3 -m http.server $port >/dev/null 2>&1 &
    SERVER_PID=$!
    # Give the server a moment to start
    sleep 1
}

# Function to stop the HTTP server
stop_server() {
    if [ ! -z "$SERVER_PID" ]; then
        echo "Stopping HTTP server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
    fi
}

# Function to test a connection to a port
test_connection() {
    local port=$1
    local should_succeed=$2
    
    echo -n "Testing connection to port $port (should be ${should_succeed:-blocked}): "
    
    if curl -s -m 2 "http://localhost:$port" >/dev/null 2>&1; then
        if [ "$should_succeed" = "allowed" ]; then
            echo -e "${GREEN}✅ Success: Port $port is accessible${NC}"
        else
            echo -e "${RED}❌ Error: Port $port is accessible but should be blocked${NC}"
        fi
    else
        if [ "$should_succeed" = "allowed" ]; then
            echo -e "${RED}❌ Error: Could not connect to port $port (should be allowed)${NC}"
        else
            echo -e "${GREEN}✅ Success: Port $port is blocked as expected${NC}"
        fi
    fi
}

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    stop_server
    # Detach and unload BPF program if it was loaded
    if [ -f "/sys/fs/bpf/simple-port-filter" ]; then
        echo "Unloading BPF program..."
        sudo bpftool cgroup detach /sys/fs/cgroup/unified connect4 pinned /sys/fs/bpf/simple-port-filter 2>/dev/null || true
        sudo rm -f /sys/fs/bpf/simple-port-filter
    fi
}

# Set up trap to ensure cleanup happens on script exit
trap cleanup EXIT

# Start HTTP servers on both ports
echo "Starting test environment..."
start_server 4040
start_server 8080

# Compile the BPF program
echo -e "\nCompiling BPF program..."
make clean
if ! make; then
    echo -e "${RED}Failed to compile BPF program${NC}"
    exit 1
fi

# Load and attach the BPF program
echo -e "\nLoading BPF program..."
if ! sudo make load; then
    echo -e "${RED}Failed to load BPF program${NC}"
    exit 1
fi

if ! sudo make attach; then
    echo -e "${RED}Failed to attach BPF program to cgroup${NC}"
    exit 1
fi

# Wait a moment for BPF program to be fully attached
sleep 1

# Test connections
echo -e "\nTesting connections..."
test_connection 4040 "allowed"
test_connection 8080 "blocked"

echo -e "\nTest complete!"
