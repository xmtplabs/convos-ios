#!/bin/bash
set -eou pipefail

# Start ngrok tunnels for CI testing
# Creates tunnels for the XMTP node port (5556)

echo "Starting ngrok tunnel for port 5556..."

# Create directory for tunnel info
mkdir -p tunnel-info

# Start ngrok tunnel for XMTP node (port 5556)
ngrok tcp 5556 --log=stdout --log-format=json > ngrok-5556.log 2>&1 &
echo $! > ngrok-5556.pid

# Wait for tunnel to be established
echo "Waiting for tunnel to be established..."
sleep 5

# Extract the tunnel URL from ngrok API
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    NODE_URL=$(curl -s http://localhost:4040/api/tunnels | jq -r '.tunnels[0].public_url' 2>/dev/null || echo "")

    if [ -n "$NODE_URL" ] && [ "$NODE_URL" != "null" ]; then
        # Extract host:port from tcp://host:port
        NODE_ADDRESS=$(echo "$NODE_URL" | sed 's|tcp://||')
        echo "$NODE_ADDRESS" > tunnel-info/node-url.txt
        echo "✅ Tunnel established: $NODE_ADDRESS"
        exit 0
    fi

    ATTEMPT=$((ATTEMPT + 1))
    echo "Attempt $ATTEMPT/$MAX_ATTEMPTS - waiting for tunnel..."
    sleep 2
done

echo "❌ Failed to establish tunnel"
cat ngrok-5556.log
exit 1
