#!/usr/bin/env bash
# Deploys the agenda parser (infra/ai.yml): one Lambda function with a function URL, outside the
# VPC. Run via `make deploy-ai`, after `make deploy-backend`: the parser runs the very image that
# the API runs.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  stack_exists "$BACKEND_STACK" || {
    echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2
    exit 1
  }

  echo "==> [1/3] Read the backend ($BACKEND_STACK) and Cognito ($AUTH_STACK)"
  function_name="$(output "$BACKEND_STACK" FunctionName)"
  image="$(aws lambda get-function --function-name "$function_name" \
    --query Code.ImageUri --output text)"
  pool_id="$(output "$AUTH_STACK" UserPoolId)"
  client_id="$(output "$AUTH_STACK" UserPoolClientId)"
  for value in "$image" "$pool_id" "$client_id"; do
    if [ -z "$value" ] || [ "$value" = "None" ]; then
      echo "Missing image or Cognito outputs; run make deploy-backend and make deploy-auth." >&2
      exit 1
    fi
  done
  echo "    Image: $image"

  overrides=(
    "ProjectName=$PROJECT_NAME"
    "ImageUri=$image"
    "CognitoUserPoolId=$pool_id"
    "CognitoClientId=$client_id"
    "CorsOrigins=$(cors_origins)"
  )
  # Only when set; otherwise the stack keeps its current model.
  if [ -n "${PARSER_MODEL:-}" ]; then
    overrides+=("ParserModel=$PARSER_MODEL")
  fi

  echo "==> [2/3] Parser stack ($AI_STACK)"
  aws cloudformation deploy \
    --stack-name "$AI_STACK" \
    --template-file infra/ai.yml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "${overrides[@]}" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [3/3] Done"
  echo "    Parser URL: $(output "$AI_STACK" ParserUrl)"
  echo "    Logs:       $(output "$AI_STACK" LogGroup)"
  echo
  echo "Put the Parser URL into .env as AGENDA_PARSER_URL, then run make deploy-frontend."
}

main "$@"
