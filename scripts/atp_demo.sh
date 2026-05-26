#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# This demo runs in-process so it can show the real BEAM runtime state.
# It does not need a Phoenix HTTP server, and unsetting PHX_SERVER avoids
# colliding with a local server that may already be using ATP_PORT.
#
# Recording knobs:
#   ATP_DEMO_DELAY_MS=0     run without pacing
#   ATP_DEMO_NO_COLOR=1     plain text output
unset PHX_SERVER

MIX_ENV="${MIX_ENV:-dev}" mix run --no-start scripts/atp_demo.exs
