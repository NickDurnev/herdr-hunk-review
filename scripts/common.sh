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
  if mkdir "$lock" 2>/dev/null; then return 0; fi
  # Break a lock older than the stale threshold; a killed hook must not wedge the session.
  if [ -d "$lock" ]; then
    now=$(date +%s)
    then_=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
    if [ $((now - then_)) -gt "$HHR_LOCK_STALE_SECONDS" ]; then
      # Claim the break by renaming: only one racer can move a given directory away,
      # so only that racer goes on to re-acquire. A blind `rm -rf` here would let a
      # second racer delete the winner's fresh lock and acquire it as well.
      if mv "$lock" "$lock.stale.$$" 2>/dev/null; then
        rm -rf "$lock.stale.$$"
        mkdir "$lock" 2>/dev/null && return 0
      fi
    fi
  fi
  return 1
}

hhr_unlock() { rm -rf "$1/.lock"; }
