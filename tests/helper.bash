setup_scratch() {
  SCRATCH="$(mktemp -d)"
  export CLAUDE_PLUGIN_DATA="$SCRATCH/data"
  mkdir -p "$CLAUDE_PLUGIN_DATA"
  export HHR_ROOT="$BATS_TEST_DIRNAME/.."

  # The suite must NEVER touch the real herdr or hunk. These tests run inside a live
  # herdr session, so without this a test that reaches hhr_pane_ensure splits a REAL
  # pane in the user's terminal and abandons it when the scratch dir is torn down.
  # Two independent guards, because either alone has failed in practice:
  #   1. clear the env flag every pane code path checks first
  #   2. shadow both binaries with inert stubs on PATH
  unset HERDR_ENV
  HHR_STUB_BIN="$SCRATCH/default-bin"
  mkdir -p "$HHR_STUB_BIN"
  for b in herdr hunk; do
    printf '#!/bin/sh\nexit 0\n' > "$HHR_STUB_BIN/$b"
    chmod +x "$HHR_STUB_BIN/$b"
  done
  export PATH="$HHR_STUB_BIN:$PATH"
}

teardown_scratch() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
}

# Makes a git repo at $1 with one committed file, and echoes the path.
make_repo() {
  repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  printf 'line1\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

# Emits a PostToolUse payload: session_id, agent_id, file_path
post_tool_payload() {
  jq -nc --arg s "$1" --arg a "$2" --arg f "$3" \
    '{session_id:$s, agent_id:$a, hook_event_name:"PostToolUse",
      tool_name:"Edit", tool_input:{file_path:$f}}'
}

# Emits a SubagentStop payload: session_id, agent_id, agent_type, agent_output
subagent_stop_payload() {
  jq -nc --arg s "$1" --arg a "$2" --arg t "$3" --arg o "$4" \
    '{session_id:$s, agent_id:$a, agent_type:$t, agent_output:$o,
      hook_event_name:"SubagentStop"}'
}

# Emits a SessionEnd payload: session_id
session_end_payload() {
  jq -nc --arg s "$1" '{session_id:$s, hook_event_name:"SessionEnd"}'
}
