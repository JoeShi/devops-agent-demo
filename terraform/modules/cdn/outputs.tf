output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.main.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "outline_url" {
  description = "Outline application URL."
  value       = "https://${var.domain_name}"
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID."
  value       = data.aws_route53_zone.main.zone_id
}

output "alb_certificate_arn" {
  description = "ACM certificate ARN for ALB HTTPS listener."
  value       = aws_acm_certificate_validation.alb.certificate_arn
}

output "grafana_certificate_arn" {
  description = "ACM certificate ARN for Grafana."
  value       = var.grafana_domain != "" ? aws_acm_certificate_validation.grafana[0].certificate_arn : ""
}
