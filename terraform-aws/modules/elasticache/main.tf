# =============================================================================
# ElastiCache Module
# Creates a Redis replication group for the CartService
# =============================================================================

# -----------------------------------------------------------------------------
# ElastiCache Subnet Group
# -----------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.project_name}-${var.environment}-redis"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-redis-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# Security Group for Redis
# -----------------------------------------------------------------------------
resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-${var.environment}-redis-"
  vpc_id      = var.vpc_id
  description = "Security group for ElastiCache Redis"

  tags = {
    Name = "${var.project_name}-${var.environment}-redis-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "redis_ingress" {
  type                     = "ingress"
  from_port                = var.redis_port
  to_port                  = var.redis_port
  protocol                 = "tcp"
  source_security_group_id = var.allowed_security_group_id
  security_group_id        = aws_security_group.redis.id
  description              = "Allow Redis access from EKS worker nodes"
}

resource "aws_security_group_rule" "redis_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.redis.id
  description       = "Allow all outbound traffic"
}

# -----------------------------------------------------------------------------
# ElastiCache Redis Replication Group
# -----------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project_name}-${var.environment}"
  description          = "Redis for ${var.project_name} ${var.environment} CartService"

  engine               = "redis"
  engine_version       = var.redis_version
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_clusters
  port                 = var.redis_port
  parameter_group_name = var.parameter_group_name

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = var.at_rest_encryption
  transit_encryption_enabled = var.transit_encryption

  maintenance_window       = var.maintenance_window
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_window

  # Auto failover requires num_cache_clusters >= 2
  automatic_failover_enabled = var.num_cache_clusters >= 2
  multi_az_enabled           = var.num_cache_clusters >= 2

  apply_immediately = var.apply_immediately

  tags = {
    Name        = "${var.project_name}-${var.environment}-redis"
    Environment = var.environment
  }
}
