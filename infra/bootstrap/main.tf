# Bootstrap: the one piece that must exist before HCP Terraform can do anything in AWS. An IAM OIDC
# provider that trusts tokens signed by app.terraform.io, and a role that runs of the project's
# workspace may assume. Applied once from a laptop with your own credentials, with a local state
# (kept out of Git by infra/.gitignore):
#
#   terraform -chdir=infra/bootstrap init
#   terraform -chdir=infra/bootstrap apply -var tfc_organization=<org>
#
# Then set TFC_AWS_PROVIDER_AUTH=true and TFC_AWS_RUN_ROLE_ARN=<role_arn> as environment variables
# of the workspace.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}

variable "project_name" {
  type    = string
  default = "new-project-solya"
}

variable "tfc_organization" {
  type        = string
  description = "HCP Terraform organization"
}

variable "tfc_workspace" {
  type    = string
  default = "new-project-solya-dev"
}

data "tls_certificate" "tfc" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "tfc" {
  name = "hcp-terraform-${var.tfc_organization}"

  # Narrower than the lab's "any workspace of the organization": only this project's workspace,
  # in both the plan and the apply phase.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        StringLike = {
          "app.terraform.io:sub" = "organization:${var.tfc_organization}:project:*:workspace:${var.tfc_workspace}:run_phase:*"
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to the services the workspace manages
# (Cognito, S3, SQS, Lambda, IAM roles with a permissions boundary, Scheduler, SES, Logs, EC2
# VPC endpoints, and read access to CloudFormation and SSM).
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}
