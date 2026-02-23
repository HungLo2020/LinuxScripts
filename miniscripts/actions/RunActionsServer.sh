#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/UpdateHomepage.sh"
PORT="${ACTIONS_SERVER_PORT:-8787}"
HOST="${ACTIONS_SERVER_HOST:-0.0.0.0}"

if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  echo "Error: update script not found: $UPDATE_SCRIPT"
  exit 1
fi

export UPDATE_SCRIPT
export ACTIONS_SERVER_PORT="$PORT"
export ACTIONS_SERVER_HOST="$HOST"

python3 - <<'PY'
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

update_script = os.environ["UPDATE_SCRIPT"]
host = os.environ.get("ACTIONS_SERVER_HOST", "0.0.0.0")
port = int(os.environ.get("ACTIONS_SERVER_PORT", "8787"))


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: str) -> None:
        body_bytes = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):
        if self.path.rstrip("/") != "/update-homepage":
            self._respond(404, "Not found\n")
            return

        result = subprocess.run(
            ["bash", update_script],
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode == 0:
            output = (result.stdout or "").strip()
            if output:
                self._respond(200, f"Update started/completed successfully.\n\n{output}\n")
            else:
                self._respond(200, "Update started/completed successfully.\n")
            return

        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        merged = "\n".join(part for part in [stdout, stderr] if part)
        self._respond(500, f"Update failed (exit {result.returncode}).\n\n{merged}\n")

    def log_message(self, format: str, *args):
        return


server = HTTPServer((host, port), Handler)
print(f"Actions server listening on http://{host}:{port}")
server.serve_forever()
PY
