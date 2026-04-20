terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "outline-terraform-state-604179600882"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "outline-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
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

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  environment        = var.environment
}

module "eks" {
  source = "./modules/eks"

  project_name          = var.project_name
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  node_instance_type    = var.eks_node_instance_type
  node_count            = var.eks_node_count
  environment           = var.environment
  devops_agent_role_arn = var.devops_agent_role_arn
}

module "data_stores" {
  source = "./modules/data-stores"

  project_name               = var.project_name
  vpc_id                     = module.vpc.vpc_id
  data_subnet_ids            = module.vpc.data_subnet_ids
  eks_node_sg_id             = module.eks.node_security_group_id
  environment                = var.environment
  db_instance_class          = var.db_instance_class
  redis_node_type            = var.redis_node_type
  opensearch_instance_type   = var.opensearch_instance_type
  opensearch_instance_count  = var.opensearch_instance_count
  opensearch_master_password = var.opensearch_master_password
}

module "observability" {
  source = "./modules/observability"

  opensearch_endpoint        = module.data_stores.opensearch_endpoint
  opensearch_master_password = var.opensearch_master_password
  opensearch_domain_arn      = module.data_stores.opensearch_domain_arn
  grafana_admin_password     = var.grafana_admin_password
  grafana_host           = var.grafana_host
  eks_cluster_name       = module.eks.cluster_name

  alertmanager_sns_topic_arn = module.integration.grafana_alerts_sns_topic_arn
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_issuer_host           = module.eks.oidc_issuer_host

  grafana_oauth_enabled       = true
  grafana_oauth_client_id     = module.auth.grafana_client_id
  grafana_oauth_client_secret = module.auth.grafana_client_secret
  grafana_oauth_auth_url      = module.auth.oidc_auth_uri
  grafana_oauth_token_url     = module.auth.oidc_token_uri
  grafana_oauth_api_url       = module.auth.oidc_userinfo_uri
  grafana_root_url            = "https://${var.grafana_host}"
  grafana_certificate_arn     = module.cdn.grafana_certificate_arn
}

module "integration" {
  source = "./modules/integration"

  feishu_webhook_url    = var.feishu_webhook_url
  feishu_chat_id        = var.feishu_chat_id
  feishu_app_id         = var.feishu_app_id
  feishu_app_secret     = var.feishu_app_secret
  github_token          = var.github_token
  github_repo           = var.github_repo
  devops_agent_space_id = var.devops_agent_space_id
  eks_cluster_name      = module.eks.cluster_name
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_issuer_host      = module.eks.oidc_issuer_host
  route53_zone_id       = module.cdn.route53_zone_id

  # Grafana DevOps Agent capability
  grafana_url                 = "https://${var.grafana_host}"
  grafana_service_name        = "outline-grafana"
  grafana_sa_token_secret_arn = module.observability.grafana_sa_token_secret_arn

  # Private connection (VPC Lattice)
  private_connection_name = "outline-vpc-private"
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  grafana_alb_dns_name    = var.grafana_alb_dns_name

  # GitHub Issues → DevOps Agent investigation
  github_tickets_repo       = "JoeShi/devops-agent-demo-tickets"
  github_tickets_repo_owner = "JoeShi"
  github_tickets_repo_name  = "devops-agent-demo-tickets"
}

module "cdn" {
  source = "./modules/cdn"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name      = var.project_name
  environment       = var.environment
  domain_name       = var.outline_domain
  route53_zone_name = var.route53_zone_name
  alb_dns_name      = var.alb_dns_name
  grafana_domain    = var.grafana_host
  grafana_alb_dns_name = var.grafana_alb_dns_name
  apigw_endpoint       = ""
}

module "auth" {
  source = "./modules/auth"

  project_name = var.project_name
  outline_url  = "https://${var.outline_domain}"
  grafana_url  = "https://${var.grafana_host}"

  # Amazon Federate OIDC
  federate_enabled       = var.federate_enabled
  federate_client_id     = var.federate_client_id
  federate_client_secret = var.federate_client_secret
  federate_issuer_url    = var.federate_issuer_url
}
