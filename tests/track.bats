load helper

setup()    { setup_scratch; REPO="$(make_repo "$SCRATCH/repoA")"; }
teardown() { teardown_scratch; }

run_track() { printf '%s' "$1" | sh "$HHR_ROOT/scripts/track.sh"; }

@test "records the repo, a baseline and the file" {
  run_track "$(post_tool_payload s1 agent1 "$REPO/tracked.txt")"
  st="$(cat "$CLAUDE_PLUGIN_DATA/sessions/s1/state.json")"
  [ "$(printf '%s' "$st" | jq -r --arg r "$REPO" '.repos[$r].prefix')" = "repoA" ]
  [ "$(printf '%s' "$st" | jq -r --arg r "$REPO" '.repos[$r].baseline | length')" -eq 40 ]
  [ "$(printf '%s' "$st" | jq -r '.agents.agent1.files[0]')" = "$REPO/tracked.txt" ]
}

@test "baseline captures pre-existing drift so it is excluded later" {
  printf 'drift\n' >> "$REPO/tracked.txt"
  run_track "$(post_tool_payload s2 agent1 "$REPO/tracked.txt")"
  base="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$CLAUDE_PLUGIN_DATA/sessions/s2/state.json")"
  run git -C "$REPO" diff "$base"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "baseline is captured once and not overwritten" {
  run_track "$(post_tool_payload s3 agent1 "$REPO/tracked.txt")"
  first="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$CLAUDE_PLUGIN_DATA/sessions/s3/state.json")"
  printf 'more\n' >> "$REPO/tracked.txt"
  run_track "$(post_tool_payload s3 agent1 "$REPO/tracked.txt")"
  second="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$CLAUDE_PLUGIN_DATA/sessions/s3/state.json")"
  [ "$first" = "$second" ]
}

@test "falls back to HEAD on a clean tree" {
  run_track "$(post_tool_payload s4 agent1 "$REPO/tracked.txt")"
  base="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$CLAUDE_PLUGIN_DATA/sessions/s4/state.json")"
  [ "$base" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "falls back to HEAD when stash create fails on a conflicted tree" {
  # Build a real merge conflict, which makes `git stash create` fail.
  git -C "$REPO" checkout -q -b other
  printf 'theirs\n' > "$REPO/tracked.txt"
  git -C "$REPO" commit -qam theirs
  git -C "$REPO" checkout -q -
  printf 'ours\n' > "$REPO/tracked.txt"
  git -C "$REPO" commit -qam ours
  git -C "$REPO" merge other >/dev/null 2>&1 || true
  run run_track "$(post_tool_payload s9 a1 "$REPO/tracked.txt")"
  [ "$status" -eq 0 ]
  base="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$CLAUDE_PLUGIN_DATA/sessions/s9/state.json")"
  [ -n "$base" ]
  [ "$base" != "null" ]
}

@test "works on a detached HEAD" {
  git -C "$REPO" checkout -q --detach HEAD
  run run_track "$(post_tool_payload s10 a1 "$REPO/tracked.txt")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos | length' "$CLAUDE_PLUGIN_DATA/sessions/s10/state.json")" -eq 1 ]
}

@test "a file outside any repo is ignored without error" {
  printf 'x\n' > "$SCRATCH/loose.txt"
  run run_track "$(post_tool_payload s5 agent1 "$SCRATCH/loose.txt")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos | length' "$CLAUDE_PLUGIN_DATA/sessions/s5/state.json")" -eq 0 ]
}

@test "deduplicates prefixes across two worktrees of one repo" {
  R2="$(make_repo "$SCRATCH/repoA-wt")"
  run_track "$(post_tool_payload s6 a1 "$REPO/tracked.txt")"
  run_track "$(post_tool_payload s6 a1 "$R2/tracked.txt")"
  p1="$(jq -r --arg r "$REPO" '.repos[$r].prefix' "$CLAUDE_PLUGIN_DATA/sessions/s6/state.json")"
  p2="$(jq -r --arg r "$R2"   '.repos[$r].prefix' "$CLAUDE_PLUGIN_DATA/sessions/s6/state.json")"
  [ "$p1" != "$p2" ]
}

@test "handles a path containing a space" {
  R3="$(make_repo "$SCRATCH/repo with space")"
  run run_track "$(post_tool_payload s7 a1 "$R3/tracked.txt")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos | length' "$CLAUDE_PLUGIN_DATA/sessions/s7/state.json")" -eq 1 ]
}

@test "exits 0 and writes nothing to stdout" {
  run run_track "$(post_tool_payload s8 a1 "$REPO/tracked.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
