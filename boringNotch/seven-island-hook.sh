#!/bin/sh
# Bundled by Seven Island — invoked from ~/.claude/settings.json and ~/.codex/hooks.json.
# Usage: seven-island-hook.sh <platform> <action> [event_name] [permission_timeout]
# platform: claude | codex
# action:   session | stop | hook | permission
set -eu

PLATFORM="${1:-}"
ACTION="${2:-}"
EVENT_NAME="${3:-}"
PERMISSION_TIMEOUT="${4:-60}"

SOCKET_PATH="${SEVEN_ISLAND_SOCKET:-$HOME/.seven-island/agent.sock}"
LOG_PATH="${SEVEN_ISLAND_LOG:-$HOME/.seven-island/hooks-log.jsonl}"

payload=$(cat 2>/dev/null || true)

case "$PLATFORM" in
  claude|codex|opencode) ;;
  *) exit 0 ;;
esac

# ── Shared JSONL writer (inlined python) ─────────────────────────────────────
_write_jsonl() {
  event_name="$1"
  raw="$2"
  log_path="$3"
  extra_json="${4:-{}}"
  python3 -c "
import sys, json, time, os, shutil
event_name = sys.argv[1]
raw        = sys.argv[2]
log_path   = sys.argv[3]
extra_json = sys.argv[4] if len(sys.argv) > 4 else '{}'
platform   = sys.argv[5] if len(sys.argv) > 5 else ''
try:
    p = json.loads(raw)
    extra = json.loads(extra_json)
except Exception:
    sys.exit(0)
def summarize(ev, p):
    inp = p.get('tool_input') or {}
    m = {
        'SessionStart':      p.get('model', ''),
        'UserPromptSubmit':  p.get('prompt', '')[:80],
        'Stop':              p.get('last_assistant_message', '')[:80],
        'StopFailure':       p.get('error', ''),
        'Notification':      p.get('message', ''),
        'PermissionRequest': p.get('tool_name', ''),
        'SessionEnd':        '',
    }.get(ev, '')
    return str(m).strip()
record = {
    'ts':                time.time(),
    'event':             event_name,
    'session_id':        p.get('session_id', ''),
    'cwd':               p.get('cwd', ''),
    'tool_name':         p.get('tool_name'),
    'summary':           summarize(event_name, p),
    'model':             p.get('model'),
    'parent_session_id': p.get('parent_session_id') or p.get('parentSessionId'),
    'platform':          platform,
}
record.update(extra)
try:
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
    try:
        with open(log_path) as f: lines = f.readlines()
    except FileNotFoundError:
        lines = []
    if len(lines) > 3000: lines = lines[-2000:]
    lines.append(json.dumps(record, ensure_ascii=False) + '\n')
    tmp = log_path + '.tmp'
    with open(tmp, 'w') as f: f.writelines(lines)
    shutil.move(tmp, log_path)
except Exception:
    pass
" "$event_name" "$raw" "$log_path" "$extra_json" "$PLATFORM" 2>/dev/null || true
}

# Bail if socket doesn't exist (app not running) — still record hook/permission to JSONL
if [ ! -S "$SOCKET_PATH" ]; then
  case "$ACTION" in
    hook)
      _write_jsonl "$EVENT_NAME" "$payload" "$LOG_PATH"
      ;;
    permission)
      _write_jsonl "PermissionRequest" "$payload" "$LOG_PATH"
      exit 0
      ;;
  esac
  exit 0
fi

case "$ACTION" in
  session|stop)
    # Fire-and-forget: record to JSONL, nudge socket (action: hook so AgentSocketServer talks)
    _write_jsonl "$ACTION" "$payload" "$LOG_PATH"
    python3 -c "
import socket, sys, json
platform = sys.argv[1]
action   = sys.argv[2]
payload  = sys.argv[3]
sock     = sys.argv[4]
try:
    p = json.loads(payload)
except Exception:
    sys.exit(0)
p['platform'] = platform
msg = json.dumps({'action': action, 'payload': p}) + '\n'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(sock)
    s.sendall(msg.encode())
    s.shutdown(socket.SHUT_RDWR)
except Exception:
    pass
finally:
    s.close()
" "$PLATFORM" "$ACTION" "$payload" "$SOCKET_PATH" 2>/dev/null || true
    ;;

  hook)
    event="${EVENT_NAME:-}"
    _write_jsonl "$event" "$payload" "$LOG_PATH"
    python3 -c "
import socket, sys, json
platform   = sys.argv[1]
event_name = sys.argv[2]
raw        = sys.argv[3]
sock       = sys.argv[4]
try:
    p = json.loads(raw)
except Exception:
    sys.exit(0)
record = {
    'action': 'hook',
    'payload': {
        'event': event_name,
        'session_id': p.get('session_id', ''),
        'platform': platform,
    }
}
msg = json.dumps(record) + '\n'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sock)
    s.sendall(msg.encode())
    s.shutdown(socket.SHUT_RDWR)
except Exception:
    pass
finally:
    try: s.close()
    except: pass
" "$PLATFORM" "$event" "$payload" "$SOCKET_PATH" 2>/dev/null || true
    ;;

  permission)
    # Write JSONL immediately, then block on socket waiting for allow/deny decision.
    _write_jsonl "PermissionRequest" "$payload" "$LOG_PATH"
    python3 -c "
import socket, sys, json, os
platform = sys.argv[1]
raw      = sys.argv[2]
sock     = sys.argv[3]
try:
    p = json.loads(raw)
except Exception:
    sys.exit(0)
p['platform'] = platform
msg = json.dumps({'action': 'permission', 'payload': p}) + '\n'
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(None)
try:
    s.connect(sock)
    s.sendall(msg.encode())
    s.shutdown(socket.SHUT_WR)
    resp = b''
    while b'\n' not in resp:
        chunk = s.recv(1024)
        if not chunk: break
        resp += chunk
    r = resp.decode('utf-8', errors='replace').strip()
    def write_decision(behavior, message=''):
        os.write(1, json.dumps({
            'hookSpecificOutput': {
                'hookEventName': 'PermissionRequest',
                'decision': {'behavior': behavior, 'message': message} if message else {'behavior': behavior}
            }
        }).encode() + b'\n')
    if r == 'allow':
        write_decision('allow')
        sys.exit(0)
    elif r.startswith('deny'):
        reason = r[5:].strip() if r.startswith('deny:') else ''
        write_decision('deny', reason or '用户在灵动岛拒绝了权限请求')
        sys.exit(0)
    else:
        write_decision('deny', '未收到有效授权回复')
        sys.exit(0)
except Exception:
    # On any error, auto-allow so Claude Code isn't blocked by a missing UI
    os.write(1, json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': {'behavior': 'allow'}
        }
    }).encode() + b'\n')
    sys.exit(0)
finally:
    try: s.close()
    except: pass
" "$PLATFORM" "$payload" "$SOCKET_PATH" 2>/dev/null
    ;;

  *)
    exit 0
    ;;
esac