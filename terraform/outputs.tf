###############################################################################
# outputs.tf — Target resource endpoints
###############################################################################

output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives cost alert payloads."
  value       = aws_sns_topic.cost_alerts.arn
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = aws_lambda_function.cost_handler.function_name
}

output "lambda_function_arn" {
  description = "ARN of the deployed Lambda function."
  value       = aws_lambda_function.cost_handler.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB anomaly audit ledger."
  value       = aws_dynamodb_table.anomaly_ledger.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB anomaly audit ledger."
  value       = aws_dynamodb_table.anomaly_ledger.arn
}

output "s3_artifacts_bucket" {
  description = "Name of the S3 bucket storing Lambda deployment artifacts."
  value       = aws_s3_bucket.artifacts.id
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for Lambda function output."
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "cost_anomaly_monitor_arn" {
  description = "ARN of the Cost Explorer anomaly monitor."
  value       = aws_ce_anomaly_monitor.services.arn
}
