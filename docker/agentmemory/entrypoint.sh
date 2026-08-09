#!/bin/sh
# Adapted from AgentMemory's Coolify all-in-one entrypoint at
# d60652a7058773fa9428fa720eda38942f12f014 (Apache-2.0).

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
TRANSFORMERS_CACHE_DIR="${AGENTMEMORY_TRANSFORMERS_CACHE_DIR:-$DATA_DIR/transformers-cache}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
SECRET_FILE="${AGENTMEMORY_SECRET_FILE:-/run/secrets/agentmemory-secret}"
III_PID_FILE="/home/node/.agentmemory/iii.pid"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

export AGENTMEMORY_DATA_DIR="$DATA_DIR"

mkdir -p "$DATA_DIR" "$TRANSFORMERS_CACHE_DIR"
chown -R "$RUN_AS" "$DATA_DIR"

cat > "$III_CONFIG" <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins:
          - "http://localhost:3111"
          - "http://localhost:3113"
          - "http://127.0.0.1:3111"
          - "http://127.0.0.1:3113"
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 1.0
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF
chown "$RUN_AS" "$III_CONFIG"

if [ ! -s "$SECRET_FILE" ]; then
  echo "agentmemory: secret file is missing or empty: $SECRET_FILE" >&2
  exit 1
fi

# Seed the persistent HMAC once. Refuse mismatches instead of silently rotating
# a credential while retaining the existing memory volume.
if [ -s "$HMAC_FILE" ]; then
  if ! cmp -s "$SECRET_FILE" "$HMAC_FILE"; then
    echo "agentmemory: local secret does not match the persistent /data/.hmac" >&2
    echo "Restore the matching host agentmemory-secret or reset the data directory." >&2
    exit 1
  fi
else
  umask 077
  cat "$SECRET_FILE" > "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
  chown "$RUN_AS" "$HMAC_FILE"
fi

AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

CHILD_PID=""
SHUTTING_DOWN=0

shutdown() {
  SHUTTING_DOWN=1
  trap - TERM INT
  echo "agentmemory: graceful shutdown requested" >&2

  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi

  III_PID=""
  if [ -s "$III_PID_FILE" ]; then
    III_PID="$(cat "$III_PID_FILE" 2>/dev/null || true)"
  fi
  case "$III_PID" in
    *[!0-9]*|"") III_PID="" ;;
  esac
  if [ -n "$III_PID" ] && kill -0 "$III_PID" 2>/dev/null; then
    kill -TERM "$III_PID" 2>/dev/null || true
  fi

  attempts=0
  while [ "$attempts" -lt 100 ]; do
    child_running=0
    engine_running=0
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
      child_running=1
    fi
    if [ -n "$III_PID" ] && kill -0 "$III_PID" 2>/dev/null; then
      engine_running=1
    fi
    if [ "$child_running" -eq 0 ] && [ "$engine_running" -eq 0 ]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.2
  done
}

trap shutdown TERM INT
gosu "$RUN_AS" agentmemory "$@" &
CHILD_PID=$!

set +e
wait "$CHILD_PID"
STATUS=$?
set -e

if [ "$SHUTTING_DOWN" -eq 1 ]; then
  exit 0
fi
exit "$STATUS"
