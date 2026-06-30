###############################################################################
# variables.tf — Configurable inputs
###############################################################################

variable "project_name" {
  type        = string
  description = "Prefix applied to all resource names."
  default     = "cost-anomaly-detector"
}

variable "environment" {
  type        = string
  description = "Deployment environment tag (e.g. prod, staging)."
  default     = "prod"
}

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into. NOTE: CloudWatch Billing metrics are only available in us-east-1."
  default     = "us-east-1"
}

variable "slack_webhook_url" {
  type        = string
  description = "Incoming webhook URL for Slack or Discord alert delivery."
  sensitive   = true
}

variable "cost_threshold" {
  type        = number
  description = "Minimum absolute dollar impact ($) before Lambda fires an alert."
  default     = 5.00
}

variable "billing_alarm_threshold" {
  type        = number
  description = "Total estimated monthly charge ($) that triggers the CloudWatch billing alarm."
  default     = 50.00
}

variable "alert_email" {
  type        = string
  description = "Optional email address for direct SNS subscription (leave empty to skip)."
  default     = ""
}
