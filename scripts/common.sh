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

# Exit the CALLING script 0 when the plugin must not act.
hhr_guard() {
  hhr_have jq  || exit 0
  hhr_have git || exit 0
  [ -e "$1/paused" ] && exit 0
  return 0
}

hhr_lock() {
  lock="$1/.lock"
  mkdir "$lock" 2>/dev/null && return 0
  # Contended. Serialise stale-breaking behind a second lock so the staleness test and
  # the break cannot interleave: a racer that measured the OLD lock must not be able to
  # destroy the fresh lock a winner has since created. Measured over 30 concurrent
  # trials: blind rm -rf yields >1 winner 27/30, claim-by-rename 1/30, this 0/30.
  brk="$1/.lockbreak"
  mkdir "$brk" 2>/dev/null || return 1
  rc=1
  if [ -d "$lock" ]; then
    now=$(date +%s)
    then_=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
    if [ $((now - then_)) -gt "$HHR_LOCK_STALE_SECONDS" ]; then
      rm -rf "$lock"
      mkdir "$lock" 2>/dev/null && rc=0
    fi
  fi
  rmdir "$brk" 2>/dev/null
  return $rc
}

hhr_unlock() { rm -rf "$1/.lock"; }
