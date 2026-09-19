load helper

setup()    { setup_scratch; }
teardown() { teardown_scratch; }

# Regression for the orphaned-pane incident: these tests run inside a live herdr
# session (HERDR_ENV=1, real herdr/hunk on PATH). Any test that reaches
# hhr_pane_ensure without both guards below splits a REAL pane in the user's
# terminal and abandons it when the scratch dir is torn down.

@test "setup_scratch unsets HERDR_ENV" {
  [ -z "${HERDR_ENV+x}" ]
}

@test "setup_scratch shadows herdr with a stub inside the scratch dir" {
  run command -v herdr
  [ "$status" -eq 0 ]
  case "$output" in
    "$SCRATCH"*) : ;;
    *) false ;;
  esac
}

@test "setup_scratch shadows hunk with a stub inside the scratch dir" {
  run command -v hunk
  [ "$status" -eq 0 ]
  case "$output" in
    "$SCRATCH"*) : ;;
    *) false ;;
  esac
}
