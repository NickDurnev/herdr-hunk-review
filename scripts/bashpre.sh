#!/bin/sh
# PreToolUse (Bash): snapshot every repo the command might write to, BEFORE it runs.
# Edit/Write name their file; a Bash edit (`sed -i`, `python3 - <<PY`, `cat > f`) does
# not, so without this an agent that edits through the shell leaves no trace and the
# pane stays empty. Nothing is recorded in state.json here - bashtrack.sh compares
# against these snapshots afterwards and records only a repo the command really changed,
# so read-only commands (the vast majority) never add a repo to the diff.
set -e
. "$(dirname "$0")/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
id=$(printf '%s' "$payload" | jq -r '.tool_use_id // empty' | tr -cd 'A-Za-z0-9_-')
[ -n "$id" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_debug_payload "$dir" "$payload"
hhr_guard "$dir"

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Keyed by tool_use_id, never shared: bashtrack.sh runs async, so the next Bash call's
# snapshot may land before this call's comparison has read its own.
pend="$dir/bash"
mkdir -p "$pend" || exit 0
out="$pend/$id.tsv"
: > "$out.tmp"
n=0
hhr_bash_candidate_roots "$cwd" "$cmd" > "$pend/$id.roots" || true
while IFS= read -r root; do
  [ -n "$root" ] || continue
  snap=$(hhr_snapshot_repo "$root") || continue
  n=$((n + 1))
  git -C "$root" ls-files --others --exclude-standard 2>/dev/null | sort > "$pend/$id.$n.u" || :
  printf '%s\t%s\t%s\n' "$root" "$snap" "$pend/$id.$n.u" >> "$out.tmp"
done < "$pend/$id.roots"
rm -f "$pend/$id.roots"
mv "$out.tmp" "$out"
exit 0
