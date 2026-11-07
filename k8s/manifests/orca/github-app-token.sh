#!/bin/bash
# Prints a one-hour installation token for the GitHub App, whose key stays in KMS.
set -euo pipefail

svid_dir=/tmp/orca-github-app

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

mkdir -p -m 700 "$svid_dir"
# spiffe-helper retries forever without an agent, which would hang git and gh.
if ! helper_output=$(timeout 30 spiffe-helper -config /etc/orca/spiffe-helper.hcl 2>&1); then
  echo "Couldn't fetch a JWT SVID: $helper_output" >&2
  exit 1
fi

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$GITHUB_APP_ID" | b64url)
printf '%s' "$header.$payload" >"$svid_dir/signing-input"

signature=$(
  AWS_ROLE_ARN=$GITHUB_APP_AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE=$svid_dir/svid.jwt \
    aws kms sign \
    --key-id "$GITHUB_APP_KMS_KEY" \
    --message-type RAW \
    --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
    --message "fileb://$svid_dir/signing-input" \
    --query Signature --output text \
    | base64 -d | b64url
)

curl -fsS -X POST \
  -H "Authorization: Bearer $header.$payload.$signature" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/app/installations/$GITHUB_APP_INSTALLATION_ID/access_tokens" \
  | jq -er .token
