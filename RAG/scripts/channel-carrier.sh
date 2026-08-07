#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OWNER_REPO="${VAMPIREOTP_OWNER_REPO:-/Users/golem/git/VampireOTP}"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <carrier-command> [arguments]" >&2
  exit 2
fi

command_name="$1"
shift

export CARRIER_CHANNEL=".relay"
export CARRIER_STATE_DIR="$OWNER_REPO/.relay/state"

exec python3 "$SCRIPT_DIR/carrier.py" "$command_name" --repo "$OWNER_REPO" "$@"
