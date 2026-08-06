#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if pgrep -f '[o]penshift-install create cluster' >/dev/null 2>&1; then
  echo "ERROR: an openshift-install create cluster process is already running." >&2
  echo "Do not start a second installer." >&2
  exit 1
fi

./preflight.sh
./render-install-config.sh
./install-cluster.sh
