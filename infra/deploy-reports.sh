#!/usr/bin/env bash
# Deploys the weekly report (infra/reports.yaml): the schedule, the queue, the report-builder and
# report-mailer functions, the S3 bucket and the SES address. Run via `make deploy-reports`,
# after `make deploy-backend`: the builder runs the very image that the API runs.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  : "${REPORT_EMAIL:?Set REPORT_EMAIL in .env: the address that sends and receives the report}"
  stack_exists "$BACKEND_STACK" || {
    echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2
    exit 1
  }

  echo "==> [1/3] Read the backend ($BACKEND_STACK)"
  function_name="$(output "$BACKEND_STACK" FunctionName)"
  image="$(aws lambda get-function --function-name "$function_name" \
    --query Code.ImageUri --output text)"
  vpc_id="$(output "$BACKEND_STACK" VpcId)"
  subnets="$(output "$BACKEND_STACK" PrivateSubnetIds)"
  route_table="$(output "$BACKEND_STACK" PrivateRouteTableId)"
  security_group="$(output "$BACKEND_STACK" FunctionSecurityGroupId)"
  database="$(output "$BACKEND_STACK" DatabaseEndpoint)"
  for value in "$vpc_id" "$subnets" "$route_table" "$security_group" "$database" "$image"; do
    if [ -z "$value" ] || [ "$value" = "None" ]; then
      echo "The backend stack lacks the outputs the report needs; run make deploy-backend again." >&2
      exit 1
    fi
  done
  echo "    Image: $image"
  db_password="$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --with-decryption \
    --query Parameter.Value --output text)"

  # SES refuses to create an identity twice. If the address is already in SES and this stack
  # did not create it (for example, verified by hand earlier), leave it alone.
  create_identity=true
  if aws sesv2 get-email-identity --email-identity "$REPORT_EMAIL" >/dev/null 2>&1 &&
    ! aws cloudformation describe-stack-resource --stack-name "$REPORTS_STACK" \
      --logical-resource-id ReportEmailIdentity >/dev/null 2>&1; then
    create_identity=false
    echo "    $REPORT_EMAIL is already an SES identity; keeping it as it is"
  fi

  overrides=(
    "ProjectName=$PROJECT_NAME"
    "ImageUri=$image"
    "DBPassword=$db_password"
    "DatabaseEndpoint=$database"
    "VpcId=$vpc_id"
    "PrivateSubnetIds=$subnets"
    "PrivateRouteTableId=$route_table"
    "FunctionSecurityGroupId=$security_group"
    "ReportEmail=$REPORT_EMAIL"
    "CreateEmailIdentity=$create_identity"
  )
  # Only when set; otherwise the schedule keeps its current value (Mondays at 07:00, Kyiv).
  if [ -n "${REPORT_SCHEDULE:-}" ]; then
    overrides+=("ScheduleExpression=$REPORT_SCHEDULE")
  fi

  echo "==> [2/3] Report stack ($REPORTS_STACK)"
  aws cloudformation deploy \
    --stack-name "$REPORTS_STACK" \
    --template-file infra/reports.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "${overrides[@]}" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo "==> [3/3] Done"
  echo "    Bucket:  s3://$(output "$REPORTS_STACK" BucketName)/reports/"
  echo "    Queue:   $(output "$REPORTS_STACK" QueueUrl)"
  echo "    DLQ:     $(output "$REPORTS_STACK" DeadLetterQueueUrl)"
  echo "    Logs:    $(output "$REPORTS_STACK" BuilderLogGroup) and $(output "$REPORTS_STACK" MailerLogGroup)"
  echo
  if [ "$create_identity" = true ]; then
    echo "SES sent a verification email to $REPORT_EMAIL. Click the link in it once:"
    echo "until you do, SES refuses to send (the account is in the sandbox)."
  fi
  echo "Try it: make report-now WEEK=<an ISO week, e.g. 2026-W40>"
}

main "$@"
