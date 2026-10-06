load helper

setup() {
  setup_scratch
  REPO="$(cd "$(make_repo "$SCRATCH/repoA")" && pwd -P)"
  OTHER="$(cd "$(make_repo "$SCRATCH/repoB")" && pwd -P)"
}
teardown() { teardown_scratch; }

# Emits a Bash Pre/PostToolUse payload: session_id, agent_id, tool_use_id, cwd, command
bash_payload() {
  jq -nc --arg s "$1" --arg a "$2" --arg t "$3" --arg c "$4" --arg cmd "$5" \
    '{session_id:$s, tool_use_id:$t, cwd:$c, tool_name:"Bash", tool_input:{command:$cmd}}
     + (if $a != "main" then {agent_id:$a} else {} end)'
}

pre()  { printf '%s' "$1" | sh "$HHR_ROOT/scripts/bashpre.sh"; }
post() { printf '%s' "$1" | sh "$HHR_ROOT/scripts/bashtrack.sh"; }

# Runs a command the way the harness would: Pre hook, the command in CWD, Post hook.
run_bash() {
  session="$1" agent="$2" id="$3" cwd="$4" cmd="$5"
  p="$(bash_payload "$session" "$agent" "$id" "$cwd" "$cmd")"
  pre "$p"
  ( cd "$cwd" && sh -c "$cmd" ) >/dev/null 2>&1 || true
  post "$p"
}

@test "an edit made through Bash in the shell's cwd is tracked and kept in the diff" {
  run_bash s1 main t1 "$REPO" "printf 'bash edit\n' >> tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s1/state.json"
  base="$(jq -r --arg r "$REPO" '.repos[$r].baseline' "$st")"
  [ -n "$base" ] && [ "$base" != null ]
  run git -C "$REPO" diff "$base"
  case "$output" in *"bash edit"*) : ;; *) echo "edit was swallowed"; false ;; esac
  [ "$(jq -r '.agents.main.files[0]' "$st")" = "$REPO/tracked.txt" ]
}

@test "a read-only Bash command records nothing" {
  run_bash s2 main t2 "$REPO" "git status && cat tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s2/state.json"
  [ ! -f "$st" ] || [ "$(jq -r '.repos | length' "$st")" -eq 0 ]
}

@test "a cd target inside the command is snapshotted, not just the cwd" {
  run_bash s3 main t3 "$SCRATCH" "cd $OTHER && printf 'x\n' >> tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s3/state.json"
  [ "$(jq -r --arg r "$OTHER" '.repos[$r].prefix' "$st")" = repoB ]
}

@test "an absolute path written from another cwd is tracked" {
  run_bash s4 main t4 "$REPO" "printf 'y\n' >> $OTHER/tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s4/state.json"
  [ "$(jq -r --arg r "$OTHER" '.repos[$r] != null' "$st")" = true ]
  [ "$(jq -r --arg r "$REPO" '.repos[$r] == null' "$st")" = true ]
}

@test "a file created through Bash shows up in the combined patch" {
  run_bash s5 main t5 "$REPO" "printf 'brand new\n' > created.txt"
  sh "$HHR_ROOT/scripts/refresh.sh" s5
  grep -q 'brand new' "$CLAUDE_PLUGIN_DATA/sessions/s5/combined.patch"
}

@test "a pre-existing untracked file is not attributed to the Bash command" {
  printf 'old\n' > "$REPO/stale.txt"
  run_bash s6 main t6 "$REPO" "printf 'z\n' >> tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s6/state.json"
  [ "$(jq -r '.agents.main.files | length' "$st")" -eq 1 ]
}

@test "an edit committed inside the same command stays in the diff" {
  run_bash s7 main t7 "$REPO" "printf 'committed\n' >> tracked.txt && git commit -qam c"
  sh "$HHR_ROOT/scripts/refresh.sh" s7
  grep -q 'committed' "$CLAUDE_PLUGIN_DATA/sessions/s7/combined.patch"
}

@test "Bash edits are attributed to the subagent that ran them" {
  run_bash s8 sub1 t8 "$REPO" "printf 'sub\n' >> tracked.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s8/state.json"
  [ "$(jq -r '.agents.sub1.files[0]' "$st")" = "$REPO/tracked.txt" ]
}

@test "per-call snapshot files are cleaned up" {
  run_bash s9 main t9 "$REPO" "printf 'q\n' >> tracked.txt"
  [ -z "$(ls -A "$CLAUDE_PLUGIN_DATA/sessions/s9/bash")" ]
}

@test "bash hooks are silent on stdout" {
  p="$(bash_payload s10 main t10 "$REPO" "printf 'q\n' >> tracked.txt")"
  run pre "$p"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  printf 'q\n' >> "$REPO/tracked.txt"
  run post "$p"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "a cwd outside any repo exits cleanly" {
  run_bash s11 main t11 "$SCRATCH" "printf 'q\n' > loose.txt"
  st="$CLAUDE_PLUGIN_DATA/sessions/s11/state.json"
  [ ! -f "$st" ] || [ "$(jq -r '.repos | length' "$st")" -eq 0 ]
}
