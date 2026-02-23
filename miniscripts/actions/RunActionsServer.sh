#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/UpdateHomepage.sh"
PORT="${ACTIONS_SERVER_PORT:-8787}"
HOST="${ACTIONS_SERVER_HOST:-0.0.0.0}"
HOMEPAGE_REDIRECT_URL="${HOMEPAGE_REDIRECT_URL:-http://localhost:3001}"
ACTION_LOG_FILE="${ACTION_LOG_FILE:-/tmp/linuxscripts-update-homepage.log}"

if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  echo "Error: update script not found: $UPDATE_SCRIPT"
  exit 1
fi

export UPDATE_SCRIPT
export ACTIONS_SERVER_PORT="$PORT"
export ACTIONS_SERVER_HOST="$HOST"
export HOMEPAGE_REDIRECT_URL
export ACTION_LOG_FILE

python3 - <<'PY'
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

update_script = os.environ["UPDATE_SCRIPT"]
host = os.environ.get("ACTIONS_SERVER_HOST", "0.0.0.0")
port = int(os.environ.get("ACTIONS_SERVER_PORT", "8787"))
homepage_redirect_url = os.environ.get("HOMEPAGE_REDIRECT_URL", "http://localhost:3001")
action_log_file = os.environ.get("ACTION_LOG_FILE", "/tmp/linuxscripts-update-homepage.log")


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: str) -> None:
        body_bytes = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/update-homepage/status":
            self._show_status()
            return

        if path != "/update-homepage":
            self._respond(404, "Not found\n")
            return

        query = parse_qs(parsed.query)
        next_url = query.get("next", [""])[0].strip()
        redirect_url = next_url or self.headers.get("Referer", "").strip() or homepage_redirect_url

        with open(action_log_file, "a", encoding="utf-8") as log_fp:
            log_fp.write("\n=== Triggered update-homepage action ===\n")
            process = subprocess.Popen(
                ["bash", update_script],
                stdout=log_fp,
                stderr=log_fp,
                text=True,
            )
            log_fp.write(f"PID: {process.pid}\n")

        self.send_response(302)
        self.send_header("Location", redirect_url)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _show_status(self):
        if not os.path.exists(action_log_file):
            self._respond(200, "No action log yet.\n")
            return

        try:
            with open(action_log_file, "r", encoding="utf-8") as fp:
                content = fp.read()
        except OSError as exc:
            self._respond(500, f"Unable to read log file: {exc}\n")
            return

        self._respond(200, content if content.endswith("\n") else content + "\n")

    def log_message(self, format: str, *args):
        return


server = HTTPServer((host, port), Handler)
print(f"Actions server listening on http://{host}:{port}")
server.serve_forever()
PY
