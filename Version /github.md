#!/bin/bash
set -euo pipefail

mkdir -p /root/.hermes

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

# 2. Setup environment variables and cleanup for Telegram
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

export TELEGRAM_BOT_TOKEN="$(clean "$TELEGRAM_BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$TELEGRAM_ALLOWED_USERS")"
export GITHUB_TOKEN="$(clean "$GITHUB_TOKEN")"

# 3. Create the custom Python proxy with Dynamic Key Scanning, User-Agent bypass, and Context Truncation (8k Limit Fix)
cat <<'EOF' > /root/proxy.py
import http.server
import urllib.request
import urllib.error
import json
import os
import sys

github_token = os.environ.get("GITHUB_TOKEN", "").replace("\r", "").strip()

if not github_token:
    print("Error: GITHUB_TOKEN not found in environment!", file=sys.stderr)
    sys.exit(1)

class GitHubProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        if self.path in ["/chat/completions", "/v1/chat/completions"]:
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            # Parse and prune the payload to stay safely under GitHub's 8,000-token limit
            try:
                payload = json.loads(post_data.decode('utf-8'))
                modified = False
                
                # 1. Cap max_tokens to 2048 to prevent going over 8k limit
                if "max_tokens" in payload and isinstance(payload["max_tokens"], int) and payload["max_tokens"] > 2048:
                    payload["max_tokens"] = 2048
                    modified = True
                    
                if "max_completion_tokens" in payload and isinstance(payload["max_completion_tokens"], int) and payload["max_completion_tokens"] > 2048:
                    payload["max_completion_tokens"] = 2048
                    modified = True

                # 2. Prune old history to stay under 8,000 tokens limit (preserves system prompt + last 4 messages)
                if "messages" in payload and isinstance(payload["messages"], list) and len(payload["messages"]) > 6:
                    system_message = None
                    if payload["messages"][0].get("role") == "system":
                        system_message = payload["messages"][0]
                    
                    # Keep system prompt + last 4 messages (2 turns)
                    last_messages = payload["messages"][-4:]
                    
                    new_messages = []
                    if system_message:
                        new_messages.append(system_message)
                    new_messages.extend(last_messages)
                    
                    payload["messages"] = new_messages
                    modified = True
                    
                if modified:
                    post_data = json.dumps(payload).encode('utf-8')
            except Exception as pe:
                print(f"Payload parsing warning: {pe}", file=sys.stderr)

            # Submit request to GitHub Models official API
            req = urllib.request.Request(
                "https://models.inference.ai.azure.com/chat/completions",
                data=post_data,
                headers={
                    "Authorization": f"Bearer {github_token}",
                    "Content-Type": "application/json"
                },
                method="POST"
            )
            
            try:
                with urllib.request.urlopen(req, timeout=60) as response:
                    res_data = response.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(res_data)
                    return
            except urllib.error.HTTPError as e:
                err_msg = e.read().decode('utf-8', errors='ignore')
                print(f"GitHub Models API failed with HTTP {e.code}: {err_msg}", file=sys.stderr)
                self.send_response(e.code)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(err_msg.encode('utf-8'))
                return
            except Exception as e:
                print(f"Connection error: {e}", file=sys.stderr)
                self.send_response(500)
                self.end_headers()
                return
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path in ["/models", "/v1/models"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            models_data = {"data": [{"id": "gpt-4o", "object": "model"}]}
            self.wfile.write(json.dumps(models_data).encode('utf-8'))
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Proxy Alive")

def run(port=8001):
    server_address = ('127.0.0.1', port)
    httpd = http.server.HTTPServer(server_address, GitHubProxyHandler)
    print(f"Starting custom GitHub Models proxy on port {port}...", file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 4. Write local environment variables for Hermes
{
  echo "LITELLM_API_KEY=sk-dummy"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env
chmod 600 /root/.hermes/.env

# 5. Create Hermes config.yaml pointing to our local lightweight proxy
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "gpt-4o"
  provider: "local_proxy"

custom_providers:
  - name: local_proxy
    base_url: http://127.0.0.1:8001
    key_env: LITELLM_API_KEY
    api_mode: chat_completions

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

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

# 7. Start the custom lightweight Python GitHub Models proxy in the background
echo "Starting local Python GitHub Models proxy..."
python3 /root/proxy.py &

# 8. Start web server explicitly bound to 0.0.0.0 for Render's external health scanner
PORT="${PORT:-8000}"
python3 -m http.server --bind 0.0.0.0 "$PORT" &

# 9. Start Gateway in foreground (Ensures background jobs survive)
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run