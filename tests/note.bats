load helper

setup() {
  setup_scratch
  REPO="$(make_repo "$SCRATCH/repoA")"
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  jq -nc --arg r "$REPO" --arg b "$BASE" --arg f "$REPO/tracked.txt" \
    '{repos:{($r):{baseline:$b,prefix:"repoA"}},
      agents:{a1:{type:"",output:"",files:[$f]}}}' > "$DIR/state.json"
  printf 'change\n' >> "$REPO/tracked.txt"
  # $SCRATCH only exists after setup_scratch runs, so this must be assigned here,
  # not at file scope (bats evaluates file-scope statements once at load time,
  # before any setup() has run, which would bake in an empty/stale $SCRATCH).
  TRANSCRIPT="$SCRATCH/transcripts/main.jsonl"
}
teardown() { teardown_scratch; }

# A copy of scripts/ whose common.sh has the HHR_NOTE_MAX_CHARS assignment stripped
# out, so a script run from here sources "a common.sh" but the constant is genuinely
# unset - the same hazard as HHR_NOTE_MAX_CHARS being unset for any other reason
# (common.sh not sourced, a future edit removing the line, etc), reproduced faithfully
# rather than simulated by hand-editing the environment mid-script.
setup_scripts_without_max_chars_const() {
  NO_CONST="$SCRATCH/scripts-no-const"
  cp -R "$HHR_ROOT/scripts" "$NO_CONST"
  grep -v '^HHR_NOTE_MAX_CHARS=' "$HHR_ROOT/scripts/common.sh" > "$NO_CONST/common.sh.tmp"
  mv "$NO_CONST/common.sh.tmp" "$NO_CONST/common.sh"
}

@test "stores the agent type and output" {
  printf '%s' "$(subagent_stop_payload s1 a1 impl-handler 'Made the dep required.')" \
    | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents.a1.type'   "$DIR/state.json")" = "impl-handler" ]
  [ "$(jq -r '.agents.a1.output' "$DIR/state.json")" = "Made the dep required." ]
}

@test "creates the agent entry when PostToolUse never ran for it" {
  printf '%s' "$(subagent_stop_payload s1 brand-new reviewer 'looked at it')" \
    | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents["brand-new"].type' "$DIR/state.json")" = "reviewer" ]
}

@test "triggers a refresh" {
  printf '%s' "$(subagent_stop_payload s1 a1 impl 'note')" | sh "$HHR_ROOT/scripts/note.sh"
  [ -s "$DIR/combined.patch" ]
}

@test "tolerates an empty output" {
  run sh -c "printf '%s' '$(subagent_stop_payload s1 a1 impl "")' | sh '$HHR_ROOT/scripts/note.sh'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.agents.a1.type' "$DIR/state.json")" = "impl" ]
}

@test "is silent on stdout" {
  run sh -c "printf '%s' '$(subagent_stop_payload s1 a1 impl note)' | sh '$HHR_ROOT/scripts/note.sh'"
  [ -z "$output" ]
}

@test "does not write a debug payload file when HHR_DEBUG_PAYLOAD is unset" {
  unset HHR_DEBUG_PAYLOAD
  printf '%s' "$(subagent_stop_payload s1 a1 impl note)" | sh "$HHR_ROOT/scripts/note.sh"
  run sh -c 'ls "$1"/payloads-*.jsonl 2>/dev/null' _ "$DIR"
  [ -z "$output" ]
}

@test "writes one debug payload line when HHR_DEBUG_PAYLOAD=1" {
  export HHR_DEBUG_PAYLOAD=1
  printf '%s' "$(subagent_stop_payload s1 a1 impl note)" | sh "$HHR_ROOT/scripts/note.sh"
  [ -f "$DIR/payloads-SubagentStop.jsonl" ]
  [ "$(wc -l < "$DIR/payloads-SubagentStop.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "init creates the state directory" {
  printf '{"session_id":"fresh","hook_event_name":"SessionStart"}' | sh "$HHR_ROOT/scripts/init.sh"
  [ -d "$CLAUDE_PLUGIN_DATA/sessions/fresh" ]
}

# --- transcript fallback: agent_output is always empty in real payloads, so the
# closing report has to come from the subagent's own transcript instead. ---

@test "payload agent_output is preferred and marks note_source payload" {
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$(assistant_text_record 'from the transcript, not used')"
  printf '%s' "$(subagent_stop_payload s1 a1 impl 'from the payload' "$TRANSCRIPT")" \
    | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents.a1.output'      "$DIR/state.json")" = "from the payload" ]
  [ "$(jq -r '.agents.a1.note_source' "$DIR/state.json")" = "payload" ]
}

@test "falls back to the transcript when agent_output is empty" {
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$(assistant_text_record 'Correction to brief: fixed the ordering.')"
  printf '%s' "$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")" | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents.a1.output'      "$DIR/state.json")" = "Correction to brief: fixed the ordering." ]
  [ "$(jq -r '.agents.a1.note_source' "$DIR/state.json")" = "transcript" ]
}

@test "picks the LAST assistant record, not an earlier one" {
  line1="$(assistant_text_record 'first draft, superseded')"
  line2='{"type":"user","message":{"content":[{"type":"text","text":"go on"}]}}'
  line3="$(assistant_text_record 'final report')"
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$line1
$line2
$line3"
  printf '%s' "$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")" | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents.a1.output' "$DIR/state.json")" = "final report" ]
}

@test "missing transcript file degrades to no note, silently" {
  # No write_subagent_transcript call - the derived file never exists.
  run sh -c "printf '%s' '$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")' | sh '$HHR_ROOT/scripts/note.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.agents.a1.output'      "$DIR/state.json")" = "" ]
  [ "$(jq -r '.agents.a1.note_source' "$DIR/state.json")" = "none" ]
  # note_source:none must still be recorded - it's the diagnostic signal that
  # extraction was attempted and failed, not silence that could mean anything.
  # And track.sh's files array (seeded in setup()) must survive untouched.
  [ "$(jq -r '.agents.a1.files[0]' "$DIR/state.json")" = "$REPO/tracked.txt" ]
}

@test "malformed transcript JSON degrades to no note, silently" {
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "not json at all
{ also not valid"
  run sh -c "printf '%s' '$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")' | sh '$HHR_ROOT/scripts/note.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.agents.a1.output'      "$DIR/state.json")" = "" ]
  [ "$(jq -r '.agents.a1.note_source' "$DIR/state.json")" = "none" ]
}

@test "transcript with no assistant text degrades to no note" {
  norec='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$norec"
  printf '%s' "$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")" | sh "$HHR_ROOT/scripts/note.sh"
  [ "$(jq -r '.agents.a1.output'      "$DIR/state.json")" = "" ]
  [ "$(jq -r '.agents.a1.note_source' "$DIR/state.json")" = "none" ]
}

@test "a very long report is truncated to the existing note-length limit" {
  long=""; i=0
  while [ "$i" -lt 500 ]; do long="${long}a"; i=$((i + 1)); done
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$(assistant_text_record "$long")"
  printf '%s' "$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")" | sh "$HHR_ROOT/scripts/note.sh"
  got="$(jq -r '.agents.a1.output' "$DIR/state.json")"
  [ "${#got}" -eq 300 ]
}

# --- HHR_NOTE_MAX_CHARS guard: an unset/empty constant must not mean no notes ---

@test "note.sh still stores a note when HHR_NOTE_MAX_CHARS is unset" {
  setup_scripts_without_max_chars_const
  printf '%s' "$(subagent_stop_payload s1 a1 impl-handler 'Real note.')" \
    | sh "$NO_CONST/note.sh"
  [ "$(jq -r '.agents.a1.output' "$DIR/state.json")" = "Real note." ]
}

@test "note.sh's truncation path still works when HHR_NOTE_MAX_CHARS is unset" {
  setup_scripts_without_max_chars_const
  long=""; i=0
  while [ "$i" -lt 500 ]; do long="${long}a"; i=$((i + 1)); done
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$(assistant_text_record "$long")"
  printf '%s' "$(subagent_stop_payload s1 a1 impl '' "$TRANSCRIPT")" | sh "$NO_CONST/note.sh"
  got="$(jq -r '.agents.a1.output' "$DIR/state.json")"
  # Falls back to the built-in default (300) - the same number common.sh configures,
  # so this also confirms the guard didn't silently pick a different length.
  [ "${#got}" -eq 300 ]
}

@test "a transcript-sourced note reaches the sidecar as a ranged annotation" {
  write_subagent_transcript "$TRANSCRIPT" s1 a1 "$(assistant_text_record 'fixed the session-matching key')"
  printf '%s' "$(subagent_stop_payload s1 a1 impl-handler '' "$TRANSCRIPT")" | sh "$HHR_ROOT/scripts/note.sh"
  [ -f "$DIR/agent-context.json" ]
  jq -e '.files[] | select(.path == "repoA/tracked.txt")
         | .annotations[] | select(.summary | test("fixed the session-matching key"))' \
    "$DIR/agent-context.json"
}
