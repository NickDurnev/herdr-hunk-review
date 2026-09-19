load helper

setup()    { setup_scratch; REPO="$(cd "$(make_repo "$SCRATCH/repoA")" && pwd -P)"; }
teardown() { teardown_scratch; }

@test "prebaseline captures a baseline that EXCLUDES the edit that follows" {
  # The whole point: PostToolUse is too late, because by then the edit is in the tree.
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/prebaseline.sh"' _ \
    "$(post_tool_payload s20 a1 "$REPO/tracked.txt")" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  printf 'the session change\n' >> "$REPO/tracked.txt"
  base="$(jq -r --arg r "$(cd "$REPO" && pwd -P)" '.repos[$r].baseline' \
          "$CLAUDE_PLUGIN_DATA/sessions/s20/state.json")"
  run git -C "$REPO" diff "$base"
  [ "$status" -eq 0 ]
  # The edit made AFTER the snapshot must be visible in the diff.
  case "$output" in *"the session change"*) : ;; *) echo "edit was swallowed"; false ;; esac
}

@test "prebaseline handles a file that does not exist yet" {
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/prebaseline.sh"' _ \
    "$(post_tool_payload s21 a1 "$REPO/brand/new/deep.txt")" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos | length' "$CLAUDE_PLUGIN_DATA/sessions/s21/state.json")" -eq 1 ]
}

@test "prebaseline is silent on stdout" {
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/prebaseline.sh"' _ \
    "$(post_tool_payload s22 a1 "$REPO/tracked.txt")" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
