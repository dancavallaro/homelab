#!/bin/bash
set -euo pipefail

GH_TOKEN=$(github-app-token)
export GH_TOKEN
exec /opt/gh/bin/gh "$@"
