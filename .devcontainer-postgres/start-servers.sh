#!/usr/bin/env bash
mkdir -p /workspace/logs
cd /workspace || exit 1
setsid nohup npm run dev >> /workspace/logs/dev-servers.log 2>&1 &
