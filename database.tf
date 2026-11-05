# Separate, managed data tier for GitLab: RDS PostgreSQL + ElastiCache Redis in the cluster's VPC.

# ---------------- PostgreSQL ----------------
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%^*-_+=" # RDS forbids / @ " and spaces
}

resource "aws_db_subnet_group" "gitlab" {
  name       = "${local.prefix}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "db" {
  name_prefix = "${local.prefix}-db-"
  description = "GitLab PostgreSQL"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from the EKS cluster"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = local.client_sgs
    cidr_blocks     = var.client_cidrs
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "gitlab" {
  name_prefix = "${local.prefix}-pg-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.prefix}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "monitoring.rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "gitlab" {
  identifier     = "${local.prefix}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.gitlab.arn

  db_name             = "gitlabhq_production"
  username            = "gitlab"
  password_wo         = random_password.db.result
  password_wo_version = 1 # bump to push a new password

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.gitlab.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.gitlab.name
  publicly_accessible    = false

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "20:00-21:00" # 01:30-02:30 IST
  maintenance_window         = "Sun:21:30-Sun:23:00"
  copy_tags_to_snapshot      = true
  delete_automated_backups   = false
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${local.prefix}-postgres-final"
  auto_minor_version_upgrade = true

  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.gitlab.arn
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}

# ---------------- Redis ----------------
resource "random_password" "redis" {
  length  = 48
  special = false
}

resource "aws_elasticache_subnet_group" "gitlab" {
  name       = "${local.prefix}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.prefix}-redis-"
  description = "GitLab Redis"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Redis from the EKS cluster"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = local.client_sgs
    cidr_blocks     = var.client_cidrs
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "gitlab" {
  replication_group_id = "${local.prefix}-redis"
  description          = "GitLab Redis"

  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  parameter_group_name = "default.redis${split(".", var.redis_engine_version)[0]}"
  port                 = 6379

  num_cache_clusters         = var.redis_replica ? 2 : 1
  automatic_failover_enabled = var.redis_replica
  multi_az_enabled           = var.redis_replica

  subnet_group_name  = aws_elasticache_subnet_group.gitlab.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.gitlab.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis.result

  snapshot_retention_limit = 7
  snapshot_window          = "19:00-20:00"
  maintenance_window       = "sun:22:00-sun:23:00"
}
