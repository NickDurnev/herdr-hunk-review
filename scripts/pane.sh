# Sourced. Owns the herdr pane running the hunk viewer.

hhr_viewer_cmd() {
  printf 'hunk patch %s/combined.patch --agent-context %s/agent-context.json --agent-notes --watch' "$1" "$1"
}

hhr_pane_alive() {
  [ -n "$1" ] || return 1
  herdr pane list 2>/dev/null | jq -e --arg p "$1" '[.result.panes[].pane_id] | index($p)' >/dev/null 2>&1
}

hhr_pane_ensure() {
  dir="$1"
  [ "${HERDR_ENV:-}" = 1 ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  command -v hunk  >/dev/null 2>&1 || return 0
  [ -s "$dir/combined.patch" ] || return 0

  if [ -f "$dir/pane" ] && hhr_pane_alive "$(cat "$dir/pane")"; then
    return 0
  fi

  # Split the long side so neither pane becomes unusably narrow.
  w=$(herdr pane layout --current 2>/dev/null | jq -r '.result.layout.area.width // 120')
  h=$(herdr pane layout --current 2>/dev/null | jq -r '.result.layout.area.height // 40')
  if [ "$w" -gt $((h * 3)) ] 2>/dev/null; then direction=right; else direction=down; fi

  pane=$(herdr pane split --current --direction "$direction" --cwd "$dir" --no-focus 2>/dev/null \
         | jq -r '.result.pane.pane_id // empty')
  [ -n "$pane" ] || return 0
  printf '%s' "$pane" > "$dir/pane"
  herdr pane run "$pane" "$(hhr_viewer_cmd "$dir")" >/dev/null 2>&1 || true
  return 0
}

hhr_pane_restart() {
  dir="$1"
  [ -f "$dir/pane" ] || return 0
  pane=$(cat "$dir/pane")
  # pane run types into whatever occupies the pane, so the TUI must be quit first.
  herdr pane send-keys "$pane" q >/dev/null 2>&1 || true
  sleep 1
  herdr pane run "$pane" "$(hhr_viewer_cmd "$dir")" >/dev/null 2>&1 || true
  return 0
}

hhr_session_id() {
  command -v hunk >/dev/null 2>&1 || return 0
  hunk session list --json 2>/dev/null \
    | jq -r --arg d "$1" '.sessions[] | select(.cwd == $d) | .sessionId' 2>/dev/null | head -1
}
