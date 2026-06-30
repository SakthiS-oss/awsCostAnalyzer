###############################################################################
# main.tf — Core providers, S3, DynamoDB, and Lambda resources
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# S3 — deployment artifact storage
###############################################################################

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project_name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# Package Lambda source → zip → upload to S3
###############################################################################

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/cost_handler.py"
  output_path = "${path.module}/../dist/cost_handler.zip"
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "lambda/cost_handler.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5

  tags = local.common_tags
}

###############################################################################
# DynamoDB — on-demand audit ledger
###############################################################################

resource "aws_dynamodb_table" "anomaly_ledger" {
  name         = "${var.project_name}-anomaly-ledger"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "anomaly_id"
  range_key    = "detected_at"

  attribute {
    name = "anomaly_id"
    type = "S"
  }

  attribute {
    name = "detected_at"
    type = "S"
  }

  attribute {
    name = "service"
    type = "S"
  }

  # GSI used by historical delta analysis query
  global_secondary_index {
    name            = "ServiceDateIndex"
    hash_key        = "service"
    range_key       = "detected_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.common_tags
}

###############################################################################
# Lambda function
###############################################################################

resource "aws_lambda_function" "cost_handler" {
  function_name = "${var.project_name}-cost-handler"
  description   = "Processes AWS cost anomaly SNS payloads and fires webhook alerts."

  s3_bucket        = aws_s3_bucket.artifacts.id
  s3_key           = aws_s3_object.lambda_zip.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  role    = aws_iam_role.lambda_exec.arn
  runtime = "python3.11"
  handler = "cost_handler.lambda_handler"
  timeout = 30

  environment {
    variables = {
      DYNAMODB_TABLE    = aws_dynamodb_table.anomaly_ledger.name
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      COST_THRESHOLD    = tostring(var.cost_threshold)
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts.arn
}

###############################################################################
# CloudWatch Log Group for Lambda
###############################################################################

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.cost_handler.function_name}"
  retention_in_days = 30

  tags = local.common_tags
}

###############################################################################
# Data sources & locals
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
