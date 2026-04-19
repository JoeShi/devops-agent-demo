output "rds_endpoint" {
  description = "RDS Aurora PostgreSQL cluster endpoint."
  value       = aws_rds_cluster.main.endpoint
}

output "rds_reader_endpoint" {
  description = "RDS Aurora PostgreSQL reader endpoint."
  value       = aws_rds_cluster.main.reader_endpoint
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "opensearch_endpoint" {
  description = "OpenSearch domain endpoint."
  value       = aws_opensearch_domain.main.endpoint
}

output "opensearch_domain_arn" {
  description = "OpenSearch domain ARN."
  value       = aws_opensearch_domain.main.arn
}