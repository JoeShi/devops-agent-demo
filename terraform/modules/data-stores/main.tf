locals {
  common_tags = {
    App         = "outline"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- RDS PostgreSQL ---

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = var.data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-db-subnet"
  })
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier          = "${var.project_name}-pg"
  engine                      = "aurora-postgresql"
  engine_version              = "16.6"
  database_name               = "outline"
  master_username             = "outline_admin"
  master_password             = var.db_password
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  storage_encrypted           = true
  deletion_protection         = false
  skip_final_snapshot         = true
  final_snapshot_identifier   = "${var.project_name}-pg-final"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-pg"
  })
}

resource "aws_rds_cluster_instance" "main" {
  count              = 2
  identifier         = "${var.project_name}-pg-${count.index}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.db_instance_class
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-pg-${count.index}"
  })
}

# --- ElastiCache Redis ---

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-redis-subnet"
  subnet_ids = var.data_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-redis-subnet"
  })
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-redis-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.project_name}-redis"
  description                = "Redis cluster for Outline"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.redis_node_type
  num_cache_clusters         = 2
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.redis.id]
  automatic_failover_enabled = true
  multi_az_enabled           = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-redis"
  })
}

# --- OpenSearch ---

resource "aws_security_group" "opensearch" {
  name_prefix = "${var.project_name}-os-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-opensearch-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_role" "opensearch" {
  name = "AWSServiceRoleForAmazonOpenSearchService"
}

resource "aws_opensearch_domain" "main" {
  domain_name    = "${var.project_name}-search"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = true

    zone_awareness_config {
      availability_zone_count = 2
    }
  }

  vpc_options {
    subnet_ids         = slice(var.data_subnet_ids, 0, 2)
    security_group_ids = [aws_security_group.opensearch.id]
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 100
    volume_type = "gp3"
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_name     = "admin"
      master_user_password = var.opensearch_master_password
    }
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:*"
      Resource  = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${var.project_name}-search/*"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-search"
  })

  depends_on = [data.aws_iam_role.opensearch]
}
