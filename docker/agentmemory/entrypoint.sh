#!/bin/sh
# Adapted from AgentMemory's Coolify all-in-one entrypoint at
# d60652a7058773fa9428fa720eda38942f12f014 (Apache-2.0).

set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
SECRET_FILE="${AGENTMEMORY_SECRET_FILE:-/run/secrets/agentmemory-secret}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/node_modules/@agentmemory/agentmemory/dist/iii-config.yaml"

mkdir -p "$DATA_DIR"
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
    echo "Restore the matching .state/agentmemory-secret or reset the data volume." >&2
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

exec gosu "$RUN_AS" agentmemory "$@"
