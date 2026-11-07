#!/bin/bash
set -euo pipefail

[ "${1:-}" = get ] || exit 0
token=$(github-app-token)
printf 'username=x-access-token\npassword=%s\n' "$token"
