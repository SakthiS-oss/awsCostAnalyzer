###############################################################################
# monitoring.tf — SNS topic, Cost Anomaly Monitor, CloudWatch Billing Alarms
###############################################################################

###############################################################################
# SNS Topic — decoupled pub/sub transport layer
###############################################################################

resource "aws_sns_topic" "cost_alerts" {
  name              = "${var.project_name}-cost-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_handler.arn
}

# Optional: email subscription for direct delivery alongside Slack
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# SNS Topic Policy — allow CloudWatch & Cost Anomaly Detection to publish
###############################################################################

resource "aws_sns_topic_policy" "cost_alerts" {
  arn = aws_sns_topic.cost_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCostAnomalyDetection"
        Effect = "Allow"
        Principal = {
          Service = "costalerts.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
      },
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudwatch:*:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
        }
      }
    ]
  })
}

###############################################################################
# AWS Cost Anomaly Detection Monitor + Alert Subscription
###############################################################################

resource "aws_ce_anomaly_monitor" "services" {
  name              = "${var.project_name}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = local.common_tags
}

resource "aws_ce_anomaly_subscription" "sns_alert" {
  name      = "${var.project_name}-anomaly-subscription"
  frequency = "IMMEDIATE"

  monitor_arn_list = [
    aws_ce_anomaly_monitor.services.arn,
  ]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  # Alert when absolute impact exceeds threshold OR percentage impact exceeds 20 %
  threshold_expression {
    or {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        values        = [tostring(var.cost_threshold)]
        match_options = ["GREATER_THAN_OR_EQUAL"]
      }
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        values        = ["20"]
        match_options = ["GREATER_THAN_OR_EQUAL"]
      }
    }
  }

  tags = local.common_tags
}

###############################################################################
# CloudWatch Billing Alarms — static hard-floor guardrails
# NOTE: billing metrics only exist in us-east-1. If you deploy to another
# region you can either point these at us-east-1 via a provider alias or
# remove this block and rely solely on Cost Anomaly Detection.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "total_billing" {
  alarm_name          = "${var.project_name}-total-daily-spend"
  alarm_description   = "Fires when estimated total AWS charges exceed the configured threshold."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400 # 24 hours
  statistic           = "Maximum"
  threshold           = var.billing_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.cost_alerts.arn]
  ok_actions    = [aws_sns_topic.cost_alerts.arn]

  tags = local.common_tags
}

# Per-service alarms for your most commonly expensive services
locals {
  watched_services = {
    AmazonEC2  = var.billing_alarm_threshold * 0.5
    AWSLambda  = 5.00
    AmazonRDS  = var.billing_alarm_threshold * 0.3
    AmazonS3   = 10.00
  }
}

resource "aws_cloudwatch_metric_alarm" "service_billing" {
  for_each = local.watched_services

  alarm_name          = "${var.project_name}-${each.key}-spend"
  alarm_description   = "Fires when estimated ${each.key} charges exceed $${each.value}."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400
  statistic           = "Maximum"
  threshold           = each.value
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = each.key
    Currency    = "USD"
  }

  alarm_actions = [aws_sns_topic.cost_alerts.arn]

  tags = local.common_tags
}
