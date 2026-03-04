#!/bin/sh
if [ -f /etc/openclaw/openclaw.json ]; then
  cp /etc/openclaw/openclaw.json /home/openclaw/.openclaw/openclaw.json
fi

# Start gateway in background
openclaw gateway --port 3000 --bind lan &
GATEWAY_PID=$!

# Wait for gateway to be ready
sleep 10

# Keep approving pending device requests as they come in
while true; do
  openclaw devices approve --latest --token "$OPENCLAW_GATEWAY_TOKEN" 2>/dev/null || true
  sleep 5
done &

# Wait for gateway process
wait $GATEWAY_PID
