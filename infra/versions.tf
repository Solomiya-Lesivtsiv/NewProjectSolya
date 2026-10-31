# The Terraform part of the infrastructure: Cognito (auth.tf), the weekly report (reports.tf) and
# the agenda parser (ai.tf). The older stacks (ECR, backend + Aurora, frontend, certificate) are
# still CloudFormation; this configuration only reads their outputs (data.tf).
#
# State and runs live in HCP Terraform. Plans and applies run there with dynamic AWS credentials
# (an IAM role trusted through OIDC); nobody needs AWS keys to change this infrastructure.
terraform {
  required_version = ">= 1.10"

  cloud {
    organization = "App_for_meetings"

    workspaces {
      name = "new-project-solya-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}
