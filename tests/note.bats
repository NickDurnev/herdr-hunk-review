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
}
teardown() { teardown_scratch; }

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

@test "init creates the state directory" {
  printf '{"session_id":"fresh","hook_event_name":"SessionStart"}' | sh "$HHR_ROOT/scripts/init.sh"
  [ -d "$CLAUDE_PLUGIN_DATA/sessions/fresh" ]
}
