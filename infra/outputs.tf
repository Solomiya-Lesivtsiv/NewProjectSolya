# Everything the infra scripts and the frontend build read (terraform output -raw <name>).

# ---------------------------------------------------------------------------------- auth.tf
output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_domain" {
  description = "Cognito domain for OAuth redirects (Google)"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_issuer" {
  description = "Issuer of the tokens; the backend checks it"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "google_enabled" {
  value = local.has_google ? "true" : "false"
}

# ------------------------------------------------------------------------------- reports.tf
output "reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}

output "report_queue_url" {
  description = "make report-now sends its message here"
  value       = aws_sqs_queue.reports.url
}

output "report_dlq_url" {
  value = aws_sqs_queue.report_dlq.url
}

output "report_builder_log_group" {
  value = aws_cloudwatch_log_group.builder.name
}

output "report_mailer_log_group" {
  value = aws_cloudwatch_log_group.mailer.name
}

# ------------------------------------------------------------------------------------ ai.tf
output "parser_url" {
  description = "Function URL without the trailing slash; the browser POSTs to <it>/api/parse-agenda"
  value       = trimsuffix(aws_lambda_function_url.parser.function_url, "/")
}

output "parser_log_group" {
  value = aws_cloudwatch_log_group.parser.name
}
