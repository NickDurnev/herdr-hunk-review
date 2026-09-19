load helper

setup() {
  setup_scratch
  REPO="$(make_repo "$SCRATCH/repoA")"
  DIR="$CLAUDE_PLUGIN_DATA/sessions/s1"; mkdir -p "$DIR"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  jq -nc --arg r "$REPO" --arg b "$BASE" \
    '{repos:{($r):{baseline:$b,prefix:"repoA"}},agents:{}}' > "$DIR/state.json"
}
teardown() { teardown_scratch; }

@test "re-snapshotting moves the baseline past current changes" {
  printf 'reviewed\n' >> "$REPO/tracked.txt"
  old="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  sh "$HHR_ROOT/scripts/baseline.sh" s1
  new="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$DIR/state.json")"
  [ "$old" != "$new" ]
  run git -C "$REPO" diff "$new"
  [ -z "$output" ]
}

@test "clears stored agent notes so old reports do not linger" {
  jq '.agents = {a1:{type:"t",output:"o",files:["/f"]}}' "$DIR/state.json" > "$DIR/t" && mv "$DIR/t" "$DIR/state.json"
  sh "$HHR_ROOT/scripts/baseline.sh" s1
  [ "$(jq -r '.agents | length' "$DIR/state.json")" -eq 0 ]
}

@test "is silent and exits 0" {
  run sh "$HHR_ROOT/scripts/baseline.sh" s1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
