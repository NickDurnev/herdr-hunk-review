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

@test "lock breaks a stale lock and then holds it" {
  d="$(hhr_state_dir sess-stale)"
  mkdir -p "$d/.lock"
  # backdate beyond the stale threshold
  touch -t 200001010000 "$d/.lock"
  run hhr_lock "$d"
  [ "$status" -eq 0 ]
  # The breaker must now OWN the lock, not merely have deleted it.
  hhr_lock "$d" && false || true
  [ -d "$d/.lock" ]
}

@test "only one of many CONCURRENT racers wins a contested stale lock" {
  # Sequential calls cannot expose this bug: the second caller re-stats the winner's
  # fresh lock, sees it is not stale, and declines. Only genuine concurrency, where
  # several racers pass the staleness test before any of them acts, reproduces it.
  # Five trials: against a blind `rm -rf` break this fails ~90% of the time per trial.
  for trial in 1 2 3 4 5; do
    d="$(hhr_state_dir "sess-race-$trial")"
    mkdir -p "$d/.lock"
    touch -t 200001010000 "$d/.lock"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      ( . "$BATS_TEST_DIRNAME/../scripts/common.sh"
        hhr_lock "$d" && echo w >> "$d/wins" ) &
    done
    wait
    winners=$(wc -l < "$d/wins" 2>/dev/null | tr -d ' ')
    [ -n "$winners" ] || winners=0
    [ "$winners" -eq 1 ] || {
      echo "trial $trial: expected exactly 1 winner, got $winners"
      false
    }
    # The break lock must never be left behind.
    [ ! -d "$d/.lockbreak" ]
  done
}

@test "guard exits 0 and silently when the session is paused" {
  d="$(hhr_state_dir sess-paused)"
  touch "$d/paused"
  run sh -c '. "$1/scripts/common.sh"; hhr_guard "$2"; echo REACHED' _ "$HHR_ROOT" "$d"
  [ "$status" -eq 0 ]
  [ "$output" != "REACHED" ]
}

@test "guard returns and lets the caller continue when not paused" {
  d="$(hhr_state_dir sess-ok)"
  run sh -c '. "$1/scripts/common.sh"; hhr_guard "$2"; echo REACHED' _ "$HHR_ROOT" "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "REACHED" ]
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
