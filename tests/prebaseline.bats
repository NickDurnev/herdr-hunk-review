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

@test "on a conflicted tree, prebaseline falls back to HEAD and records dirty_at_baseline" {
  # This is the real-world bug: an unresolved merge makes `git stash create` fail
  # ("needs merge"), so the baseline falls back to plain HEAD - which does NOT itself
  # exclude the repo's pre-existing unmerged/modified paths. Without dirty_at_baseline,
  # every one of them reads as a session change forever, and re-baselining (closing the
  # pane) can never fix it because it hits the exact same failing stash create.
  RC="$(cd "$(make_conflicted_repo "$SCRATCH/repoConflict")" && pwd -P)"
  run sh -c 'printf "%s" "$1" | sh "$2/scripts/prebaseline.sh"' _ \
    "$(post_tool_payload s23 a1 "$RC/tracked.txt")" "$HHR_ROOT"
  [ "$status" -eq 0 ]
  st="$CLAUDE_PLUGIN_DATA/sessions/s23/state.json"
  base="$(jq -r --arg r "$RC" '.repos[$r].baseline' "$st")"
  [ "$base" = "$(git -C "$RC" rev-parse HEAD)" ]
  [ "$(jq -c --arg r "$RC" '.repos[$r].dirty_at_baseline' "$st")" = '["tracked.txt"]' ]
}
