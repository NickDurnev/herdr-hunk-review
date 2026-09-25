bats_require_minimum_version 1.5.0

load helper

setup()    { setup_scratch; }
teardown() { teardown_scratch; }

# Builds a fake installed-plugin layout at $1 (a fresh dir) matching the real one:
#   <root>/plugins/cache/<marketplace>/<plugin>/<version>/scripts/{common.sh,state-root.sh}
#   <root>/plugins/data/<plugin>-<marketplace>/sessions
# copied (not symlinked) from this repo's real scripts, so state-root.sh's own $0
# resolves to a path that actually has this shape - exercising the same dirname
# chain hhr_state_root walks against a real install. Echoes the scripts dir.
make_fake_install() {
  root="$1" marketplace="${2:-testmarket}" plugin="${3:-testplugin}" version="${4:-9.9.9}"
  scripts_dir="$root/plugins/cache/$marketplace/$plugin/$version/scripts"
  mkdir -p "$scripts_dir"
  cp "$HHR_ROOT/scripts/common.sh" "$scripts_dir/common.sh"
  cp "$HHR_ROOT/scripts/state-root.sh" "$scripts_dir/state-root.sh"
  printf '%s' "$scripts_dir"
}

@test "CLAUDE_PLUGIN_DATA set resolves to it unconditionally, even when it does not exist yet (hook path unchanged)" {
  export CLAUDE_PLUGIN_DATA="$SCRATCH/hookdata-fresh"
  run sh "$HHR_ROOT/scripts/state-root.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$SCRATCH/hookdata-fresh/sessions" ]
  # Resolving must not itself create the root - only hhr_state_dir's mkdir -p does.
  [ ! -e "$SCRATCH/hookdata-fresh" ]
}

@test "unset CLAUDE_PLUGIN_DATA with a derivable installed-layout root present resolves to it, not the legacy root" {
  scripts_dir="$(make_fake_install "$SCRATCH/fake-install")"
  derived="$SCRATCH/fake-install/plugins/data/testplugin-testmarket/sessions"
  mkdir -p "$derived"

  export HOME="$SCRATCH/fake-home"
  legacy="$HOME/.claude/herdr-hunk-review/sessions"
  mkdir -p "$legacy"

  unset CLAUDE_PLUGIN_DATA
  run sh "$scripts_dir/state-root.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$derived" ]
}

@test "unset CLAUDE_PLUGIN_DATA and no derivable root falls back to the legacy root when it exists" {
  scripts_dir="$(make_fake_install "$SCRATCH/fake-install2")"
  # Deliberately do NOT create the derived data dir - only the legacy one.
  export HOME="$SCRATCH/fake-home2"
  legacy="$HOME/.claude/herdr-hunk-review/sessions"
  mkdir -p "$legacy"

  unset CLAUDE_PLUGIN_DATA
  run sh "$scripts_dir/state-root.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$legacy" ]
}

@test "neither candidate exists: exits non-zero, prints a diagnostic to stderr, and creates nothing" {
  unset CLAUDE_PLUGIN_DATA
  export HOME="$SCRATCH/fake-home-none"
  errfile="$SCRATCH/err.txt"
  run sh -c 'sh "$1/scripts/state-root.sh" 2>"$2"' _ "$HHR_ROOT" "$errfile"
  [ "$status" -ne 0 ]
  [ -s "$errfile" ]
  [ ! -d "$HOME/.claude" ]
}

@test "probing creates no directories on success or on failure" {
  scripts_dir="$(make_fake_install "$SCRATCH/fake-install3")"
  export HOME="$SCRATCH/fake-home3-empty"
  unset CLAUDE_PLUGIN_DATA

  before="$(find "$SCRATCH/fake-install3" | wc -l | tr -d ' ')"
  run sh "$scripts_dir/state-root.sh"
  [ "$status" -ne 0 ]
  after="$(find "$SCRATCH/fake-install3" | wc -l | tr -d ' ')"
  [ "$before" -eq "$after" ]
  [ ! -d "$HOME/.claude" ]
}

@test "a command's resolution matches the directory a hook actually wrote into (installed layout)" {
  scripts_dir="$(make_fake_install "$SCRATCH/fake-install4")"
  data_root="$SCRATCH/fake-install4/plugins/data/testplugin-testmarket"
  mkdir -p "$data_root/sessions"

  # Hook context: CLAUDE_PLUGIN_DATA set exactly as the harness sets it for hooks.
  (
    export CLAUDE_PLUGIN_DATA="$data_root"
    . "$scripts_dir/common.sh"
    hook_dir="$(hhr_state_dir sess-xyz)"
    printf '%s' "$hook_dir" > "$SCRATCH/hook_dir.txt"
  )

  # Command context: no CLAUDE_PLUGIN_DATA, resolved purely from the script's own
  # location, exactly like a command's Bash tool call reaches it.
  unset CLAUDE_PLUGIN_DATA
  run sh "$scripts_dir/state-root.sh"
  [ "$status" -eq 0 ]
  cmd_root="$output"

  hook_dir="$(cat "$SCRATCH/hook_dir.txt")"
  [ "$hook_dir" = "$cmd_root/sess-xyz" ]
}

@test "a command's resolution matches the directory a hook actually wrote into (legacy layout)" {
  export HOME="$SCRATCH/fake-home5"
  legacy="$HOME/.claude/herdr-hunk-review/sessions"
  mkdir -p "$legacy"

  # Simulate an old-style hook run that had no installed-layout root to derive from
  # either (pre-plugin-marketplace install), only the legacy CLAUDE_PLUGIN_DATA value.
  (
    export CLAUDE_PLUGIN_DATA="$HOME/.claude/herdr-hunk-review"
    . "$HHR_ROOT/scripts/common.sh"
    hook_dir="$(hhr_state_dir sess-legacy)"
    printf '%s' "$hook_dir" > "$SCRATCH/hook_dir_legacy.txt"
  )

  unset CLAUDE_PLUGIN_DATA
  run sh "$HHR_ROOT/scripts/state-root.sh"
  [ "$status" -eq 0 ]
  cmd_root="$output"
  [ "$cmd_root" = "$legacy" ]

  hook_dir="$(cat "$SCRATCH/hook_dir_legacy.txt")"
  [ "$hook_dir" = "$cmd_root/sess-legacy" ]
}

@test "refresh.sh exits non-zero and writes nothing to stdout when no root resolves" {
  unset CLAUDE_PLUGIN_DATA
  export HOME="$SCRATCH/fake-home-refresh-none"
  run --separate-stderr sh "$HHR_ROOT/scripts/refresh.sh" sess-anything force
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "baseline.sh exits non-zero when no root resolves" {
  unset CLAUDE_PLUGIN_DATA
  export HOME="$SCRATCH/fake-home-baseline-none"
  run sh "$HHR_ROOT/scripts/baseline.sh" sess-anything
  [ "$status" -ne 0 ]
}
