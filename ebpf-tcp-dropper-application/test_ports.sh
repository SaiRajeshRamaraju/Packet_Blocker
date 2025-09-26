#!/bin/bash

# Function to test port connection
test_port() {
    local port=$1
    local should_succeed=$2
    
    echo -n "Testing port $port (should be ${should_succeed:-blocked}): "
    
    # Use curl with a timeout of 2 seconds
    if curl -s -m 2 "http://localhost:$port" >/dev/null 2>&1; then
        if [ "$should_succeed" = "allowed" ]; then
            echo "✅ Success: Port $port is accessible"
        else
            echo "❌ Error: Port $port is accessible but should be blocked"
        fi
    else
        if [ "$should_succeed" = "allowed" ]; then
            echo "❌ Error: Could not connect to port $port (should be allowed)"
        else
            echo "✅ Success: Port $port is blocked as expected"
        fi
    fi
}

# Test port 4040 (should be allowed)
test_port 4040 "allowed"

# Test port 8080 (should be blocked)
test_port 8080 "blocked"
