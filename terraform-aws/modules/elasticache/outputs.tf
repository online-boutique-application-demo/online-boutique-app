output "redis_endpoint" {
  description = "Primary endpoint of the Redis replication group"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Reader endpoint of the Redis replication group"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "redis_port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.redis.port
}

output "redis_security_group_id" {
  description = "Security group ID of the Redis cluster"
  value       = aws_security_group.redis.id
}

output "redis_connection_string" {
  description = "Redis connection string for CartService (host:port)"
  value       = "${aws_elasticache_replication_group.redis.primary_endpoint_address}:${aws_elasticache_replication_group.redis.port}"
}
