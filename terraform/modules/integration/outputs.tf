output "feishu_notifier_function_name" {
  description = "Name of the Feishu notifier Lambda function."
  value       = aws_lambda_function.feishu_notifier.function_name
}

output "feishu_bot_role_arn" {
  description = "IAM role ARN for the Feishu bot EKS pod (IRSA)."
  value       = aws_iam_role.feishu_bot.arn
}

output "grafana_alerts_sns_topic_arn" {
  description = "SNS topic ARN for Grafana Alertmanager integration."
  value       = aws_sns_topic.grafana_alerts.arn
}
