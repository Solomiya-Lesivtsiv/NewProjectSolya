#!/usr/bin/env bash
# Writes the Cognito settings that infra/auth.tf created into .env, for the local dev servers.
# Run via `make cognito-env`. Reads Terraform outputs only; changes nothing in AWS.
set -euo pipefail

# set_env KEY VALUE: sets KEY=VALUE in .env, replacing an existing line or appending one.
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^$key=" .env; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=" v; next } { print }' .env >"$tmp"
  else
    cat .env >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  cat "$tmp" >.env
  rm -f "$tmp"
}

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh
  require_terraform

  pool_id="$(tf_output user_pool_id)"
  client_id="$(tf_output user_pool_client_id)"
  domain="$(tf_output cognito_domain)"
  google="$(tf_output google_enabled)"
  set_env COGNITO_USER_POOL_ID "$pool_id"
  set_env COGNITO_CLIENT_ID "$client_id"
  set_env COGNITO_DOMAIN "$domain"
  set_env COGNITO_GOOGLE_ENABLED "$google"

  # None of these are secrets: the browser receives all of them.
  echo "Written to .env:"
  echo "  COGNITO_USER_POOL_ID=$pool_id"
  echo "  COGNITO_CLIENT_ID=$client_id"
  echo "  COGNITO_DOMAIN=$domain"
  echo "  COGNITO_GOOGLE_ENABLED=$google"
  echo "  Issuer: $(tf_output cognito_issuer)"
}

main "$@"
