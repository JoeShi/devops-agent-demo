output "cluster_endpoint" {
  description = "EKS cluster API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS nodes."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller."
  value       = aws_iam_role.lb_controller.arn
}

output "alb_dns_name" {
  description = "ALB DNS name, available after ingress deployment."
  value       = "deploy-ingress-first"
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator."
  value       = aws_iam_role.external_secrets.arn
}

output "oidc_issuer_host" {
  description = "EKS OIDC issuer hostname without https:// (used in IRSA conditions)."
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}
