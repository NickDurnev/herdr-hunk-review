#!/bin/sh
# SubagentStop: keep the subagent's closing report, then refresh.
#
# agent_output on the SubagentStop payload is the documented source for this text,
# but measured across 104 real subagents it is ALWAYS empty - the text simply isn't
# there. When that happens, fall back to the subagent's own transcript: the harness
# writes one JSONL file per subagent at a path derivable from fields already on the
# payload (see below), and the subagent's closing report is the text of the LAST
# assistant record in it. This is a harness-internal layout, not a documented
# contract - see README's "Where agent notes come from" for what happens if it
# changes, and check note_source in state.json to tell payload/transcript/none apart.
set -e
here="$(dirname "$0")"
. "$here/common.sh"

payload=$(cat)
hhr_have jq || exit 0

session=$(printf '%s' "$payload" | hhr_json_get session_id)
[ -n "$session" ] || exit 0
dir="$(hhr_state_dir "$session")" || exit 0
hhr_debug_payload "$dir" "$payload"
hhr_guard "$dir"

agent=$(printf '%s' "$payload" | jq -r '.agent_id // empty')
[ -n "$agent" ] || exit 0
atype=$(printf '%s' "$payload" | jq -r '.agent_type // "agent"')
output=$(printf '%s' "$payload" | jq -r '.agent_output // ""')
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')

note_source=none
note_text=""

if [ -n "$output" ]; then
  note_source=payload
  note_text=$output
elif [ -n "$transcript" ]; then
  # Each subagent's own transcript sits beside the main session transcript, under a
  # per-session "subagents" directory, named by agent id.
  subfile="$(dirname "$transcript")/$session/subagents/agent-$agent.jsonl"
  if [ -f "$subfile" ]; then
    # A closing report is a few sentences; the last few hundred lines of the
    # transcript are always enough to reach it (verified against 392-, 550- and
    # 164-line real files), and reading further risks pulling a multi-MB transcript
    # into memory for no benefit.
    extracted=$(tail -n 500 "$subfile" 2>/dev/null \
      | jq -rs '[.[] | select(.type=="assistant")] | last
                | .message.content[]? | select(.type=="text") | .text' 2>/dev/null) \
      || extracted=""
    if [ -n "$extracted" ]; then
      note_source=transcript
      note_text=$extracted
    fi
  fi
fi

# Collapse whitespace and truncate exactly the way the sidecar renders notes (same
# HHR_NOTE_MAX_CHARS, from common.sh), so a note read back out of state.json is
# already what the pane will show, regardless of which source it came from.
if [ "$note_source" != none ]; then
  note_text=$(printf '%s' "$note_text" \
    | jq -Rsr --arg m "$HHR_NOTE_MAX_CHARS" '. | gsub("\\s+"; " ") | .[0:($m|tonumber)]')
fi

state="$dir/state.json"
[ -f "$state" ] || printf '{"repos":{},"agents":{}}' > "$state"

if hhr_lock "$dir"; then
  jq --arg a "$agent" --arg t "$atype" --arg o "$note_text" --arg s "$note_source" \
     '.agents[$a] = (.agents[$a] // {type:"", output:"", files:[]})
      | .agents[$a].type = $t
      | .agents[$a].output = $o
      | .agents[$a].note_source = $s' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  hhr_unlock "$dir"
fi

sh "$here/refresh.sh" "$session" || true
exit 0
