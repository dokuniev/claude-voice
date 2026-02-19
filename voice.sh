#!/bin/bash
# voice: TTS branch name announcements for Claude Code hooks
# Speaks the git branch name on Stop/Notification so you know which session needs attention
set -uo pipefail

VOICE_DIR="${CLAUDE_VOICE_DIR:-$HOME/.claude/hooks/voice}"
CONFIG="$VOICE_DIR/config.json"
PAUSED_FILE="$VOICE_DIR/.paused"

# --- CLI subcommands (must come before INPUT=$(cat) which blocks on stdin) ---
case "${1:-}" in
  --pause)   touch "$PAUSED_FILE"; echo "voice: paused"; exit 0 ;;
  --resume)  rm -f "$PAUSED_FILE"; echo "voice: resumed"; exit 0 ;;
  --toggle)
    if [ -f "$PAUSED_FILE" ]; then rm -f "$PAUSED_FILE"; echo "voice: resumed"
    else touch "$PAUSED_FILE"; echo "voice: paused"; fi
    exit 0 ;;
  --status)
    [ -f "$PAUSED_FILE" ] && echo "voice: paused" || echo "voice: active"
    exit 0 ;;
  --help|-h)
    echo "Usage: voice.sh --pause | --resume | --toggle | --status"; exit 0 ;;
  --*)
    echo "Unknown option: $1" >&2; exit 1 ;;
esac

INPUT=$(cat)

# --- Check paused state ---
[ -f "$PAUSED_FILE" ] && exit 0

# --- Load config ---
eval "$(/usr/bin/python3 -c "
import json, shlex
try:
    c = json.load(open('$CONFIG'))
except:
    c = {}
print('ENABLED=' + shlex.quote(str(c.get('enabled', True)).lower()))
print('VOICE=' + shlex.quote(c.get('voice', 'Samantha')))
print('RATE=' + shlex.quote(str(c.get('rate', 200))))
evts = c.get('events', {})
print('EVT_START=' + shlex.quote(str(evts.get('start', True)).lower()))
print('EVT_STOP=' + shlex.quote(str(evts.get('stop', True)).lower()))
print('EVT_PERMISSION=' + shlex.quote(str(evts.get('permission', True)).lower()))
print('EVT_FAILURE=' + shlex.quote(str(evts.get('failure', True)).lower()))
print('START_PHRASE=' + shlex.quote(c.get('start_phrase', '')))
" 2>/dev/null)"

[ "$ENABLED" = "false" ] && exit 0

# --- Parse event fields ---
eval "$(/usr/bin/python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
print('EVENT=' + shlex.quote(d.get('hook_event_name', '')))
print('NTYPE=' + shlex.quote(d.get('notification_type', '')))
print('CWD=' + shlex.quote(d.get('cwd', '')))
print('SESSION_ID=' + shlex.quote(d.get('session_id', '')))
print('PERM_MODE=' + shlex.quote(d.get('permission_mode', '')))
" <<< "$INPUT" 2>/dev/null)"

# --- Skip agent/teammate sessions ---
if [ "$PERM_MODE" = "delegate" ]; then
  exit 0
fi

# --- Get repo name and branch name ---
REPO=""
BRANCH=""
if [ -n "$CWD" ]; then
  GIT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$GIT_ROOT" ]; then
    REPO="${GIT_ROOT##*/}"
    BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
  fi
fi
# Fall back to folder name if not a git repo
if [ -z "$REPO" ]; then
  REPO="${CWD##*/}"
fi
[ -z "$REPO" ] && REPO="project"

# --- Sanitize for speech ---
# feature/auth-login -> "feature auth login"
sanitize() { printf '%s' "$1" | tr '/_-' '   ' | tr -s ' '; }
SPOKEN_REPO=$(sanitize "$REPO")
SPOKEN_BRANCH=$(sanitize "$BRANCH")

# Build the identifier: "repo, branch" or just "repo" if no branch
if [ -n "$SPOKEN_BRANCH" ] && [ "$SPOKEN_BRANCH" != "$SPOKEN_REPO" ]; then
  IDENT="$SPOKEN_REPO, $SPOKEN_BRANCH"
else
  IDENT="$SPOKEN_REPO"
fi

# --- Use CLAUDE_VOICE_NAME if set ---
if [ -n "${CLAUDE_VOICE_NAME:-}" ]; then
  IDENT=$(sanitize "$CLAUDE_VOICE_NAME")
fi

# --- Session tracking (detect multiple sessions on same repo+branch) ---
SESSIONS_FILE="$VOICE_DIR/.sessions.json"
REPO_BRANCH="${REPO}/${BRANCH}"

track_session() {
  /usr/bin/python3 -c "
import json, os, sys
sf = '$SESSIONS_FILE'
sid = '$SESSION_ID'
key = '$REPO_BRANCH'
mode = sys.argv[1]
try:
    sessions = json.load(open(sf))
except:
    sessions = {}
if mode == 'register':
    lst = sessions.setdefault(key, [])
    if sid not in lst:
        lst.append(sid)
    json.dump(sessions, open(sf, 'w'))
    print(str(lst.index(sid) + 1) + '/' + str(len(lst)))
elif mode == 'unregister':
    lst = sessions.get(key, [])
    if sid in lst:
        lst.remove(sid)
    if not lst:
        sessions.pop(key, None)
    json.dump(sessions, open(sf, 'w'))
    # Report count of remaining sessions on this key
    print(str(len(lst)))
elif mode == 'lookup':
    lst = sessions.get(key, [])
    if sid in lst:
        print(str(lst.index(sid) + 1) + '/' + str(len(lst)))
    else:
        print('1/1')
" "$1" 2>/dev/null
}

# --- Append session number if multiple sessions on same branch ---
append_session_number() {
  local track="$1"
  local num="${track%%/*}"
  local total="${track##*/}"
  if [ "$total" -gt 1 ] 2>/dev/null; then
    IDENT="$IDENT, session $num"
  fi
}

# --- Determine what to say ---
SAY_TEXT=""

case "$EVENT" in
  SessionStart)
    [ "$EVT_START" = "false" ] && exit 0
    TRACK=$(track_session register)
    append_session_number "$TRACK"
    if [ -n "${START_PHRASE:-}" ]; then
      SAY_TEXT="$START_PHRASE"
    else
      PHRASES=("let's go" "let's do this" "here we go" "let's cook" "showtime" "let's build" "let's roll")
      SAY_TEXT="${PHRASES[$((RANDOM % ${#PHRASES[@]}))]}"
    fi
    ;;
  Stop)
    [ "$EVT_STOP" = "false" ] && exit 0
    # Lookup before unregistering so we still know our number
    TRACK=$(track_session lookup)
    append_session_number "$TRACK"
    track_session unregister >/dev/null
    SAY_TEXT="$IDENT"
    ;;
  Notification)
    if [ "$NTYPE" = "permission_prompt" ]; then
      [ "$EVT_PERMISSION" = "false" ] && exit 0
      TRACK=$(track_session lookup)
      append_session_number "$TRACK"
      SAY_TEXT="$IDENT, needs approval"
    else
      # idle_prompt or other — skip (Stop already spoke)
      exit 0
    fi
    ;;
  PostToolUseFailure)
    [ "$EVT_FAILURE" = "false" ] && exit 0
    TRACK=$(track_session lookup)
    append_session_number "$TRACK"
    SAY_TEXT="$IDENT, tool failed"
    ;;
  *)
    exit 0
    ;;
esac

[ -z "$SAY_TEXT" ] && exit 0

# --- Speak in background so we don't block the hook timeout ---
nohup say -v "$VOICE" -r "$RATE" "$SAY_TEXT" >/dev/null 2>&1 &

exit 0
