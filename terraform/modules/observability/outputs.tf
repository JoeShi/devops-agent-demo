output "grafana_url" {
  description = "Grafana dashboard URL."
  value       = "https://${var.grafana_host}"
}

output "grafana_sa_token_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the Grafana service account token for AWS DevOps Agent."
  value       = aws_secretsmanager_secret.grafana_sa_token.arn
}
