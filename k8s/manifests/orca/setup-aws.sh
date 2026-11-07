#!/bin/bash
# One-time AWS setup for the Orca GitHub App.
#   setup-aws.sh kms KEY.pem   Import the App's private key into a sign-only KMS key.
#   setup-aws.sh iam           Let the pod's JWT SVID assume a role that can sign with it.
set -euo pipefail

export AWS_REGION=us-east-1
alias_name=alias/orca-github-app
role_name=orca-github-app
account=484396241422
issuer=fed.spirl.org/t-t7jofa522v/td-tn4hsa850h
audience=sts.amazonaws.com
spiffe_id=spiffe://prod.cavallaro.local/talos-prod/ns/orca/sa/orca

import_key() {
  local pem=$1 work bits key_id
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN

  bits=$(openssl pkey -in "$pem" -noout -text | sed -nE 's/^Private-Key: \(([0-9]+) bit.*/\1/p')
  key_id=$(aws kms create-key --origin EXTERNAL --key-spec "RSA_$bits" --key-usage SIGN_VERIFY \
    --description 'Orca GitHub App private key' --query KeyMetadata.KeyId --output text)
  aws kms create-alias --alias-name "$alias_name" --target-key-id "$key_id"

  aws kms get-parameters-for-import --key-id "$key_id" \
    --wrapping-algorithm RSA_AES_KEY_WRAP_SHA_256 --wrapping-key-spec RSA_4096 \
    --query '[PublicKey, ImportToken]' --output text >"$work/params"
  cut -f1 "$work/params" | base64 -d >"$work/wrapping-key.der"
  cut -f2 "$work/params" | base64 -d >"$work/import-token.bin"

  # An RSA key is too large for the wrapping key, so KMS wants it AES-wrapped first.
  openssl pkcs8 -topk8 -nocrypt -in "$pem" -outform DER -out "$work/key.der"
  openssl rand -out "$work/aes.bin" 32
  openssl enc -id-aes256-wrap-pad -K "$(xxd -p "$work/aes.bin" | tr -d '\n')" -iv A65959A6 \
    -in "$work/key.der" -out "$work/key.wrapped"
  openssl pkeyutl -encrypt -in "$work/aes.bin" -out "$work/aes.wrapped" \
    -inkey "$work/wrapping-key.der" -keyform DER -pubin \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256
  cat "$work/aes.wrapped" "$work/key.wrapped" >"$work/material.bin"

  aws kms import-key-material --key-id "$key_id" \
    --import-token "fileb://$work/import-token.bin" \
    --encrypted-key-material "fileb://$work/material.bin" \
    --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

  aws kms get-public-key --key-id "$key_id" --query PublicKey --output text \
    | base64 -d >"$work/kms-public.der"
  openssl pkey -in "$pem" -pubout -outform DER -out "$work/pem-public.der"
  cmp -s "$work/kms-public.der" "$work/pem-public.der" || {
    echo "KMS public key doesn't match $pem" >&2
    return 1
  }
  echo "Imported into $alias_name ($key_id). KMS holds the key now, so delete $pem."
}

grant_role() {
  local provider_arn=arn:aws:iam::$account:oidc-provider/$issuer key_arn
  key_arn=$(aws kms describe-key --key-id "$alias_name" --query KeyMetadata.Arn --output text)

  aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" >/dev/null 2>&1 \
    || aws iam create-open-id-connect-provider --url "https://$issuer" --client-id-list "$audience" >/dev/null

  aws iam create-role --role-name "$role_name" --query Role.Arn --output text \
    --assume-role-policy-document "$(jq -nc \
      --arg provider "$provider_arn" --arg aud_key "$issuer:aud" --arg sub_key "$issuer:sub" \
      --arg aud "$audience" --arg sub "$spiffe_id" \
      '{Version: "2012-10-17", Statement: [{
        Effect: "Allow",
        Principal: {Federated: $provider},
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {StringEquals: {($aud_key): $aud, ($sub_key): $sub}}
      }]}')"

  aws iam put-role-policy --role-name "$role_name" --policy-name sign-github-app-jwt \
    --policy-document "$(jq -nc --arg key "$key_arn" \
      '{Version: "2012-10-17", Statement: [{
        Effect: "Allow",
        Action: "kms:Sign",
        Resource: $key,
        Condition: {StringEquals: {"kms:SigningAlgorithm": "RSASSA_PKCS1_V1_5_SHA_256"}}
      }]}')"
}

case "${1:-}" in
  kms) import_key "$2" ;;
  iam) grant_role ;;
  *)
    echo "Usage: $0 kms KEY.pem | iam" >&2
    exit 2
    ;;
esac
