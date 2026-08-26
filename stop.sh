#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PID_FILE="/private/tmp/chrome-outline-v1-${UID}.pid"
BINARY_PATH="$SCRIPT_DIR/bin/sing-box"
EXPECTED_COMMAND="$BINARY_PATH run -c config.json"

cd "$SCRIPT_DIR"

if [[ ! -e "$PID_FILE" ]]; then
  print "This project's sing-box is not running."
  exit 0
fi

if [[ ! -r "$PID_FILE" ]]; then
  print -u2 "Cannot read this project's PID file. No process was stopped."
  exit 1
fi

recorded_pid="$(<"$PID_FILE")"
if [[ "$recorded_pid" != <-> ]]; then
  print -u2 "The PID file is invalid. No process was stopped."
  exit 1
fi

current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
if [[ "$current_command" != "$EXPECTED_COMMAND" ]]; then
  print -u2 "PID $recorded_pid does not belong to this project's sing-box. No process was stopped."
  exit 1
fi

/usr/bin/sudo -v

current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
if [[ "$current_command" != "$EXPECTED_COMMAND" ]]; then
  print -u2 "The process changed while it was being checked. No process was stopped."
  exit 1
fi

/usr/bin/sudo /bin/kill -TERM "$recorded_pid"

for _ in {1..50}; do
  current_command="$(/bin/ps -ww -p "$recorded_pid" -o command= 2>/dev/null || true)"
  if [[ -z "$current_command" ]]; then
    /usr/bin/sudo /bin/rm -f "$PID_FILE"
    print "This project's sing-box has stopped."
    exit 0
  fi
  if [[ "$current_command" != "$EXPECTED_COMMAND" ]]; then
    /usr/bin/sudo /bin/rm -f "$PID_FILE"
    print "This project's sing-box has stopped."
    exit 0
  fi
  /bin/sleep 0.1
done

print -u2 "This project's sing-box did not stop within five seconds. The PID file was preserved."
exit 1
