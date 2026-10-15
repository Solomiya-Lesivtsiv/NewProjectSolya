#!/usr/bin/env bash
# Builds a weekly report now, by putting the same message on the queue that the schedule uses.
# Run via `make report-now WEEK=2026-W39` (no WEEK: last week).
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  week="${1:-}"
  # Checked here because the text goes into JSON; the builder checks it again.
  if [ -n "$week" ] && ! [[ "$week" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
    echo "WEEK must look like 2026-W40, not '$week'." >&2
    exit 1
  fi
  stack_exists "$REPORTS_STACK" || {
    echo "Stack $REPORTS_STACK not found; run make deploy-reports first." >&2
    exit 1
  }

  if [ -n "$week" ]; then
    body="{\"week\": \"$week\", \"source\": \"report-now\"}"
  else
    body='{"week": null, "source": "report-now"}'
  fi
  queue_url="$(output "$REPORTS_STACK" QueueUrl)"
  echo "==> Queue ${queue_url##*/}: $body"
  aws sqs send-message --queue-url "$queue_url" --message-body "$body" \
    --query MessageId --output text
  echo "Sent. The report appears in the bucket within a minute (the first run after a quiet period"
  echo "waits for the database to resume). Follow it:"
  echo "  aws logs tail $(output "$REPORTS_STACK" BuilderLogGroup) --since 5m --follow"
}

main "$@"
