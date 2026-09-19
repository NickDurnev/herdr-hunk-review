#!/bin/sh
# Prints the resolved sessions root, matching common.sh's CLAUDE_PLUGIN_DATA fallback.
# Slash commands run outside common.sh, so they call this instead of hardcoding
# ${CLAUDE_PLUGIN_DATA}/sessions/ - hardcoding it there let the two drift apart.
set -e
. "$(dirname "$0")/common.sh"
hhr_state_root
