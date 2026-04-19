terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  common_tags = {
    App         = "outline"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# --- Route53 Hosted Zone ---

data "aws_route53_zone" "main" {
  name = var.route53_zone_name
}

# --- ACM Certificate for CloudFront (us-east-1) ---

resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  tags              = merge(local.common_tags, { Name = "${var.project_name}-cf-cert" })
  lifecycle { create_before_destroy = true }
}

# --- ACM Certificate for ALB (current region) ---

resource "aws_acm_certificate" "alb" {
  domain_name       = "alb-${var.domain_name}"
  validation_method = "DNS"
  tags              = merge(local.common_tags, { Name = "${var.project_name}-alb-cert" })
  lifecycle { create_before_destroy = true }
}

# --- DNS Validation Records (both certs share the same zone) ---

locals {
  all_dvos = merge(
    { for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => dvo },
    { for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => dvo },
  )
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.all_dvos

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.resource_record_name]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.resource_record_name]
}

# --- CloudFront Distribution ---

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  aliases             = [var.domain_name]
  comment             = "${var.project_name} Outline CDN"
  default_root_object = ""
  price_class         = "PriceClass_200"
  http_version        = "http2and3"

  origin {
    domain_name = "alb-${var.domain_name}"
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
  }

  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  ordered_cache_behavior {
    path_pattern           = "/static/*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  dynamic "origin" {
    for_each = var.apigw_endpoint != "" ? [1] : []
    content {
      domain_name = var.apigw_endpoint
      origin_id   = "apigw"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.apigw_endpoint != "" ? [1] : []
    content {
      path_pattern           = "/webhook/*"
      target_origin_id       = "apigw"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-cdn" })
}

# --- Route53 Records ---

resource "aws_route53_record" "main" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "alb-${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.alb_dns_name]
}

# --- Grafana: ACM Certificate + DNS ---

resource "aws_acm_certificate" "grafana" {
  count             = var.grafana_domain != "" ? 1 : 0
  domain_name       = var.grafana_domain
  validation_method = "DNS"
  tags              = merge(local.common_tags, { Name = "${var.project_name}-grafana-cert" })
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "grafana_cert_validation" {
  for_each = var.grafana_domain != "" ? {
    for dvo in aws_acm_certificate.grafana[0].domain_validation_options : dvo.domain_name => dvo
  } : {}

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 300
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "grafana" {
  count                   = var.grafana_domain != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.grafana[0].arn
  validation_record_fqdns = [for dvo in aws_acm_certificate.grafana[0].domain_validation_options : dvo.resource_record_name]
}

resource "aws_route53_record" "grafana" {
  count   = var.grafana_domain != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.grafana_domain
  type    = "CNAME"
  ttl     = 300
  records = [var.grafana_alb_dns_name != "" ? var.grafana_alb_dns_name : var.alb_dns_name]
}
