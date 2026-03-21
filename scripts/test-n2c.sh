#!/bin/bash
set -e
cd "$(dirname "$0")/.."
rm -f kassadin.socket

# Start kassadin in background
./zig-out/bin/kassadin sync --network preprod \
  --shelley-genesis config/preprod/shelley.json \
  --byron-genesis config/preprod/byron.json \
  --socket-path kassadin.socket > /tmp/kassadin-n2c-test.log 2>&1 &
KPID=$!
trap "kill -INT $KPID 2>/dev/null; wait $KPID 2>/dev/null" EXIT

# Wait for socket
for i in $(seq 1 30); do
    [ -S kassadin.socket ] && break
    sleep 1
done

if [ ! -S kassadin.socket ]; then
    echo "FAIL: socket never appeared"
    exit 1
fi

sleep 3

echo "=== cardano-cli output ==="
./cardano-cli-native query tip --socket-path ./kassadin.socket --testnet-magic 1 2>&1
CLI_EXIT=$?
echo "=== exit code: $CLI_EXIT ==="

echo ""
echo "=== kassadin N2C log ==="
grep -E "N2C|query|→" /tmp/kassadin-n2c-test.log | tail -20

exit $CLI_EXIT
