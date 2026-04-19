variable "project_name" {
  description = "Project name prefix for resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "domain_name" {
  description = "Custom domain name for Outline (e.g. outline.devops-agent.xyz)."
  type        = string
}

variable "route53_zone_name" {
  description = "Route53 hosted zone name (e.g. devops-agent.xyz)."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the internet-facing ALB."
  type        = string
}

variable "grafana_domain" {
  description = "Custom domain name for Grafana (e.g. grafana.devops-agent.xyz)."
  type        = string
  default     = ""
}

variable "grafana_alb_dns_name" {
  description = "DNS name of the Grafana ALB (may differ from Outline ALB)."
  type        = string
  default     = ""
}

variable "apigw_endpoint" {
  description = "API Gateway endpoint domain (e.g. xxx.execute-api.us-east-1.amazonaws.com) for /webhook/* path."
  type        = string
  default     = ""
}
