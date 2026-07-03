#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes
mkdir -p /root/.pi/agent/extensions
mkdir -p /root/.hermes/extensions

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_KEY="${SUPABASE_KEY:-}"

# 1. Restore state from Supabase if credentials exist
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  echo "Checking Supabase backup..."
  HTTP_STATUS=$(curl -s -o /tmp/state.zip -w "%{http_code}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    "${SUPABASE_URL}/storage/v1/object/authenticated/hermes/state.zip")

  if [ "$HTTP_STATUS" -eq 200 ] && [ -f /tmp/state.zip ]; then
    echo "Restoring state..."
    python3 -c "import shutil; shutil.unpack_archive('/tmp/state.zip', '/root/.hermes')"
    rm -f /tmp/state.zip
  else
    echo "No backup found (HTTP ${HTTP_STATUS}). Starting fresh."
    rm -f /tmp/state.zip
  fi
fi

# 2. Setup environment variables and cleanup
AGENTROUTER_API_KEY_PRIMARY="${AGENTROUTER_API_KEY_PRIMARY:-}"
AGENTROUTER_API_KEY_SECONDARY="${AGENTROUTER_API_KEY_SECONDARY:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

export TELEGRAM_BOT_TOKEN="$(clean "$TELEGRAM_BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$TELEGRAM_ALLOWED_USERS")"
export AGENTROUTER_API_KEY_PRIMARY="$(clean "$AGENTROUTER_API_KEY_PRIMARY")"
export AGENTROUTER_API_KEY_SECONDARY="$(clean "$AGENTROUTER_API_KEY_SECONDARY")"

# Function to write active key to .env and export to environment for TS extensions
write_env() {
  local active_key="$1"
  export AGENTROUTER_API_KEY="${active_key}"
  {
    echo "AGENTROUTER_API_KEY=${active_key}"
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
  } > /root/.hermes/.env
  chmod 600 /root/.hermes/.env
}

# 3. Determine active key based on Bangladesh time (06:00 to 12:00 = Primary)
HOUR=$(date +%H)
HOUR_INT=$((10#$HOUR))

if [ $HOUR_INT -ge 6 ] && [ $HOUR_INT -lt 12 ]; then
  ACTIVE_KEY="$AGENTROUTER_API_KEY_PRIMARY"
  ACTIVE_NAME="PRIMARY"
else
  ACTIVE_KEY="${AGENTROUTER_API_KEY_SECONDARY:-}"
  ACTIVE_NAME="SECONDARY"
  if [ -z "$ACTIVE_KEY" ]; then
    ACTIVE_KEY="$AGENTROUTER_API_KEY_PRIMARY"
    ACTIVE_NAME="PRIMARY"
  fi
fi

write_env "$ACTIVE_KEY"

# 4. Create custom provider extensions based on official documentation
cat <<'EOF' > /root/.pi/agent/extensions/agentrouter-claude.ts
export default function (pi: ExtensionAPI) {
  pi.registerProvider("agentrouter-claude", {
    name: "AgentRouter Claude",
    baseUrl: "https://agentrouter.org",
    apiKey: process.env.AGENTROUTER_API_KEY || "",
    api: "anthropic-messages",
    models: [
      {
        id: "claude-opus-4-8",
        name: "Claude Opus 4.8 via AgentRouter",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 8192
      },
      {
        id: "claude-opus-4-7",
        name: "Claude Opus 4.7 via AgentRouter",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 8192
      },
      {
        id: "claude-opus-4-6",
        name: "Claude Opus 4.6 via AgentRouter",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 8192
      }
    ]
  });
}
EOF
cp /root/.pi/agent/extensions/agentrouter-claude.ts /root/.hermes/extensions/agentrouter-claude.ts

cat <<'EOF' > /root/.pi/agent/extensions/agentrouter-openai.ts
export default function (pi: ExtensionAPI) {
  pi.registerProvider("agentrouter-openai", {
    name: "AgentRouter openai",
    baseUrl: "https://agentrouter.org/v1",
    apiKey: process.env.AGENTROUTER_API_KEY || "",
    api: "OpenAI Compatible",
    models: [
      {
        id: "gpt-5.5",
        name: "GPT-5.5",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 8192
      },
      {
        id: "glm-5.2",
        name: "GLM-5.2",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 8192
      }
    ]
  });
}
EOF
cp /root/.pi/agent/extensions/agentrouter-openai.ts /root/.hermes/extensions/agentrouter-openai.ts

# 5. Create config.yaml utilizing the custom provider extensions
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "claude-opus-4-8"
  provider: "agentrouter-claude"

agent:
  api_max_retries: 2
  retry_backoff_base: 5.0
EOF

# 6. Background loop to sync backup to Supabase
backup_loop() {
  while true; do
    sleep 30
    if [ -d /root/.hermes ] && [ -f /root/.hermes/state.db ]; then
      python3 -c "import shutil; shutil.make_archive('/tmp/state', 'zip', '/root/.hermes')"
      
      curl -s -o /dev/null -X POST \
        -H "apikey: ${SUPABASE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_KEY}" \
        -H "Content-Type: application/zip" \
        -H "x-upsert: true" \
        --data-binary "@/tmp/state.zip" \
        "${SUPABASE_URL}/storage/v1/object/hermes/state.zip"
        
      rm -f /tmp/state.zip
    fi
  done
}

# 7. Background loop to check time and rotate keys (Checks every 5 minutes)
GATEWAY_PID=""
key_rotator_loop() {
  local current_active_name="$1"
  
  while true; do
    sleep 300
    
    local hour=$(date +%H)
    local hour_int=$((10#$hour))
    local target_key=""
    local target_name=""
    
    if [ $hour_int -ge 6 ] && [ $hour_int -lt 12 ]; then
      target_key="$AGENTROUTER_API_KEY_PRIMARY"
      target_name="PRIMARY"
    else
      target_key="$AGENTROUTER_API_KEY_SECONDARY"
      target_name="SECONDARY"
      if [ -z "$target_key" ]; then
        target_key="$AGENTROUTER_API_KEY_PRIMARY"
        target_name="PRIMARY"
      fi
    fi
    
    if [ "$target_name" != "$current_active_name" ]; then
      echo "Time shift detected. Swapping to $target_name key..."
      write_env "$target_key"
      current_active_name="$target_name"
      
      if [ -n "$GATEWAY_PID" ]; then
        kill "$GATEWAY_PID" || true
      fi
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

key_rotator_loop "$ACTIVE_NAME" &

# 8. Start web server and run Gateway process in a self-healing loop
PORT="${PORT:-8000}"
python3 -m http.server "$PORT" &

while true; do
  echo "Starting Hermes Gateway..."
  /usr/local/bin/hermes gateway run &
  GATEWAY_PID=$!
  wait $GATEWAY_PID || true
  sleep 2
done