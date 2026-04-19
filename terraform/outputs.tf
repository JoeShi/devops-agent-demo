output "eks_cluster_endpoint" {
  description = "EKS cluster API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = module.data_stores.rds_endpoint
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = module.data_stores.redis_endpoint
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint."
  value       = module.data_stores.opensearch_endpoint
}

output "alb_dns_name" {
  description = "ALB DNS name (available after ingress deployment)."
  value       = module.eks.alb_dns_name
}

output "grafana_url" {
  description = "Grafana dashboard URL."
  value       = module.observability.grafana_url
}

output "grafana_sa_token_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the Grafana service account token."
  value       = module.observability.grafana_sa_token_secret_arn
}

output "feishu_bot_role_arn" {
  description = "IAM role ARN for the Feishu bot EKS pod (IRSA)."
  value       = module.integration.feishu_bot_role_arn
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = module.cdn.cloudfront_distribution_id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = module.cdn.cloudfront_domain_name
}

output "outline_url" {
  description = "Outline application URL."
  value       = module.cdn.outline_url
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID."
  value       = module.auth.user_pool_id
}

output "grafana_alerts_sns_topic_arn" {
  description = "SNS topic ARN for Grafana Alertmanager integration."
  value       = module.integration.grafana_alerts_sns_topic_arn
}
