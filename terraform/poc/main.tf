provider "aws" {
  region  = var.aws_region
  profile = var.profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
      Stack       = "mvp"
    }
  }
}

terraform {
  required_version = ">= 1.16.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  backend "s3" {
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix    = "${var.project}-${var.env}"
  archive_bucket = "${local.name_prefix}-archive-${data.aws_caller_identity.current.account_id}"
  subnet_id      = aws_default_subnet.default_az1.id
  az             = aws_default_subnet.default_az1.availability_zone
  profile_flag   = var.profile == null ? "" : "--profile ${var.profile} "
}
