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

# 2. Setup environment variables and cleanup (Supports up to 6 keys)
OPENROUTER_API_KEY_1="${OPENROUTER_API_KEY_1:-}"
OPENROUTER_API_KEY_2="${OPENROUTER_API_KEY_2:-}"
OPENROUTER_API_KEY_3="${OPENROUTER_API_KEY_3:-}"
OPENROUTER_API_KEY_4="${OPENROUTER_API_KEY_4:-}"
OPENROUTER_API_KEY_5="${OPENROUTER_API_KEY_5:-}"
OPENROUTER_API_KEY_6="${OPENROUTER_API_KEY_6:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

clean() {
  echo "$1" | tr -d '\r' | xargs
}

export TELEGRAM_BOT_TOKEN="$(clean "$TELEGRAM_BOT_TOKEN")"
export TELEGRAM_ALLOWED_USERS="$(clean "$TELEGRAM_ALLOWED_USERS")"

export KEY_1="$(clean "$OPENROUTER_API_KEY_1")"
export KEY_2="$(clean "$OPENROUTER_API_KEY_2")"
export KEY_3="$(clean "$OPENROUTER_API_KEY_3")"
export KEY_4="$(clean "$OPENROUTER_API_KEY_4")"
export KEY_5="$(clean "$OPENROUTER_API_KEY_5")"
export KEY_6="$(clean "$OPENROUTER_API_KEY_6")"

# Function to write active key to .env
write_env() {
  local active_key="$1"
  {
    echo "OPENROUTER_API_KEY=${active_key}"
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
  } > /root/.hermes/.env
  chmod 600 /root/.hermes/.env
}

# 3. Create the custom Python proxy with DYNAMIC Key Scanning & Failover
cat <<'EOF' > /root/proxy.py
import http.server
import urllib.request
import urllib.error
import json
import os
import sys

# Dynamically scan all environment variables starting with "OPENROUTER_API_KEY_"
env_keys = {}
for env_name, env_val in os.environ.items():
    if env_name.startswith("OPENROUTER_API_KEY_"):
        val_clean = env_val.replace("\r", "").strip()
        if val_clean:
            try:
                index = int(env_name.replace("OPENROUTER_API_KEY_", ""))
                env_keys[index] = val_clean
            except ValueError:
                env_keys[env_name] = val_clean

sorted_indices = sorted([k for k in env_keys.keys() if isinstance(k, int)])
active_keys = [env_keys[idx] for idx in sorted_indices]

for k, v in env_keys.items():
    if not isinstance(k, int):
        active_keys.append(v)

if not active_keys:
    print("Error: No active OpenRouter keys (OPENROUTER_API_KEY_*) found in environment!", file=sys.stderr)
    sys.exit(1)

print(f"Custom Proxy initialized with {len(active_keys)} active keys.", file=sys.stderr)
current_key_index = 0

class OpenRouterProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        global current_key_index
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            
            try:
                payload = json.loads(post_data.decode('utf-8'))
                modified = False
                
                if "max_tokens" in payload and isinstance(payload["max_tokens"], int) and payload["max_tokens"] > 4096:
                    payload["max_tokens"] = 4096
                    modified = True
                    
                if "max_completion_tokens" in payload and isinstance(payload["max_completion_tokens"], int) and payload["max_completion_tokens"] > 4096:
                    payload["max_completion_tokens"] = 4096
                    modified = True

                if "messages" in payload and isinstance(payload["messages"], list) and len(payload["messages"]) > 6:
                    system_message = None
                    if payload["messages"][0].get("role") == "system":
                        system_message = payload["messages"][0]
                    
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

            for attempt in range(len(active_keys)):
                key_index = (current_key_index + attempt) % len(active_keys)
                api_key = active_keys[key_index]
                
                req = urllib.request.Request(
                    "https://openrouter.ai/api/v1/chat/completions",
                    data=post_data,
                    headers={
                        "Authorization": f"Bearer {api_key}",
                        "Content-Type": "application/json",
                        "HTTP-Referer": "https://github.com/",
                        "X-Title": "Pydroid 3 Bot"
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
                        current_key_index = key_index
                        return
                except urllib.error.HTTPError as e:
                    err_msg = e.read().decode('utf-8', errors='ignore')
                    print(f"Key {key_index + 1} failed with HTTP {e.code}: {err_msg}", file=sys.stderr)
                    if e.code in [429, 402, 401, 400, 413]:
                        continue
                    else:
                        self.send_response(e.code)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(err_msg.encode('utf-8'))
                        return
                except Exception as e:
                    print(f"Key {key_index + 1} connection error: {e}", file=sys.stderr)
                    continue
            
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": "All OpenRouter keys failed."}}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            models_data = {"data": [{"id": "openrouter/free", "object": "model"}]}
            self.wfile.write(json.dumps(models_data).encode('utf-8'))
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Proxy Alive")

def run(port=8001):
    server_address = ('127.0.0.1', port)
    httpd = http.server.HTTPServer(server_address, OpenRouterProxyHandler)
    print(f"Starting lightweight proxy on port {port}...", file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 4. Create the Custom Interactive Admin Control Panel inside reverse_proxy.py
cat <<'EOF' > /root/reverse_proxy.py
import http.server
import urllib.request
import urllib.error
import socketserver
import os
import sys
import json
import subprocess
import shutil

PORT = int(os.environ.get("PORT", 10000))
PASSWORD = "sk-hermes-boss-key"

INDEX_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hermes Agent - Admin Control Panel</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; background-color: #0b0f19; color: #f3f4f6; margin: 0; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; background: #111827; border-radius: 12px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); padding: 30px; border-top: 5px solid #3b82f6; }
        h1 { margin: 0 0 10px 0; color: #fff; }
        .tabs { display: flex; gap: 10px; margin-bottom: 25px; border-bottom: 2px solid #1f2937; padding-bottom: 10px; }
        .tab-btn { background: none; border: none; color: #9ca3af; font-size: 16px; font-weight: 600; cursor: pointer; padding: 8px 16px; border-radius: 4px; transition: 0.2s; }
        .tab-btn.active { background-color: #1e293b; color: #3b82f6; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .card { background-color: #1f2937; border-radius: 8px; padding: 20px; border: 1px solid #374151; margin-bottom: 20px; }
        .card h2 { margin: 0 0 15px 0; font-size: 18px; color: #fff; border-bottom: 1px solid #374151; padding-bottom: 8px; }
        .info-row { display: flex; justify-content: space-between; margin-bottom: 10px; font-size: 14px; }
        .label { color: #9ca3af; }
        .value { color: #e5e7eb; font-family: monospace; background-color: #111827; padding: 2px 6px; border-radius: 4px; }
        textarea, select, input { width: 100%; background: #111827; color: #fff; border: 1px solid #374151; border-radius: 6px; padding: 12px; font-family: monospace; box-sizing: border-box; font-size: 14px; }
        button { background-color: #3b82f6; color: #fff; border: none; padding: 10px 20px; border-radius: 6px; cursor: pointer; font-weight: bold; font-size: 14px; transition: 0.2s; }
        button:hover { background-color: #2563eb; }
        .terminal { background-color: #000; color: #10b981; padding: 15px; border-radius: 6px; font-family: monospace; height: 250px; overflow-y: auto; white-space: pre-wrap; font-size: 13px; border: 1px solid #111827; }
        .login-box { max-width: 400px; margin: 150px auto 0 auto; background: #111827; border-radius: 12px; padding: 30px; border-top: 5px solid #3b82f6; text-align: center; }
        .login-box h2 { color: #fff; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div id="login-container" class="login-box">
        <h2>🔒 Admin Access Required</h2>
        <input type="password" id="password-input" placeholder="Enter sk-hermes-boss-key..." style="margin-bottom: 20px;">
        <button onclick="login()">Access Dashboard</button>
    </div>

    <div id="main-container" class="container" style="display: none;">
        <h1>⚕️ Hermes Control Panel</h1>
        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab('overview')">Overview</button>
            <button class="tab-btn" onclick="switchTab('terminal')">Terminal</button>
            <button class="tab-btn" onclick="switchTab('files')">File Manager</button>
            <button class="tab-btn" onclick="switchTab('logs')">Live Logs</button>
        </div>

        <!-- OVERVIEW TAB -->
        <div id="overview" class="tab-content active">
            <div class="card">
                <h2>📊 Server Status</h2>
                <div class="info-row"><span class="label">Primary Connection:</span><span class="value" style="color: #10b981;">Online & Active</span></div>
                <div class="info-row"><span class="label">System CPU / RAM / Storage:</span><span class="value" id="system-stats">Loading...</span></div>
                <div class="info-row"><span class="label">Allowed Telegram ID:</span><span class="value">{ALLOWED_USER_ID}</span></div>
            </div>
        </div>

        <!-- TERMINAL TAB -->
        <div id="terminal" class="tab-content">
            <div class="card">
                <h2>⚡ Bash Command Terminal</h2>
                <div class="terminal" id="terminal-output">Ready...</div>
                <div style="display: flex; gap: 10px; margin-top: 15px;">
                    <input type="text" id="cmd-input" placeholder="Enter bash command (e.g. ls, df -h, ps aux)..." onkeydown="if(event.key==='Enter') runCommand()">
                    <button onclick="runCommand()">Execute</button>
                </div>
            </div>
        </div>

        <!-- FILE MANAGER TAB -->
        <div id="files" class="tab-content">
            <div class="card">
                <h2>📁 File Editor</h2>
                <select id="file-selector" onchange="loadFile()">
                    <option value="">-- Choose a file to edit --</option>
                    <option value="/root/.hermes/config.yaml">config.yaml (Main settings)</option>
                    <option value="/root/.hermes/.env">.env (API & Telegram keys)</option>
                    <option value="/root/.hermes/memories/USER.md">USER.md (User Memory)</option>
                    <option value="/root/.hermes/memories/MEMORY.md">MEMORY.md (AI Memory)</option>
                </select>
                <textarea id="file-content" rows="12" style="margin-top: 15px; display: none;" placeholder="File content..."></textarea>
                <div style="display: flex; gap: 10px; margin-top: 15px;">
                    <button id="save-btn" onclick="saveFile()" style="display: none;">Save & Restart Gateway</button>
                </div>
            </div>
        </div>

        <!-- LOGS TAB -->
        <div id="logs" class="tab-content">
            <div class="card">
                <h2>📋 Hermes Gateway Console Output</h2>
                <div class="terminal" id="logs-output" style="height: 350px;">Loading console logs...</div>
                <button onclick="loadLogs()" style="margin-top: 15px;">Refresh Logs</button>
            </div>
        </div>
    </div>

    <script>
        let token = "";

        function login() {
            const pwd = document.getElementById("password-input").value;
            fetch("/api/login", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ password: pwd })
            }).then(res => {
                if(res.status === 200) {
                    token = pwd;
                    document.getElementById("login-container").style.display = "none";
                    document.getElementById("main-container").style.display = "block";
                    loadStats();
                } else {
                    alert("Invalid Password!");
                }
            });
        }

        function switchTab(tabId) {
            document.querySelectorAll(".tab-btn").forEach(btn => btn.classList.remove("active"));
            document.querySelectorAll(".tab-content").forEach(content => content.classList.remove("active"));
            
            event.target.classList.add("active");
            document.getElementById(tabId).classList.add("active");

            if(tabId === "logs") loadLogs();
        }

        function loadStats() {
            fetch("/api/stats", { headers: { "Authorization": token } })
            .then(res => res.json())
            .then(data => {
                document.getElementById("system-stats").innerText = data.stats;
            });
        }

        function runCommand() {
            const cmd = document.getElementById("cmd-input").value;
            if(!cmd) return;
            document.getElementById("terminal-output").innerText += "\\n$ " + cmd + "\\nRunning...";
            
            fetch("/api/command", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ command: cmd })
            }).then(res => res.json())
            .then(data => {
                document.getElementById("terminal-output").innerText = data.output;
            });
        }

        function loadFile() {
            const file = document.getElementById("file-selector").value;
            if(!file) {
                document.getElementById("file-content").style.display = "none";
                document.getElementById("save-btn").style.display = "none";
                return;
            }
            fetch("/api/file/read", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ file: file })
            }).then(res => res.json())
            .then(data => {
                document.getElementById("file-content").value = data.content;
                document.getElementById("file-content").style.display = "block";
                document.getElementById("save-btn").style.display = "block";
            });
        }

        function saveFile() {
            const file = document.getElementById("file-selector").value;
            const content = document.getElementById("file-content").value;
            fetch("/api/file/write", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": token },
                body: JSON.stringify({ file: file, content: content })
            }).then(res => res.json())
            .then(data => {
                alert("File saved and Gateway restarted successfully!");
            });
        }

        // Periodically refresh stats if on Overview tab
        setInterval(() => {
            if(token && document.getElementById("overview").classList.contains("active")) {
                loadStats();
            }
        }, 10000);

        function loadLogs() {
            fetch("/api/logs", { headers: { "Authorization": token } })
            .then(res => res.json())
            .then(data => {
                document.getElementById("logs-output").innerText = data.logs;
            });
        }
    </script>
</body>
</html>
"""

class ReverseProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def handle_request(self, target_url):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else None
        
        headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ['host', 'content-length']:
                headers[k] = v
                
        req = urllib.request.Request(
            target_url,
            data=body,
            headers=headers,
            method=self.command
        )
        
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                self.send_response(response.status)
                hop_by_hop = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailers', 'transfer-encoding', 'upgrade']
                for k, v in response.headers.items():
                    if k.lower() not in hop_by_hop:
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(response.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Proxy error: {e}".encode('utf-8'))

    def do_GET(self):
        if self.path.startswith("/v1"):
            # Forward API requests to Hermes API Server
            self.handle_request(f"http://127.0.0.1:8642{self.path}")
        elif self.path == "/api/stats":
            if self.headers.get("Authorization") != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            try:
                storage = subprocess.check_output("df -h / | tail -1 | awk '{print $4}'", shell=True).decode('utf-8').strip()
                mem = subprocess.check_output("free -m | grep Mem | awk '{print $4}'", shell=True).decode('utf-8').strip()
                uptime = subprocess.check_output("uptime -p", shell=True).decode('utf-8').strip()
                stats_str = f"Free RAM: {mem} MB | Free Storage: {storage} | {uptime}"
            except:
                stats_str = "Memory: OK | Storage: OK"
            self.wfile.write(json.dumps({"stats": stats_str}).encode('utf-8'))
        elif self.path == "/api/logs":
            if self.headers.get("Authorization") != PASSWORD:
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            log_content = ""
            if os.path.exists("/root/.hermes/gateway.log"):
                try:
                    with open("/root/.hermes/gateway.log", "r") as f:
                        log_content = "".join(f.readlines()[-100:])
                except Exception as e:
                    log_content = f"Error reading logs: {e}"
            else:
                log_content = "Console logs not found."
            self.wfile.write(json.dumps({"logs": log_content}).encode('utf-8'))
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            # Dynamically replace variables inside HTML without f-string brackets conflict
            allowed_user_id = os.environ.get("TELEGRAM_ALLOWED_USERS", "Unknown ID")
            self.wfile.write(INDEX_HTML.replace("{ALLOWED_USER_ID}", allowed_user_id).encode('utf-8'))

    def do_POST(self):
        if self.path.startswith("/v1"):
            self.handle_request(f"http://127.0.0.1:8642{self.path}")
            return
            
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        payload = json.loads(post_data.decode('utf-8')) if content_length > 0 else {}

        if self.path == "/api/login":
            if payload.get("password") == PASSWORD:
                self.send_response(200)
            else:
                self.send_response(401)
            self.end_headers()
            return

        if self.headers.get("Authorization") != PASSWORD:
            self.send_response(401)
            self.end_headers()
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        if self.path == "/api/command":
            cmd = payload.get("command")
            try:
                output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT, timeout=30).decode('utf-8')
            except Exception as e:
                output = str(e)
            self.wfile.write(json.dumps({"output": output}).encode('utf-8'))

        elif self.path == "/api/file/read":
            file_path = payload.get("file")
            content = ""
            if os.path.exists(file_path):
                try:
                    with open(file_path, "r") as f:
                        content = f.read()
                except Exception as e:
                    content = f"Error: {e}"
            self.wfile.write(json.dumps({"content": content}).encode('utf-8'))

        elif self.path == "/api/file/write":
            file_path = payload.get("file")
            content = payload.get("content")
            success = False
            try:
                with open(file_path, "w") as f:
                    f.write(content)
                success = True
                # Gracefully restart the gateway process to apply changes
                subprocess.Popen("/usr/local/bin/hermes gateway restart", shell=True)
            except Exception as e:
                print(f"File write error: {e}", file=sys.stderr)
            self.wfile.write(json.dumps({"success": success}).encode('utf-8'))

    def do_PUT(self):
        self.do_POST()
    def do_DELETE(self):
        self.do_POST()

def run():
    socketserver.TCPServer.allow_reuse_address = True
    server_address = ('0.0.0.0', PORT)
    httpd = socketserver.TCPServer(server_address, ReverseProxyHandler)
    print(f"Starting lightweight dashboard on port {PORT}...", file=sys.stderr)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF

# 5. Write local environment variables for Hermes
{
  echo "LITELLM_API_KEY=sk-dummy"
  echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
  echo "TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS}"
} > /root/.hermes/.env
chmod 600 /root/.hermes/.env

# 6. Create Hermes config.yaml pointing to our local proxy & enabling API server
cat <<EOF > /root/.hermes/config.yaml
model:
  default: "openrouter/free"
  provider: "local_proxy"

custom_providers:
  - name: local_proxy
    base_url: http://127.0.0.1:8001/v1
    key_env: LITELLM_API_KEY
    api_mode: chat_completions

api_server:
  enabled: true
  host: "127.0.0.1"
  port: 8642
  api_key: "sk-hermes-boss-key"

agent:
  api_max_retries: 2
  retry_backoff_base: 5.0
EOF

# 7. Optimized Background loop (Sleep 4 Hours + Change Detection to save 99% bandwidth)
backup_loop() {
  local last_backed_up_mtime=0
  while true; do
    sleep 14400 # Backup every 4 hours instead of 30 seconds
    if [ -d /root/.hermes ] && [ -f /root/.hermes/state.db ]; then
      local current_mtime
      current_mtime=$(stat -c %Y /root/.hermes/state.db 2>/dev/null || echo 0)
      
      if [ "$current_mtime" -gt "$last_backed_up_mtime" ]; then
        echo "Database modified. Cleaning logs and syncing secure backup..."
        python3 -c "import os, shutil; [os.remove(os.path.join(r, f)) for r, d, fs in os.walk('/root/.hermes') for f in fs if f.endswith('.log') or f.endswith('.tmp')]; shutil.make_archive('/tmp/state', 'zip', '/root/.hermes')"
        
        HTTP_STATUS=$(curl -s -o /dev/null -X POST \
          -H "apikey: ${SUPABASE_KEY}" \
          -H "Authorization: Bearer ${SUPABASE_KEY}" \
          -H "Content-Type: application/zip" \
          -H "x-upsert: true" \
          --data-binary "@/tmp/state.zip" \
          "${SUPABASE_URL}/storage/v1/object/hermes/state.zip")
          
        rm -f /tmp/state.zip
        if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
          last_backed_up_mtime="$current_mtime"
          echo "Sync complete."
        fi
      fi
    fi
  done
}

# Start background services
if [ -n "${SUPABASE_URL}" ] && [ -n "${SUPABASE_KEY}" ]; then
  backup_loop &
fi

# 8. Start local Python proxies
echo "Starting local OpenRouter failover proxy..."
python3 /root/proxy.py &

# 9. Start Hermes Gateway internally (Automatically spins up API Server on port 8642, redirects logs to file)
echo "Starting Hermes Gateway..."
/usr/local/bin/hermes gateway run > /root/.hermes/gateway.log 2>&1 &

# 10. Start the ultimate Python Reverse Proxy in foreground (Handles public port 10000)
python3 /root/reverse_proxy.py