load helper

setup()    { setup_scratch; REPO="$(cd "$(make_repo "$SCRATCH/repoA")" && pwd -P)"; }
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
  [ "${#base}" -eq 40 ]
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

@test "deduplicates prefixes for two unrelated repos sharing a basename" {
  R2="$(cd "$(make_repo "$SCRATCH/repoA-wt")" && pwd -P)"
  run_track "$(post_tool_payload s6 a1 "$REPO/tracked.txt")"
  run_track "$(post_tool_payload s6 a1 "$R2/tracked.txt")"
  p1="$(jq -r --arg r "$REPO" '.repos[$r].prefix' "$CLAUDE_PLUGIN_DATA/sessions/s6/state.json")"
  p2="$(jq -r --arg r "$R2"   '.repos[$r].prefix' "$CLAUDE_PLUGIN_DATA/sessions/s6/state.json")"
  [ "$p1" != "$p2" ]
}

@test "handles a path containing a space" {
  R3="$(cd "$(make_repo "$SCRATCH/repo with space")" && pwd -P)"
  run run_track "$(post_tool_payload s7 a1 "$R3/tracked.txt")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repos | length' "$CLAUDE_PLUGIN_DATA/sessions/s7/state.json")" -eq 1 ]
}

@test "exits 0 and writes nothing to stdout" {
  run run_track "$(post_tool_payload s8 a1 "$REPO/tracked.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tracks a file inside a real git worktree" {
  # In a linked worktree `.git` is a file containing `gitdir: ...`, not a directory.
  # A hand-rolled walk that tests `-d .git` finds nothing here and silently drops the
  # change; if the worktree sits inside another repo it attributes the file to the
  # enclosing repo instead. Worktrees are this plugin's primary use case.
  git -C "$REPO" worktree add -q "$SCRATCH/repoA-live-wt" -b wtbranch
  [ -f "$SCRATCH/repoA-live-wt/.git" ]
  printf 'in worktree\n' >> "$SCRATCH/repoA-live-wt/tracked.txt"
  run run_track "$(post_tool_payload s11 a1 "$SCRATCH/repoA-live-wt/tracked.txt")"
  [ "$status" -eq 0 ]
  st="$CLAUDE_PLUGIN_DATA/sessions/s11/state.json"
  [ "$(jq -r '.repos | length' "$st")" -eq 1 ]
  # The recorded root must be the worktree itself, not the repo it was created from.
  root="$(jq -r '.repos | keys[0]' "$st")"
  case "$root" in *repoA-live-wt) : ;; *) echo "wrong root: $root"; false ;; esac
}

@test "records the repo root as git reports it, so prefix matching works" {
  # The stored root must be a prefix of the stored file path, or Task 5 cannot map an
  # absolute path onto its repo prefix.
  run_track "$(post_tool_payload s12 a1 "$REPO/tracked.txt")"
  st="$CLAUDE_PLUGIN_DATA/sessions/s12/state.json"
  root="$(jq -r '.repos | keys[0]' "$st")"
  f="$(jq -r '.agents.a1.files[0]' "$st")"
  case "$f" in "$root"/*) : ;; *) echo "file '$f' is not under root '$root'"; false ;; esac
}
