# Sourced, not executed. POSIX sh; bash 3.2 compatible.
HHR_LOCK_STALE_SECONDS=30

hhr_have() { command -v "$1" >/dev/null 2>&1; }

hhr_state_root() {
  # CLAUDE_PLUGIN_DATA is set by the harness; fall back for tests and manual runs.
  printf '%s' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/herdr-hunk-review}/sessions"
}

hhr_state_dir() {
  d="$(hhr_state_root)/$1"
  mkdir -p "$d" || return 1
  printf '%s' "$d"
}

hhr_json_get() { jq -r --arg k "$1" '.[$k] // empty'; }

# Diagnostic aid, off by default. When HHR_DEBUG_PAYLOAD=1, append the raw hook
# payload as one JSON line to <dir>/payloads-<hook_event_name>.jsonl, so the real
# shape of a payload (field names, nulls vs empty strings) can be inspected later.
# Complete no-op - no file touched, no stdout - when the variable is unset.
hhr_debug_payload() {
  [ "${HHR_DEBUG_PAYLOAD:-}" = 1 ] || return 0
  [ -n "$1" ] && [ -n "$2" ] || return 0
  evt=$(printf '%s' "$2" | jq -r '.hook_event_name // "unknown"' 2>/dev/null) || evt=unknown
  printf '%s\n' "$2" >> "$1/payloads-$evt.jsonl" 2>/dev/null || true
  return 0
}

# Exit the CALLING script 0 when the plugin must not act. Recording (prebaseline.sh,
# track.sh, note.sh) must run whether or not the session is paused - only refresh.sh
# gates on the `paused` marker, so pausing stops the pane from updating without losing
# the edits made while it was paused.
hhr_guard() {
  hhr_have jq  || exit 0
  hhr_have git || exit 0
  return 0
}

hhr_lock() {
  lock="$1/.lock"
  brk="$1/.lockbreak"
  attempts=0
  # ~5s total (50 * 0.1s): parallel subagents finishing together is the normal case
  # for this plugin, so a single failed mkdir must not drop a caller's write - retry
  # for a bounded window before giving up.
  while [ "$attempts" -lt 50 ]; do
    mkdir "$lock" 2>/dev/null && return 0
    # Contended. Serialise stale-breaking behind a second lock so the staleness test and
    # the break cannot interleave: a racer that measured the OLD lock must not be able to
    # destroy the fresh lock a winner has since created. Measured over 30 concurrent
    # trials: blind rm -rf yields >1 winner 27/30, claim-by-rename 1/30, this 0/30.
    if mkdir "$brk" 2>/dev/null; then
      if [ -d "$lock" ]; then
        now=$(date +%s)
        then_=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
        if [ $((now - then_)) -gt "$HHR_LOCK_STALE_SECONDS" ]; then
          rm -rf "$lock"
          if mkdir "$lock" 2>/dev/null; then
            rmdir "$brk" 2>/dev/null
            return 0
          fi
        fi
      fi
      rmdir "$brk" 2>/dev/null
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

hhr_unlock() { rm -rf "$1/.lock"; }
