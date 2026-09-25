#!/bin/sh
# Prints the resolved sessions root (see hhr_state_root in common.sh for the full
# candidate list and why). Slash commands run outside common.sh, so they call this
# instead of hardcoding a root path - hardcoding it here too would let them drift
# apart from the logic common.sh's own callers use.
#
# On failure hhr_state_root has already printed a diagnostic to stderr; this script's
# own exit status is simply whatever hhr_state_root returned (it's the last
# statement), so a command that runs this and checks its exit code sees the real
# failure instead of a silently empty/wrong path.
set -e
. "$(dirname "$0")/common.sh"
hhr_state_root
