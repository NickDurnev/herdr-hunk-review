load helper

setup()    { setup_scratch; . "$BATS_TEST_DIRNAME/../scripts/common.sh"; }
teardown() { teardown_scratch; }

@test "state_dir creates and prints a per-session directory" {
  run hhr_state_dir "sess-abc"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  case "$output" in *"sess-abc"*) : ;; *) false ;; esac
}

@test "state_dir is stable across calls" {
  a="$(hhr_state_dir sess-abc)"
  b="$(hhr_state_dir sess-abc)"
  [ "$a" = "$b" ]
}

@test "have detects a present and an absent command" {
  hhr_have sh
  ! hhr_have definitely-not-a-real-binary-xyz
}

@test "lock is exclusive" {
  d="$(hhr_state_dir sess-lock)"
  hhr_lock "$d"
  run hhr_lock "$d"
  [ "$status" -ne 0 ]
  hhr_unlock "$d"
  hhr_lock "$d"
}

@test "lock breaks a stale lock" {
  d="$(hhr_state_dir sess-stale)"
  mkdir -p "$d/.lock"
  # backdate beyond the stale threshold
  touch -t 200001010000 "$d/.lock"
  run hhr_lock "$d"
  [ "$status" -eq 0 ]
}

@test "json_get reads a top-level string" {
  run sh -c '. "$1/scripts/common.sh"; printf "%s" "{\"session_id\":\"s1\"}" | hhr_json_get session_id' _ "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "s1" ]
}

@test "json_get prints nothing for a missing key" {
  run sh -c '. "$1/scripts/common.sh"; printf "%s" "{}" | hhr_json_get session_id' _ "$HHR_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
