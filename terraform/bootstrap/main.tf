# One-time setup: the S3 bucket that holds the Terraform state of ../poc.
# Run once with local state:
#   terraform init && terraform apply -var state_bucket_name=<globally-unique-name>
terraform {
  required_version = ">= 1.16.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.profile
}

variable "aws_region" {
  type        = string
  description = "AWS Region for the state bucket."
  default     = "eu-central-1"
}

variable "profile" {
  type        = string
  description = "AWS CLI profile. Leave null to use the default credential chain."
  default     = null
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique name of the Terraform state bucket."
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}
