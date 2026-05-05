output "feishu_notifier_function_name" {
  description = "Name of the Feishu notifier Lambda function."
  value       = aws_lambda_function.feishu_notifier.function_name
}

output "feishu_bot_role_arn" {
  description = "IAM role ARN for the Feishu bot EKS pod (IRSA)."
  value       = aws_iam_role.feishu_bot.arn
}

output "wecom_bot_role_arn" {
  description = "IRSA role ARN for wecom-bot EKS Pod — used by k8s/wecom-bot-deployment.yaml ServiceAccount annotation."
  value       = aws_iam_role.wecom_bot.arn
}

output "dingtalk_bot_role_arn" {
  description = "IRSA role ARN for dingtalk-bot EKS Pod — used by k8s/dingtalk-bot-deployment.yaml ServiceAccount annotation."
  value       = aws_iam_role.dingtalk_bot.arn
}

output "grafana_alerts_sns_topic_arn" {
  description = "SNS topic ARN for Grafana Alertmanager integration."
  value       = aws_sns_topic.grafana_alerts.arn
}
