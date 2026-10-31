# The agenda parser (Paste an agenda). One Lambda function with a public function URL: it takes
# pasted text from the browser, asks a model on Amazon Bedrock to turn it into a structured
# agenda, validates the answer and returns JSON. It needs no database, so it runs outside the VPC
# (no NAT gateway, no VPC endpoint, no cost while nobody uses it). It never writes anything:
# saving goes through the normal API. Was infra/ai.yml (Lab 6).

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/${var.project_name}/agenda-parser"
  retention_in_days = 14
}

resource "aws_iam_role" "parser" {
  name = "${var.project_name}-ai-Role-38J929lKpaV4"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "parser_basic" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parser" {
  name = "bedrock"
  role = aws_iam_role.parser.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # "*" for now; narrowing it to one model is a discussion question of Lab 6.
      {
        Effect   = "Allow"
        Action   = "bedrock-mantle:CreateInference"
        Resource = "*"
      },
      # Converse: a "us." cross-region profile, and the models in the regions it routes to.
      {
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = [
          "arn:${local.partition}:bedrock:${var.region}:${local.account_id}:inference-profile/*",
          "arn:${local.partition}:bedrock:*::foundation-model/*",
        ]
      },
    ]
  })
}

# The API's image, started with another command: the agenda-parser app. No vpc_config.
resource "aws_lambda_function" "parser" {
  function_name = "${var.project_name}-agenda-parser"
  package_type  = "Image"
  image_uri     = data.aws_lambda_function.api.image_uri
  architectures = ["arm64"]
  memory_size   = 512
  # A parse takes 2-8 s; the rest is room for a cold start and one retry of the model call.
  timeout = 30
  role    = aws_iam_role.parser.arn

  image_config {
    command = ["uvicorn", "app.ai.agenda_lambda:app", "--host", "0.0.0.0", "--port", "8000"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.parser.name
  }

  environment {
    variables = {
      PARSER_MODEL         = var.parser_model
      PARSER_EFFORT        = var.parser_effort
      PARSER_PROVIDER      = var.parser_provider
      BEDROCK_REGION       = var.region
      CORS_ORIGINS         = join(",", local.frontend_urls)
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
      # Lambda Web Adapter: forward requests to uvicorn once /api/health answers.
      AWS_LWA_PORT                 = "8000"
      AWS_LWA_READINESS_CHECK_PATH = "/api/health"
      AWS_LWA_ASYNC_INIT           = "true"
    }
  }
}

# Public, like the API's: the browser calls it directly. Who may call is decided by the Cognito
# token (401 otherwise); which sites may, by the app's CORS middleware (POST only).
resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE"
}

# A public function URL needs both permissions. Their statement ids are the ones CloudFormation
# generated, adopted as they are.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "${var.project_name}-ai-FunctionUrlPermission-BP2LsQojKO4W"
  function_name          = aws_lambda_function.parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_invoke" {
  statement_id             = "${var.project_name}-ai-FunctionInvokePermission-cQpQGXBJn6Ij"
  function_name            = aws_lambda_function.parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}
