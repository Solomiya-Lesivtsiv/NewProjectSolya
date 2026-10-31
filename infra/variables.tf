# Non-secret values are in terraform.tfvars. Secrets, and personal data that should not be in a
# public repository, are workspace variables in HCP Terraform (or TF_VAR_... locally).

variable "project_name" {
  type        = string
  description = "Prefix of every resource name, and the PROJECT_NAME tag"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "project_name must start with a letter and contain only a-z, 0-9 and -."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---------------------------------------------------------------------------------- auth.tf

variable "local_app_urls" {
  type        = list(string)
  description = "Dev servers that Cognito may redirect back to, besides the deployed frontend"
  default     = ["http://localhost:5173", "http://localhost:3000"]
}

variable "google_client_id" {
  type        = string
  description = "Google OAuth client id; empty disables Google sign-in"
  default     = ""
}

variable "google_client_secret" {
  type        = string
  description = "Google OAuth client secret (workspace variable, sensitive)"
  default     = ""
  sensitive   = true
}

# ------------------------------------------------------------------------------- reports.tf

variable "report_email" {
  type        = string
  description = "Sender and recipient of the weekly report (workspace variable: personal data)"
}

variable "report_schedule" {
  type        = string
  description = "When the report is built, in Europe/Kyiv. For a test run use rate(5 minutes)"
  default     = "cron(0 7 ? * MON *)"
}

variable "db_user" {
  type    = string
  default = "meetings"
}

variable "db_name" {
  type    = string
  default = "meetings"
}

# ------------------------------------------------------------------------------------ ai.tf

variable "parser_provider" {
  type        = string
  description = "bedrock = Claude through the Anthropic Messages API; converse = another Bedrock model"
  default     = "converse"

  validation {
    condition     = contains(["bedrock", "converse"], var.parser_provider)
    error_message = "parser_provider must be bedrock or converse."
  }
}

variable "parser_model" {
  type        = string
  description = "Bedrock model id. Configuration, not code, so models can be compared without a release"
  default     = "us.amazon.nova-2-lite-v1:0"
}

variable "parser_effort" {
  type    = string
  default = "low"

  validation {
    condition     = contains(["low", "medium", "high"], var.parser_effort)
    error_message = "parser_effort must be low, medium or high."
  }
}
