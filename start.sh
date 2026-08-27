#!/bin/zsh

set -euo pipefail
umask 077

SCRIPT_DIR="${0:A:h}"
CONFIG_PATH="$SCRIPT_DIR/config.json"
LOG_PATH="$SCRIPT_DIR/sing-box.log"
BINARY_PATH="$SCRIPT_DIR/bin/sing-box"

if (( $# > 1 )); then
  print -u2 "Usage: ./start.sh ['ss://...']"
  exit 2
fi

if (( $# == 1 )); then
  outline_key="$1"
elif [[ -t 0 ]]; then
  read -r -s "outline_key?Enter the Outline ss:// access key: "
  print
else
  print -u2 "Missing Outline ss:// access key."
  exit 2
fi

if [[ -z "$outline_key" ]]; then
  print -u2 "The Outline ss:// access key cannot be empty."
  exit 2
fi

OUTLINE_SS_KEY="$outline_key" /opt/homebrew/bin/python3 - "$CONFIG_PATH" <<'PY'
import base64
import json
import os
import sys
from urllib.parse import unquote, urlsplit


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"Invalid Outline ss:// access key: {message}")


def decode_base64(value: str) -> str:
    padded = value + "=" * (-len(value) % 4)
    try:
        decoded = base64.b64decode(
            padded.encode("ascii"), altchars=b"-_", validate=True
        )
        return decoded.decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        fail(f"cannot decode Base64 content ({error})")


def parse_credentials(value: str) -> tuple[str, str]:
    value = unquote(value)
    decoded = value if ":" in value else decode_base64(value)
    if ":" not in decoded:
        fail("missing method:password")
    method, password = decoded.split(":", 1)
    if not method or not password:
        fail("method or password is empty")
    return method, password


def parse_endpoint(value: str) -> tuple[str, int]:
    endpoint = urlsplit("//" + value)
    try:
        port = endpoint.port
    except ValueError as error:
        fail(str(error))
    if not endpoint.hostname or port is None:
        fail("missing server or port")
    return endpoint.hostname, port


key = os.environ["OUTLINE_SS_KEY"].strip()
if not key.startswith("ss://"):
    fail("scheme must be ss://")

body = key[5:].split("#", 1)[0].split("?", 1)[0]
if not body:
    fail("key content is empty")

if "@" in body:
    credentials_part, endpoint_part = body.rsplit("@", 1)
    method, password = parse_credentials(credentials_part)
    server, port = parse_endpoint(endpoint_part)
else:
    decoded = decode_base64(unquote(body))
    if "@" not in decoded:
        fail("missing server:port")
    credentials_part, endpoint_part = decoded.rsplit("@", 1)
    method, password = parse_credentials(credentials_part)
    server, port = parse_endpoint(endpoint_part)

config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": True,
            "stack": "system",
        }
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {
            "type": "shadowsocks",
            "tag": "outline",
            "server": server,
            "server_port": port,
            "method": method,
            "password": password,
        },
    ],
    "route": {
        "auto_detect_interface": True,
        "rules": [
            {
                "process_path_regex": [
                    r"^/Applications/Google Chrome\.app/"
                ],
                "ip_version": 6,
                "action": "reject",
                "method": "default",
                "no_drop": True,
            },
            {
                "process_path_regex": [
                    r"^/Applications/Google Chrome\.app/"
                ],
                "action": "route",
                "outbound": "outline",
            }
        ],
        "final": "direct",
    },
}

with open(sys.argv[1], "w", encoding="utf-8") as config_file:
    json.dump(config, config_file, ensure_ascii=False, indent=2)
    config_file.write("\n")
os.chmod(sys.argv[1], 0o600)
PY

unset outline_key

cd "$SCRIPT_DIR"

if ! "$BINARY_PATH" check -c config.json; then
  print -u2 "sing-box check failed. The TUN was not started."
  exit 1
fi

PID_FILE="/private/tmp/chrome-outline-v1-${UID}.pid"
EXPECTED_COMMAND="$BINARY_PATH run -c config.json"

if [[ -r "$PID_FILE" ]]; then
  recorded_pid="$(<"$PID_FILE")"
  if [[ "$recorded_pid" == <-> ]]; then
    current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
    if [[ "$current_command" == "$EXPECTED_COMMAND" ]]; then
      print "This project's sing-box is already running. PID: $recorded_pid"
      exit 0
    fi
  fi
fi

/usr/bin/sudo -v
if [[ -e "$PID_FILE" ]]; then
  /usr/bin/sudo /bin/rm -f "$PID_FILE"
fi

/usr/bin/nohup /usr/bin/sudo -n /bin/sh -c '
  umask 022
  printf "%s\n" "$$" > "$1"
  exec "$2" run -c config.json
' chrome-outline-v1 "$PID_FILE" "$BINARY_PATH" >"$LOG_PATH" 2>&1 &
launcher_pid=$!

for _ in {1..30}; do
  if [[ -r "$PID_FILE" ]]; then
    recorded_pid="$(<"$PID_FILE")"
    if [[ "$recorded_pid" == <-> ]]; then
      current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
      if [[ "$current_command" == "$EXPECTED_COMMAND" ]]; then
        print "sing-box TUN started. PID: $recorded_pid"
        exit 0
      fi
    fi
  fi

  launcher_command="$(/bin/ps -p "$launcher_pid" -o command= 2>/dev/null || true)"
  if [[ -z "$launcher_command" ]]; then
    break
  fi
  /bin/sleep 0.1
done

if [[ -r "$PID_FILE" ]]; then
  recorded_pid="$(<"$PID_FILE")"
  if [[ "$recorded_pid" == <-> ]]; then
    current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
    if [[ "$current_command" == "$EXPECTED_COMMAND" ]]; then
      /usr/bin/sudo /bin/kill -TERM "$recorded_pid"
    fi
  fi
  /usr/bin/sudo /bin/rm -f "$PID_FILE"
fi

print -u2 "Failed to start the sing-box TUN. See the log: $LOG_PATH"
exit 1
