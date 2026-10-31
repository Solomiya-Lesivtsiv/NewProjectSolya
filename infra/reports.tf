# The weekly meetings report, built by events and not by requests. A schedule (or make report-now)
# puts a message on an SQS queue; the report-builder Lambda function (in the backend's VPC, same
# image as the API) reads the database and saves a CSV to S3; the upload triggers the
# report-mailer Lambda function (outside the VPC), which emails the file through SES.
# Was infra/reports.yaml (Lab 5).
#
# The IAM role names are the ones CloudFormation generated; they were adopted as they are, since a
# new name would mean a new role.

locals {
  reports_bucket = "${var.project_name}-reports-${local.account_id}"
}

# ------------------------------------------------------------------------------------ Storage
# In CloudFormation the bucket, its notification and the mailer's permission formed a cycle, so
# the bucket name had to be built by hand. Here they are three resources with plain references.
resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket

  # Every report since Lab 5 is in it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "delete-old-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  # S3 checks that it may call the function when the notification is saved.
  depends_on = [aws_lambda_permission.mailer_s3]
}

# The builder is in the VPC and the VPC has no NAT gateway, so without this its upload to S3 would
# hang until the timeout. A gateway endpoint is free.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.backend["VpcId"]
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [local.backend["PrivateRouteTableId"]]
}

# -------------------------------------------------------------------------------------- Queue
resource "aws_sqs_queue" "report_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600
  max_message_size          = 1048576
}

resource "aws_sqs_queue" "reports" {
  name             = "${var.project_name}-report-requests"
  max_message_size = 1048576
  # At least 6 times the builder's timeout (120 s). Shorter, and a message becomes visible again
  # while the first attempt still runs, so a second builder starts on the same report.
  visibility_timeout_seconds = 720
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_dlq.arn
    maxReceiveCount     = 3
  })
}

# ------------------------------------------------------------------------------------ Builder
resource "aws_cloudwatch_log_group" "builder" {
  name              = "/${var.project_name}/report-builder"
  retention_in_days = 7
}

resource "aws_iam_role" "builder" {
  name = "${var.project_name}-reports-BuilderRole-W6STOtjX4r7D"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "builder_vpc" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "builder" {
  name = "reports"
  role = aws_iam_role.builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      # The Lambda service polls the queue with this role; the function never connects to SQS.
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.reports.arn
      },
    ]
  })
}

# The API's image, started with another command: the report-builder app, with no function URL.
# The Lambda Web Adapter hands it every SQS message or direct invocation as POST /events.
resource "aws_lambda_function" "builder" {
  function_name = "${var.project_name}-report-builder"
  package_type  = "Image"
  image_uri     = data.aws_lambda_function.api.image_uri
  architectures = ["arm64"]
  memory_size   = 512
  # Covers resuming a paused database (about 15 s), the query and the upload. Keep the queue's
  # visibility timeout at 6 times this.
  timeout = 120
  role    = aws_iam_role.builder.arn

  image_config {
    command = ["uvicorn", "app.reports.worker:app", "--host", "0.0.0.0", "--port", "8000"]
  }

  vpc_config {
    subnet_ids         = split(",", local.backend["PrivateSubnetIds"])
    security_group_ids = [local.backend["FunctionSecurityGroupId"]]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.builder.name
  }

  environment {
    variables = {
      DATABASE_URL    = "postgresql+asyncpg://${var.db_user}:${data.aws_ssm_parameter.db_password.value}@${local.backend["DatabaseEndpoint"]}:5432/${var.db_name}"
      REPORTS_BUCKET  = aws_s3_bucket.reports.bucket
      DB_POOL_SIZE    = "1"
      DB_MAX_OVERFLOW = "0"
      # Lambda Web Adapter: forward events to uvicorn once /api/health answers. A 5xx answer
      # fails the invocation, so SQS delivers the message again (then the dead-letter queue).
      AWS_LWA_PORT                 = "8000"
      AWS_LWA_READINESS_CHECK_PATH = "/api/health"
      AWS_LWA_ASYNC_INIT           = "true"
      AWS_LWA_ERROR_STATUS_CODES   = "500-599"
    }
  }

  # Without a NAT gateway the upload to S3 needs the endpoint.
  depends_on = [aws_vpc_endpoint.s3]
}

# One message at a time: the account's Lambda concurrency limit can be as low as 10.
resource "aws_lambda_event_source_mapping" "builder" {
  event_source_arn = aws_sqs_queue.reports.arn
  function_name    = aws_lambda_function.builder.arn
  batch_size       = 1
}

# ------------------------------------------------------------------------------------- Mailer
resource "aws_cloudwatch_log_group" "mailer" {
  name              = "/${var.project_name}/report-mailer"
  retention_in_days = 7
}

resource "aws_iam_role" "mailer" {
  name = "${var.project_name}-reports-MailerRole-Kk0qSxrGT6Zm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mailer_basic" {
  role       = aws_iam_role.mailer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "mailer" {
  name = "reports"
  role = aws_iam_role.mailer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read only: the mailer must never write into reports/, or its own upload would start it
      # again, forever.
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = aws_sesv2_email_identity.report.arn
      },
    ]
  })
}

data "archive_file" "mailer" {
  type        = "zip"
  source_file = "${path.module}/lambda/report_mailer/index.py"
  output_path = "${path.module}/build/report_mailer.zip"
}

# Outside the VPC: it has internet access (SES) and never touches the database.
resource "aws_lambda_function" "mailer" {
  function_name    = "${var.project_name}-report-mailer"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "index.handler"
  timeout          = 30
  memory_size      = 256
  role             = aws_iam_role.mailer.arn
  filename         = data.archive_file.mailer.output_path
  source_code_hash = data.archive_file.mailer.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mailer.name
  }

  environment {
    variables = {
      SENDER     = var.report_email
      RECIPIENTS = var.report_email
    }
  }
}

# S3 may call the mailer, but only for this account's reports bucket.
resource "aws_lambda_permission" "mailer_s3" {
  statement_id   = "${var.project_name}-reports-MailerInvokePermission-lvMVhhqD0CTb"
  function_name  = aws_lambda_function.mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_account = local.account_id
  source_arn     = aws_s3_bucket.reports.arn
}

# SES emailed a verification link to the address when this was created; it was clicked in Lab 5.
resource "aws_sesv2_email_identity" "report" {
  email_identity = var.report_email
}

# ----------------------------------------------------------------------------------- Schedule
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-reports-SchedulerRole-W2LbQbkT5Mvv"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "send-to-queue"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.reports.arn
    }]
  })
}

# A command, not an event: "build last week's report". No week in the message means the previous
# ISO week, decided by the builder when it runs.
resource "aws_scheduler_schedule" "weekly" {
  name                = "${var.project_name}-weekly-report"
  description         = "Weekly meetings report"
  schedule_expression = var.report_schedule
  # Without a time zone the cron runs in UTC and the report would move with daylight saving time.
  schedule_expression_timezone = "Europe/Kyiv"
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.reports.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = "{\"week\": null, \"source\": \"schedule\"}"
  }
}
