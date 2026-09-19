#!/bin/sh
# Records one raw hook payload per event for fixture use. Temporary; removed in Task 12.
set -e
out_dir="${CLAUDE_PLUGIN_ROOT}/docs/payloads"
mkdir -p "$out_dir"
payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // "unknown"')
printf '%s' "$payload" > "$out_dir/${event}.json"
printf '%s\n' "--- env ---" > "$out_dir/${event}.env"
env | grep -E '^(CLAUDE_|HERDR_)' | sort >> "$out_dir/${event}.env"
exit 0
