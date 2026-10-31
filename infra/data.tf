# What this configuration reads from the parts that are still CloudFormation or set by scripts.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# VPC, subnets, security group, database endpoint and the API function (backend.yaml).
data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

# The CloudFront address, and the custom domain once there is one (frontend.yaml).
data "aws_cloudformation_stack" "frontend" {
  name = "${var.project_name}-frontend"
}

# The report builder and the agenda parser run the API's image with another command, so they
# follow whatever image the API was last deployed with (make deploy-backend).
data "aws_lambda_function" "api" {
  function_name = data.aws_cloudformation_stack.backend.outputs["FunctionName"]
}

# Created by deploy-backend.sh. The value ends up in the state (the builder's DATABASE_URL),
# which is one reason the state lives in HCP Terraform and never in Git.
data "aws_ssm_parameter" "db_password" {
  name            = "/${var.project_name}/db-password"
  with_decryption = true
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  backend    = data.aws_cloudformation_stack.backend.outputs

  # The deployed frontend: CloudFront, plus the custom domain when add-domain has set one.
  frontend_urls = compact([
    data.aws_cloudformation_stack.frontend.outputs["AppUrl"],
    lookup(data.aws_cloudformation_stack.frontend.outputs, "CustomDomainUrl", ""),
  ])
}
