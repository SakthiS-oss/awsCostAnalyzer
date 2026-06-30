###############################################################################
# iam.tf — Principle of Least Privilege execution roles
###############################################################################

###############################################################################
# Lambda execution role
###############################################################################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

###############################################################################
# CloudWatch Logs — write-only to this function's log group
###############################################################################

data "aws_iam_policy_document" "lambda_logging" {
  statement {
    sid    = "AllowLogStreamCreation"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-cost-handler:*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_logging" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_logging.json
}

###############################################################################
# DynamoDB — scoped to the single anomaly ledger table
###############################################################################

data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    sid    = "AllowLedgerReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.anomaly_ledger.arn,
      "${aws_dynamodb_table.anomaly_ledger.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "dynamodb-anomaly-ledger"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}

###############################################################################
# S3 — read-only access to the artifacts bucket (lambda source)
###############################################################################

data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid    = "AllowArtifactRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.artifacts.arn}/lambda/*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_s3" {
  name   = "s3-artifact-read"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_s3.json
}

###############################################################################
# CloudWatch Metrics — publish telemetry (optional custom metrics)
###############################################################################

data "aws_iam_policy_document" "lambda_cloudwatch_metrics" {
  statement {
    sid    = "AllowMetricPublish"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["${var.project_name}/CostAnomalies"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_cloudwatch_metrics" {
  name   = "cloudwatch-metrics"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_cloudwatch_metrics.json
}
