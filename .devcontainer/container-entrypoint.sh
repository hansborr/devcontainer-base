#!/usr/bin/env bash
# Wait for node_modules (postCreateCommand may still be running on first create)
MAX_WAIT=120  # 10 minutes (5s × 120)
count=0
while [ $count -lt $MAX_WAIT ]; do
  [ -d /workspace/node_modules ] && break
  sleep 5
  count=$((count + 1))
done

mkdir -p /workspace/logs

if [ -d /workspace/node_modules ]; then
  cd /workspace
  npm run dev >> /workspace/logs/dev-servers.log 2>&1 &
  echo "$(date -Iseconds): dev servers started (PID $!)" >> /workspace/logs/dev-servers.log
else
  echo "$(date -Iseconds): node_modules not found after $((MAX_WAIT * 5))s — servers not started" >> /workspace/logs/dev-servers.log
fi

exec sleep infinity
